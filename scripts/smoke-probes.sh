# shellcheck shell=bash
# Agent Orchestrator 是编排器 Bot：没有网页入口、应用账号体系或插件自己的 MCP 服务，网页、身份、插件工具三项 N/A。
# 编排器自己不存要跨升级保留的用户数据（任务做完插件会删任务会话记录），数据两项不适用。
# 专项冒烟在附加检查里：套件的 Agent 助手（scripts/agent-probes.sh）验加密私聊、模型回答、名单外不应答，
# 下面的 ao_* 验编排器本身：开任务、问题卡、跑测试的命令卡、worker 交付、重启后重新接线。
export DATA_NA=1
export SMOKE_NOTE="编排器没有网页入口，也不存要跨升级保留的用户数据。"

# 一轮任务要编排器开 worker、worker 写代码跑测试，模型慢时十几分钟。
export EXTRA_TIMEOUT=5400
extra_check() {
  agent_check_chat '请用一句话回答：agent-orchestrator 冒烟。'
  agent_check_model
  # 外人进出房间后桥会换 Megolm 会话，之后新登录的探针设备解不开回话：只断言无声，“会回用户”由任务用例承担。
  # 编排器回完一轮后还会陆续发几条（分段的回答、状态），先等它安静 60 秒，免得算到外人头上；
  # 模型慢的时候隔几分钟才补完，所以外人那条等 120 秒才算无声。
  ao_quiet 60
  agent_check_outsider silent 120
  ao_check_task
  ao_check_restart
}

# 等到 Bot 在房间里安静 <秒数>（默认 60），最多等 600 秒：按最后一条 Bot 消息算。
ao_quiet() {
  local wait="${1:-60}" room_url token last now quiet=0
  room_url="$(jq -rn --arg r "$AGENT_ROOM" '$r | @uri')"
  # shellcheck disable=SC2153 # SMOKE_CORE 是套件在运行时给的
  token="$(docker exec "$SMOKE_CORE" cat "$SMOKE_DATA_DIR/core/matrix-admin-token")"
  for _ in $(seq 1 120); do
    last="$(agent_matrix "$token" GET "/_matrix/client/v3/rooms/$room_url/messages?dir=b&limit=20" 2>/dev/null |
      jq --arg b "$AGENT_BOT" '[.chunk[]? | select(.sender == $b) | .origin_server_ts // 0] | max // 0')"
    now="$(($(date +%s) * 1000))"
    if ((now - last > wait * 1000)); then quiet=1; break; fi
    sleep 5
  done
  ((quiet)) || echo "Bot 一直没安静下来，照常接着测"
}

ao_agent() { running_container "wonton-$SMOKE_INSTANCE--$SMOKE_SLUG--agent"; }

# 编排器容器里 AO 守护进程的接口：<方法> <路径>，标准输出 JSON。
ao_api() { docker exec "$(ao_agent)" curl -sS --noproxy '*' -X "$1" "http://127.0.0.1:3001$2"; }

# 把待答的卡片都同意（优先“Always Allow in project”）。问题卡（有“在话题里回答”）点推荐项（第一个不是
# “在话题里回答”或“取消”的选项）并留下标记；跑测试的卡（pytest/unittest）在 <测试卡标记> 出现前留着，给用例自己答。
ao_approve_pending() { # <问题卡标记> <测试卡标记>
  local list id choice skip=1
  [[ -f "$2" ]] && skip=""
  list="$(smoke_api GET /_wonton/api/confirmations 2>/dev/null)" || return 0
  while IFS=$'\t' read -r id choice; do
    [[ -n "$id" ]] || continue
    smoke_api POST "/_wonton/confirmations/$id" -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg c "$choice" '{answer: "approve", choice_id: $c}')" >/dev/null 2>&1
    touch "$1"
  done < <(jq -r '.confirmations[]? | select(([.choices[].label] | index("在话题里回答")))
    | [.id, ([.choices[] | select((.label != "在话题里回答") and (.label != "取消"))] | first | .choice_id // "")]
    | select(.[1] != "") | @tsv' <<<"$list" 2>/dev/null)
  while IFS=$'\t' read -r id choice; do
    [[ -n "$id" ]] || continue
    smoke_api POST "/_wonton/confirmations/$id" -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg c "$choice" '{answer: "approve", choice_id: $c}')" >/dev/null 2>&1
  done < <(jq -r --arg skip "$skip" '.confirmations[]? | select(([.choices[].label] | index("在话题里回答")) | not)
    | select($skip == "" or (((.title | contains("unittest")) or (.title | contains("pytest"))) | not))
    | [.id, ([.choices[] | select(.label | startswith("Always Allow in project"))] + [.choices[] | select(.label == "Allow")]
      | first | .choice_id // "")] | select(.[1] != "") | @tsv' <<<"$list" 2>/dev/null)
}

# 让编排器开一个小任务：先问一个问题（问题卡），worker 写函数和测试，批准跑测试，交出文件。
ao_check_task() {
  local reply asked tested approver bg opened=0 worker delivered=0 test_out
  agent_need 任务话题 model || return 0
  reply="$(agent_tmp)" asked="$(agent_tmp)" tested="$(agent_tmp)"
  rm -f "$asked" "$tested"
  AGENT_SAY_TIMEOUT=1020 agent_say --reply any --settle 15 --wait 960 \
    --text '在仓库里做一个小任务：加一个 add(a, b) 函数和它的单元测试并跑通。动手前先问我一个问题：函数放 src/mathlib.py 还是新文件？' \
    >"$reply" 2>&1 &
  bg=$!
  # 后台一路批准编排器和 worker 的卡片（读、写、提交、report），问题卡当场点推荐项：编排器拿到回答才开 worker。
  ( for _ in $(seq 1 900); do ao_approve_pending "$asked" "$tested"; sleep 2; done ) &
  approver=$!
  for _ in $(seq 1 480); do
    if grep -q '新任务' "$reply" 2>/dev/null ||
      ao_api GET /api/v1/sessions 2>/dev/null | jq -e '.sessions[]? | select(.kind == "worker")' >/dev/null; then
      opened=1
      break
    fi
    sleep 2
  done
  # 等回答失败时 wait 返回非 0，后面几项还要跑，别让它把整个附加检查带走。
  wait "$bg" || true
  cat "$reply"
  if ((opened)); then
    extra_item PASS 任务话题 "编排器开了任务：$(ao_api GET /api/v1/sessions | jq -r '[.sessions[] | select(.kind == "worker")] | length') 个 worker"
  else
    extra_item FAIL 任务话题 "960 秒内没开任务：$(agent_tail "$(cat "$reply")")"
  fi
  if [[ -f "$asked" ]]; then
    extra_item PASS 问题卡 "出现了问题卡，点了推荐选项"
  else
    extra_item FAIL 问题卡 "等不到问题卡"
  fi
  # 工人可能用 pytest 也可能用 unittest，两边的命令标题都含 test。不管等没等到，之后后台连测试卡一起批。
  if agent_card_answer approve test 420 >&2; then
    extra_item PASS 确认卡片 "批准了跑测试的命令"
  else
    extra_item FAIL 确认卡片 "等不到跑测试命令的卡片"
  fi
  touch "$tested"
  # 交付只看 worker 在自己的 worktree 里交出文件：合并是编排器模型的自主行为，不作验收门槛。
  for _ in $(seq 1 150); do
    worker="$(ao_api GET /api/v1/sessions | jq -r '.sessions[]? | select(.kind == "worker") | .id' | head -1)"
    if [[ -n "$worker" ]] && docker exec "$(ao_agent)" test -e "/data/agent/ao/worktrees/repo/$worker/src/mathlib.py"; then
      delivered=1
      break
    fi
    sleep 2
  done
  if ((delivered)); then
    extra_item PASS 交付 "worker 交出了 src/mathlib.py"
    test_out="$(docker exec "$(ao_agent)" sh -c "cd /data/agent/ao/worktrees/repo/$worker && if [ -x .venv/bin/pytest ]; then .venv/bin/pytest -q 2>&1 | tail -2; elif python3 -m pytest --version >/dev/null 2>&1; then python3 -m pytest -q 2>&1 | tail -2; elif [ -d tests ]; then python3 -m unittest discover -s tests -t tests 2>&1 | tail -3; else python3 -m unittest discover 2>&1 | tail -3; fi" 2>&1)"
    if grep -qE 'passed|^OK$|Ran [1-9]' <<<"$test_out" && ! grep -q 'FAILED' <<<"$test_out"; then
      extra_item PASS 测试 "worker 的测试通过：$(tail -1 <<<"$test_out")"
    else
      # worker 用什么跑测试由模型定，这里按常见几种找；没找到能跑的不算插件失败。
      extra_item N/A 测试 "按 pytest/unittest 没跑出 worker 的测试：$(agent_tail "$test_out")"
    fi
  else
    extra_item FAIL 交付 "300 秒内没等到 worker 交出 src/mathlib.py"
  fi
  kill "$approver" 2>/dev/null
  wait "$approver" 2>/dev/null
  rm -f "$reply" "$asked" "$tested"
}

# 重启编排器容器：桥对 ACP 的重连是惰性的，等用户来话才重连。发一条话当触发器，看 agent 日志里新出现
# “主会话是编排器”。回话本身不判：探针每次是新设备，桥旧 Megolm 会话没给它钥匙，回话在冒烟里解不开。
ao_check_restart() {
  local container before now=0
  agent_need 重启后还能聊 || return 0
  container="$(ao_agent)" || { extra_item FAIL 重启后还能聊 "找不到 agent 容器"; return 0; }
  # 行数基线在重启前取：适配器重连 20 秒内就完成，之后再取会错过那行。
  before="$(docker logs "$container" 2>&1 | wc -l)"
  docker restart "$container" >/dev/null || { extra_item FAIL 重启后还能聊 "docker restart 失败"; return 0; }
  sleep 20
  agent_say --wait 120 --text '重启后还在吗？还在就随便回一个字。' || true
  for _ in $(seq 1 60); do
    now="$(docker logs "$container" 2>&1 | tail -n +"$((before + 1))" | grep -c '主会话是编排器')"
    ((now >= 1)) && break
    sleep 5
  done
  if ((now >= 1)); then
    extra_item PASS 重启后还能聊 "重启后桥和适配器重新接线，编排器会话沿用"
  else
    extra_item FAIL 重启后还能聊 "重启后 5 分钟内适配器没重新接线"
  fi
}
