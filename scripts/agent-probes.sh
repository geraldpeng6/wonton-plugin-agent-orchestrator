# shellcheck shell=bash
# Agent 插件的冒烟助手：扮演用户的手机经隧道发加密消息、等 Bot 回答，验确认卡片、打断、重启、名单外不应答。
# probes.sh 读入它；插件在 smoke-probes.sh 的 extra_check 里按自己有的能力组合这些函数，每个函数记一到几行
# 附加检查的子项（extra_item），返回值不表示成败。例：
#
#   EXTRA_TIMEOUT=2400
#   extra_check() {
#     agent_check_chat '请用一句话回答：冒烟。记住暗号：青杏。'
#     agent_check_model
#     agent_check_mcp_bus
#     agent_check_restart agent bridge
#     agent_check_resume 青杏
#     agent_check_outsider
#   }
#
# 按 Agent 的行为选参数：agent_check_mcp_chat card（调 MCP 工具前也要确认）、agent_check_card <服务>（只读命令
# 不出卡片，改成在工作区建文件、看那个服务容器里的文件）。有登录的 Agent 再加 agent_check_login <方式[,方式…]> <正则…>、
# agent_check_login_web <方式…>、agent_check_login_redact。
#
# 扮演手机的两个验收工具是核心仓库 deploy/dev/core/Dockerfile 的 tunnel-client、echo-bot 两个构建目标，由调用方
# 给镜像：WONTON_SMOKE_TUNNEL_CLIENT_IMAGE、WONTON_SMOKE_ECHO_BOT_IMAGE。没给时要手机的子项记 N/A 并写原因。
# WONTON_SMOKE_CURL_IMAGE 只用来经手机的隧道代理取 Matrix 登录令牌。
# 要模型回答的子项（模型能回话、经聊天调工具、确认卡片、打断、续聊）要先接模型上游（WONTON_DEV_MODEL_*），没接时记 N/A。
# 等模型回答默认 240 秒，慢的 Agent 在探针里设 AGENT_WAIT（秒）。
# 只要 Bot 回了话就算数的（加密私聊、名单外不应答）不要模型：没有模型时 Bot 回的报错也是一条加密回复。

: "${WONTON_SMOKE_CURL_IMAGE:=curlimages/curl:8.23.0}"
AGENT_PHONE_STATE=""

# 用户的手机：tunnel-client 进核心的网络命名空间，和核心配对后在 127.0.0.1:18008 开带凭据的代理；
# echo-bot probe 经它连 Matrix。只起一次，后面的子项共用。起不来时记一行 FAIL 加密私聊（配对坏了是真问题），
# 没给镜像时什么都不记；返回 1，调用方按 AGENT_PHONE_STATE 记自己的 N/A。
agent_phone() {
  [[ -z "$AGENT_PHONE_STATE" ]] || { [[ "$AGENT_PHONE_STATE" == ok ]]; return; }
  if [[ -z "${WONTON_SMOKE_TUNNEL_CLIENT_IMAGE:-}" || -z "${WONTON_SMOKE_ECHO_BOT_IMAGE:-}" ]]; then
    AGENT_PHONE_STATE="na:没给验收工具镜像（WONTON_SMOKE_TUNNEL_CLIENT_IMAGE、WONTON_SMOKE_ECHO_BOT_IMAGE），没有扮演用户手机的客户端"
    return 1
  fi
  if agent_phone_up; then
    AGENT_PHONE_STATE=ok
    return 0
  fi
  AGENT_PHONE_STATE="fail:$AGENT_WHY"
  extra_item FAIL 加密私聊 "$AGENT_WHY"
  return 1
}

agent_phone_up() {
  local server pairing record hostport
  hostport="${SMOKE_BASE#*://}"
  hostport="${hostport%%/*}"
  AGENT_HOST="${hostport%:*}"
  AGENT_PORT="${hostport##*:}"
  AGENT_PHONE="wonton-$SMOKE_INSTANCE--smoke-phone"
  docker rm -f "$AGENT_PHONE" >/dev/null 2>&1 || true
  server="$(smoke_api GET /_wonton/api/tunnel | jq -r '.endpoint_id // empty')"
  [[ -n "$server" ]] || { AGENT_WHY="拿不到核心的隧道端点"; return 1; }
  # 带上实例标签：冒烟结束时随实例一起删。隧道的直连端口是网页端口的下一个。
  docker run -d --name "$AGENT_PHONE" --label "wonton.instance=$SMOKE_INSTANCE" \
    --network "container:$SMOKE_CORE" --entrypoint sh "$WONTON_SMOKE_TUNNEL_CLIENT_IMAGE" -c \
    "tunnel-client --key /tmp/phone.key id && exec tunnel-client --key /tmp/phone.key proxy --auth --domain $AGENT_HOST --server $server --addr 127.0.0.1:$((AGENT_PORT + 1)) --listen 127.0.0.1:18008" \
    >/dev/null || { AGENT_WHY="手机的隧道客户端起不来（$WONTON_SMOKE_TUNNEL_CLIENT_IMAGE）"; return 1; }
  for _ in $(seq 1 30); do
    docker logs "$AGENT_PHONE" 2>&1 | grep -q '^本地代理' && break
    sleep 1
  done
  AGENT_CREDENTIAL="$(docker logs "$AGENT_PHONE" 2>&1 | sed -n 's/^会话凭据：//p' | tail -1)"
  [[ -n "$AGENT_CREDENTIAL" ]] || { AGENT_WHY="手机的隧道代理 30 秒没就绪：$(docker logs "$AGENT_PHONE" 2>&1 | tail -3 | tr '\n' ' ')"; return 1; }
  # 配对码带上回环直连地址（和 proxy 的 --addr 同一个端口）：不带就只能走中继，偶尔要半分钟以上。
  pairing="$(docker exec "$SMOKE_CORE" wonton-core pair "127.0.0.1:$((AGENT_PORT + 1))" 2>&1 | grep '^wonton://pair?' | tail -1)"
  [[ -n "$pairing" ]] || { AGENT_WHY="wonton-core pair 没给出配对链接"; return 1; }
  docker exec "$AGENT_PHONE" tunnel-client --key /tmp/phone.key pair "$pairing" --name 'smoke phone' ||
    { AGENT_WHY="手机配对被核心拒绝"; return 1; }
  record="$(docker exec "$SMOKE_CORE" cat "$SMOKE_DATA_DIR/core/plugins/bots/$SMOKE_PLUGIN_ID.json")" ||
    { AGENT_WHY="核心里没有这个插件的 Bot 记录"; return 1; }
  AGENT_ROOM="$(jq -r '.bots.default.home_room // empty' <<<"$record")"
  AGENT_BOT="$(jq -r '.bots.default.user_id // empty' <<<"$record")"
  [[ -n "$AGENT_ROOM" && -n "$AGENT_BOT" ]] || { AGENT_WHY="Bot 记录里没有主房间或用户 ID"; return 1; }
}

# 用户的一台新设备发消息、等 Bot 回答：参数原样交给 echo-bot probe（--text、--reply、--wait、--settle、--mention…），
# 标准输出是 probe 的输出（含 Bot 的回答）。每次新设备，登录令牌只用这一次。
agent_say() {
  local token
  token="$(docker run --rm --network "container:$AGENT_PHONE" "$WONTON_SMOKE_CURL_IMAGE" -sS --noproxy '' \
    --max-time 60 -x http://127.0.0.1:18008 -U "$AGENT_CREDENTIAL" -H "Authorization: Bearer $SMOKE_TOKEN" \
    -X POST "http://$AGENT_HOST:$AGENT_PORT/_wonton/matrix/login-token" | jq -r '.token // empty')"
  [[ -n "$token" ]] || { echo "拿不到用户的 Matrix 登录令牌"; return 1; }
  timeout "${AGENT_SAY_TIMEOUT:-$(( ${AGENT_WAIT:-240} + 120 ))}" docker run --rm --network "container:$AGENT_PHONE" \
    "$WONTON_SMOKE_ECHO_BOT_IMAGE" probe --homeserver "http://matrix.$AGENT_HOST:$AGENT_PORT" \
    --proxy "http://$AGENT_CREDENTIAL@127.0.0.1:18008" --login-token "$token" \
    --room "$AGENT_ROOM" --bot "$AGENT_BOT" "$@"
}

# 子项的前置：<子项> [model]。手机或模型不在时记这一项 N/A（写原因）并返回 1。
agent_need() {
  local item="$1"
  if ! agent_phone; then
    case "$AGENT_PHONE_STATE" in
      na:*) extra_item N/A "$item" "${AGENT_PHONE_STATE#na:}" ;;
      *) extra_item N/A "$item" "手机没连上，没测（${AGENT_PHONE_STATE#fail:}）" ;;
    esac
    return 1
  fi
  if [[ "${2:-}" == model && -z "${WONTON_DEV_MODEL_BASE_URL:-}" ]]; then
    extra_item N/A "$item" "没接模型上游（WONTON_DEV_MODEL_*），Bot 答不了需要模型的问题"
    return 1
  fi
}

agent_tmp() { mktemp "${SMOKE_STATE%/*}/agent.XXXXXX"; }

# 诊断辅助：名单外窗口出现 Bot 消息时把现场抓全，误报时不用重跑——原始房间事件（加密事件没有正文，
# 但 sender/ts/type/relations 齐）、桥和 agent 容器日志、AO 会话列表、核心注入给桥的名单。
agent_outsider_hit_dump() { # <owner_token> <room_url> <since 毫秒> <outsider 用户 ID>
  local ot="$1" room_url="$2" since="$3" outsider="$4" outdir ts c
  ts="$(date +%H%M%S)"
  outdir="${AO_DBG_DIR:-${SMOKE_STATE%/*}}/outsider-hit-$ts"
  mkdir -p "$outdir"
  echo "== 诊断：名单外窗口出现 Bot 消息（since=$since outsider=$outsider），现场在 $outdir"
  agent_matrix "$ot" GET "/_matrix/client/v3/rooms/$room_url/messages?dir=b&limit=100" \
    >"$outdir/room-events.json" 2>&1 || true
  jq -c '.chunk[]? | {ts: .origin_server_ts, sender, type, event_id, content, relates: (.content["m.relates_to"] // empty)}' \
    "$outdir/room-events.json" 2>/dev/null | head -40 | sed 's/^/事件 /' || true
  c="$(running_container "wonton-$SMOKE_INSTANCE--$SMOKE_SLUG--bridge")"
  if [[ -n "$c" ]]; then
    docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' |
      grep -E "WONTON_MATRIX_(ALLOWED_USERS|HOME_ROOM|USER_ID|HOMESERVER)" | sed 's/^/桥env /'
    docker logs --tail 500 --timestamps "$c" >"$outdir/bridge.log" 2>&1 || true
    echo "== 桥日志尾部 50 行 =="; tail -50 "$outdir/bridge.log"
  fi
  c="$(running_container "wonton-$SMOKE_INSTANCE--$SMOKE_SLUG--agent")"
  if [[ -n "$c" ]]; then
    docker logs --tail 500 --timestamps "$c" >"$outdir/agent.log" 2>&1 || true
    echo "== agent 日志尾部 50 行 =="; tail -50 "$outdir/agent.log"
    docker exec "$c" curl -sS --noproxy '*' --max-time 10 http://127.0.0.1:3001/api/v1/orchestrators \
      >"$outdir/ao-sessions.json" 2>&1 || true
    echo "== AO 会话列表 =="; head -c 4000 "$outdir/ao-sessions.json"; echo
    # 每个会话的最近对话：outsider 文本到没到 Agent，看转录里有没有它。
    jq -r '.sessions[]?.id // empty' "$outdir/ao-sessions.json" 2>/dev/null | sort -u | head -8 |
      while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        docker exec "$c" curl -sS --noproxy '*' --max-time 15 \
          "http://127.0.0.1:3001/api/v1/sessions/$sid/conversation?limit=50" \
          >"$outdir/ao-conv-$sid.json" 2>&1 || true
      done
    echo "== AO 转录关键词扫描（outsider/请用一句话/同一个房间/诊断） =="
    grep -l . "$outdir"/ao-conv-*.json 2>/dev/null | while IFS= read -r f; do
      grep -o -E "outsider smoke[^\"]{0,80}|请用一句话[^\"]{0,60}|同一个房间[^\"]{0,60}|诊断：[^\"]{0,60}" "$f" |
        sed "s|^|$(basename "$f") |" | head -6
    done
  fi
  if [[ -n "${WONTON_DEV_MODEL_BASE_URL:-}" ]]; then
    echo "== 诊断：让 Agent 复述最近收到的用户消息 =="
    agent_say --reply any --settle 8 --wait 150 --text '诊断：请逐字复述你最近一次收到的用户消息的原文，只输出原文，不要解释。' 2>&1 | tail -15
  fi
}

# 一行摘要：日志里留全文，结果行里只放末尾一段。
agent_tail() { tail -c "${2:-200}" <<<"$1" | tr '\n' ' '; }

agent_check_chat() { # [文字]：首次安装后加密私聊收发
  local out
  agent_need 加密私聊 || return 0
  if out="$(agent_say --reply any --settle 15 --wait "${AGENT_WAIT:-240}" --text "${1:-请用一句话回答：冒烟。}" 2>&1)"; then
    extra_item PASS 加密私聊 "用户的新设备发加密消息，收到 Bot 的加密回复"
  else
    extra_item FAIL 加密私聊 "没收到 Bot 的加密回复：$(agent_tail "$out")"
  fi
  printf '%s\n' "$out"
}

# 真问到模型：回答里不能是网关或 Agent 的报错（模型不存在、上游出错）。
agent_check_model() {
  local out rc=0
  agent_need 模型能回话 model || return 0
  out="$(agent_say --reply any --wait "${AGENT_WAIT:-240}" --text '请只回答：模型验收通过。' 2>&1)" || rc=$?
  printf '%s\n' "$out"
  if ((rc == 0)) && ! grep -Eiq 'model was not found|couldn.t finish|could not finish|provider-error|⚠️' <<<"$out"; then
    extra_item PASS 模型能回话 "经模型网关回答了（上游模型 ${WONTON_DEV_MODEL:-}）"
  else
    extra_item FAIL 模型能回话 "接了模型上游，回答失败：$(agent_tail "$out")"
  fi
}

# MCP 总线本身：tools/list 有核心的 wonton__list_plugins，真调一次（只读）。不要手机。
agent_check_mcp_bus() {
  local out
  if ! out="$(mcp list 2>&1)"; then
    extra_item FAIL MCP工具 "总线 tools/list 失败：$(agent_tail "$out")"
  elif ! jq -e 'any(.[]; .name == "wonton__list_plugins")' <<<"$out" >/dev/null 2>&1; then
    extra_item FAIL MCP工具 "总线 tools/list 里没有 wonton__list_plugins"
  elif ! out="$(mcp call wonton__list_plugins '{}' 2>&1)"; then
    extra_item FAIL MCP工具 "调 wonton__list_plugins 失败：$(agent_tail "$out")"
  else
    extra_item PASS MCP工具 "总线 tools/list 有 wonton__list_plugins，只读调用成功"
  fi
}

# Agent 自己经总线调工具：让它列已装的插件，回答里要有核心预装的模型网关。[card]：这家 Agent 调 MCP 工具前
# 也要用户确认（如 Claude Code 的 default 模式），同时等那张卡片并同意，卡片没出现记 FAIL。
agent_check_mcp_chat() {
  local file bg rc=0
  agent_need MCP工具 model || return 0
  file="$(agent_tmp)"
  agent_say --reply any --settle 10 --wait "${AGENT_WAIT:-240}" \
    --text '用 wonton__list_plugins 列出已装的插件，输出每项的 id（形如 xxx.yyy.zzz），一个一行，不要解释。' >"$file" 2>&1 &
  bg=$!
  if [[ "${1:-}" == card ]]; then
    if agent_card_answer approve list_plugins >&2; then
      agent_cards_until "$bg" approve list_plugins >/dev/null
      extra_item PASS MCP工具 "Agent 调 MCP 工具前出了确认卡片，同意了"
    else
      extra_item FAIL MCP工具 "Agent 调 MCP 工具前等不到确认卡片"
    fi
  fi
  wait "$bg" || rc=$?
  cat "$file"
  if ((rc == 0)) && grep -q 'ai.usemagpie.magpie' "$file"; then
    extra_item PASS MCP工具 "Agent 在聊天里调了 wonton__list_plugins，回答里有预装的模型网关"
  else
    extra_item FAIL MCP工具 "Agent 没在聊天里调成 wonton__list_plugins：$(agent_tail "$(cat "$file")")"
  fi
  rm -f "$file"
}

# 等一张标题、说明或参数里含 <文字> 的确认卡片，按 <approve|reject> 回答，最多等 [秒数]（默认 120）；卡片没出现返回 1。选项带 choice_id 的
# （ACP 的权限卡）要把那个选项自己的 answer 和 choice_id 一起发回去。
agent_card_answer() {
  local want="$1" needle="$2" list id body
  for _ in $(seq 1 "${3:-120}"); do
    list="$(smoke_api GET /_wonton/api/confirmations 2>/dev/null)" || list='{}'
    id="$(jq -r --arg n "$needle" '[.confirmations[]? | select(((.title // "") + " " + (.description // "") + " "
      + ((.arguments // {}) | tostring)) | contains($n)) | .id][0] // empty' <<<"$list")"
    if [[ -n "$id" ]]; then
      body="$(jq -c --arg id "$id" --arg a "$want" '[.confirmations[] | select(.id == $id) | .choices[]?
        | select(((.answer // .kind) // "") | startswith($a))][0] // {} | {answer: (.answer // $a)}
        + (if .choice_id then {choice_id} else {} end)' <<<"$list")"
      echo "卡片 $id：回答 $body"
      smoke_api POST "/_wonton/confirmations/$id" -H 'Content-Type: application/json' -d "$body"
      return
    fi
    sleep 1
  done
  return 1
}

# <进程> 还在跑时一直按 <approve|reject> 回答含 <文字> 的卡片（有的 Agent 一个动作弹好几张）。输出回答了几张。
agent_cards_until() { # <进程> <approve|reject> <文字>
  local n=0
  while kill -0 "$1" 2>/dev/null; do
    agent_card_answer "$2" "$3" 2 >&2 && n=$((n + 1))
  done
  echo "$n"
}

# 确认卡片：同意一次（命令跑了），拒绝一次（命令没跑）。不给参数时让 Agent 用 shell 跑 echo，看聊天里的输出
# 和回答。[服务]：这家 Agent 只在写工作区时才问（只读命令不出卡片，如 Codex 的 read-only、Claude Code 的 default），
# 改成让它在 /workspace 里 touch 一个文件，以那个服务容器里文件在不在为准：模型有时不等执行结果就先回话，
# 拒绝后这一轮也可能直接结束、聊天里没有回答。
agent_check_card() {
  local file bg svc="${1:-}" container ask_ok ask_no
  agent_need 确认卡片 model || return 0
  if [[ -n "$svc" ]]; then
    container="$(running_container "wonton-$SMOKE_INSTANCE--$SMOKE_SLUG--$svc")" ||
      { extra_item FAIL 确认卡片 "找不到服务 $svc 在跑的容器"; return 0; }
    docker exec "$container" rm -f /workspace/card-ok /workspace/card-no >/dev/null 2>&1 || true
    ask_ok='用 touch 在 /workspace 里创建文件 card-ok，然后只回答：建好了。'
    ask_no='用 touch 在 /workspace 里创建文件 card-no，然后只回答：建好了。'
  else
    ask_ok='用 shell 跑一条命令：echo card-ok，然后只说命令输出。'
    ask_no='再用 shell 跑一条命令：echo card-no，然后只说结果。'
  fi
  file="$(agent_tmp)"
  agent_say --reply any --wait "${AGENT_WAIT:-240}" --text "$ask_ok" >"$file" 2>&1 &
  bg=$!
  if agent_card_answer approve card-ok >&2; then
    agent_cards_until "$bg" approve card-ok >/dev/null
    wait "$bg"
    if agent_card_ran "$container" card-ok "$file"; then
      extra_item PASS 确认卡片 "跑命令前出了确认卡片，同意后命令跑了${svc:+（$svc 里有 card-ok）}"
    else
      extra_item FAIL 确认卡片 "同意了卡片，等不到命令跑完：$(agent_tail "$(cat "$file")")"
    fi
  else
    kill "$bg" 2>/dev/null; wait "$bg"
    extra_item FAIL 确认卡片 "让 Agent 跑命令，等不到确认卡片：$(agent_tail "$(cat "$file")")"
  fi
  cat "$file"
  agent_say --reply any --wait "$([[ -n "$svc" ]] && echo 30 || echo 240)" --text "$ask_no" >"$file" 2>&1 &
  bg=$!
  if agent_card_answer reject card-no >&2; then
    agent_cards_until "$bg" reject card-no >/dev/null
    wait "$bg"
    sleep 5
    if [[ -n "$svc" ]]; then
      if docker exec "$container" test -e /workspace/card-no; then
        extra_item FAIL 确认卡片 "拒绝了卡片，$svc 里还是有 card-no"
      else
        extra_item PASS 确认卡片 "拒绝卡片后命令没跑（$svc 里没有 card-no）"
      fi
    elif grep -qxE ' *card-no *' "$file" || ! grep -Eiq '拒绝|没(有)?执行|未执行|denied|rejected|cancel' "$file"; then
      extra_item FAIL 确认卡片 "拒绝了卡片，回答看不出命令没跑：$(agent_tail "$(cat "$file")")"
    else
      extra_item PASS 确认卡片 "拒绝卡片后命令没跑，Agent 如实说了"
    fi
  else
    kill "$bg" 2>/dev/null; wait "$bg"
    extra_item FAIL 确认卡片 "第二次跑命令等不到确认卡片：$(agent_tail "$(cat "$file")")"
  fi
  cat "$file"
  rm -f "$file"
  [[ -z "$svc" ]] || docker exec "$container" rm -f /workspace/card-ok >/dev/null 2>&1 || true
}

# 同意之后命令跑了没有：<容器>（空 = 看聊天）<文件名> <聊天记录>。看容器时等 20 秒文件出现。
agent_card_ran() {
  if [[ -z "$1" ]]; then
    grep -q "$2" "$3"
    return
  fi
  for _ in $(seq 1 20); do
    docker exec "$1" test -e "/workspace/$2" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

# 打断：先交一个要跑很久的活，再从另一台设备发 /wonton interrupt，新的一轮要能回答。
agent_check_interrupt() {
  local file bg out rc=0
  agent_need 打断 model || return 0
  file="$(agent_tmp)"
  agent_say --reply any --wait "${AGENT_WAIT:-240}" --text '先用 shell 跑 sleep 45，跑完只回答一句：数完了。' >"$file" 2>&1 &
  bg=$!
  # 跑 sleep 也要确认的 Agent 会先弹卡片：4 秒内出了就同意（让它真的跑起来再打断），没出就再等 4 秒。
  agent_card_answer approve sleep 4 >&2 || sleep 4
  out="$(agent_say --reply any --wait 180 --settle 20 --text '/wonton interrupt 只回答一句：打断好了。' 2>&1)" || rc=$?
  wait "$bg"
  cat "$file"
  rm -f "$file"
  printf '%s\n' "$out"
  if ((rc == 0)) && grep -q '打断好了' <<<"$out"; then
    extra_item PASS 打断 "/wonton interrupt 停下手上的活，新的一轮回答了"
  else
    extra_item FAIL 打断 "打断后没等到新一轮的回答：$(agent_tail "$out")"
  fi
}

agent_wait_healthy() { # <容器>：最多等 AGENT_HEALTHY_WAIT 秒（默认 180）
  for _ in $(seq 1 "$(( ${AGENT_HEALTHY_WAIT:-180} / 2 ))"); do
    [[ "$(docker inspect "$1" --format '{{.State.Health.Status}}' 2>/dev/null)" == healthy ]] && return 0
    sleep 2
  done
  return 1
}

# 重启插件的这些服务（数据卷留着），等它们重新 healthy。<服务…> 是清单里的服务名。
agent_check_restart() {
  local svc container containers=() bad=""
  for svc in "$@"; do
    container="$(running_container "wonton-$SMOKE_INSTANCE--$SMOKE_SLUG--$svc")" ||
      { extra_item FAIL 重启后还能聊 "找不到服务 $svc 在跑的容器"; return 0; }
    containers+=("$container")
  done
  docker restart "${containers[@]}" >/dev/null ||
    { extra_item FAIL 重启后还能聊 "docker restart 失败：${containers[*]}"; return 0; }
  for container in "${containers[@]}"; do
    agent_wait_healthy "$container" || bad="$bad $container"
  done
  if [[ -n "$bad" ]]; then
    extra_item FAIL 重启后还能聊 "重启后 ${AGENT_HEALTHY_WAIT:-180} 秒没回到 healthy：$bad"
  else
    extra_item PASS 重启后还能聊 "$* 重启后重新 healthy"
  fi
}

# 续聊：问第一条消息里留的暗号，重启以后同一个会话还带得住上下文。
agent_check_resume() { # <暗号>
  local out rc=0
  agent_need 续聊 model || return 0
  # 只认含暗号的那条：桥的提示（如话题冲突）可能抢在模型的回答前到。
  out="$(agent_say --reply any --match "$1" --wait "${AGENT_WAIT:-240}" --text '我们第一次说话时留的暗号是什么？只回答暗号。' 2>&1)" || rc=$?
  printf '%s\n' "$out"
  if ((rc == 0)) && grep -qF "$1" <<<"$out"; then
    extra_item PASS 续聊 "同一个会话记得第一条消息里的暗号"
  else
    extra_item FAIL 续聊 "问不回暗号 $1：$(agent_tail "$out")"
  fi
}

# 聊天登录：/wonton login 要列出 <方式>（逗号分隔的几种都要在，发起第一种）；发起后聊天里每个 <正则> 都要命中
# （链接、设备码或输入提示），到此为止，不真登录；再 /wonton login cancel 回到待命。这些都是桥自己回的，不要模型。
agent_check_login() { # <方式[,方式…]> <正则…>
  local methods method out m re missing
  IFS=, read -ra methods <<<"$1"
  method="${methods[0]}"
  agent_need 登录方式 || return 0
  out="$(agent_say --reply any --settle 10 --wait 60 --text '/wonton login' 2>&1)"
  printf '%s\n' "$out"
  for m in "${methods[@]}"; do
    grep -qF "/wonton login $m" <<<"$out" ||
      { extra_item FAIL 登录方式 "/wonton login 的回答里没有 $m：$(agent_tail "$out")"; return 0; }
  done
  extra_item PASS 登录方式 "聊天里列出登录方式 ${methods[*]}"
  out="$(agent_say --reply any --settle 10 --wait 90 --text "/wonton login $method" 2>&1)"
  printf '%s\n' "$out"
  missing=""
  for re in "${@:2}"; do
    grep -Eq "$re" <<<"$out" || missing="$missing $re"
  done
  if [[ -z "$missing" ]]; then
    extra_item PASS 登录链接 "发起 $method 后聊天里出现了登录链接或输入提示（到这为止，不真登录）"
  else
    extra_item FAIL 登录链接 "发起 $method 后聊天里没有$missing：$(agent_tail "$out")"
  fi
  out="$(agent_say --reply any --settle 10 --wait 60 --text '/wonton login cancel' 2>&1)"
  printf '%s\n' "$out"
  if grep -q '登录已取消' <<<"$out"; then
    extra_item PASS 登录取消 "取消登录，回到待命"
  else
    extra_item FAIL 登录取消 "取消登录没确认：$(agent_tail "$out")"
  fi
}

# 登录网页（插件的网页入口，用户会话）的 /api/logins 列出的方式 id 正好是 <方式…>（不计顺序）。
agent_check_login_web() { # <方式…>
  local out want
  want="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != "")) | sort')"
  if [[ -z "${SMOKE_WEB_URL:-}" ]]; then
    extra_item FAIL 登录网页 "没有网页入口（清单的 webui）"
  elif ! out="$(web_get /api/logins 2>&1)"; then
    extra_item FAIL 登录网页 "登录网页的 /api/logins 请求失败：$(agent_tail "$out")"
  elif jq -e --argjson w "$want" '([.logins[].id] | sort) == $w' <<<"$out" >/dev/null 2>&1; then
    extra_item PASS 登录网页 "登录网页列出 $*"
  else
    extra_item FAIL 登录网页 "登录网页列出的方式不是 $*：$(agent_tail "$out")"
  fi
}

# 登录密钥撤回：/wonton login api-key 后在聊天里贴一个假 key，桥转交给 Agent 后要撤回那条消息，服务器上的
# content 是空对象。贴完取消登录。
agent_check_login_redact() {
  local out
  agent_need 登录密钥撤回 || return 0
  out="$(agent_say --reply any --settle 10 --wait 60 --text '/wonton login api-key' 2>&1)"
  printf '%s\n' "$out"
  if ! grep -Eiq 'api key|api-key|key' <<<"$out"; then
    extra_item FAIL 登录密钥撤回 "/wonton login api-key 没回出输入提示：$(agent_tail "$out")"
    return 0
  fi
  out="$(agent_say --reply any --wait 30 --print-event-id 1 --redacted 60 --text "sk-smoke-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')" 2>&1)"
  printf '%s\n' "$out"
  if grep -q '已撤回：content={}' <<<"$out"; then
    extra_item PASS 登录密钥撤回 "桥撤回了贴 key 的消息，服务器上的 content 是空对象"
  else
    extra_item FAIL 登录密钥撤回 "贴 key 的消息没撤回：$(agent_tail "$out")"
  fi
  agent_say --reply any --settle 10 --wait 60 --text '/wonton login cancel' 2>&1
}

# Matrix 客户端接口：<令牌> <方法> <路径> [JSON 正文]，在核心容器里发（同 probes_matrix），正文只用 ASCII。
agent_matrix() {
  MATRIX_TOKEN="$1" probes_matrix "${@:2}"
}

# 名单外不应答：Bot 只听名单里的人。名单外的临时用户在主房间里发一条，<等待秒>（默认 30）内 Bot 不许回；模型慢、
# 上一轮还没说完的 Agent 给长一点；踢掉他以后用户在
# 同一个房间发一条，Bot 必须回：说明 Bot 在收这个房间的消息，前一条是看到了不答，不是没在跑。
# 开窗前先用主人的一台新设备打一个往返（ping），确认没有轮次还在跑：桥对被打断的轮次会发超时通知，
# 那是不针对谁的插话，上一轮还在跑时会被算到外人头上。往返没回答时预检不过，这一项记 N/A。
# [silent]：只断言名单外的人得不到回答，不做踢人后的对照（有的桥在有人进出房间后换 Megolm 会话，之后新登录的
# 探针设备解不开回话；“Bot 在听且会回用户”由别的子项承担）。
# 临时用户用 Matrix 服务器的注册共享密钥建；邀请、踢人、读消息用用户本人的身份（管理接口代登录，用完退出），
# 不碰 Bot 的令牌。
agent_check_outsider() { # [silent] [等多少秒，默认 30]
  local admin owner owner_token secret nonce pass name mac reg outsider outsider_token room_url since seen out rc=0 expect
  local wait="${2:-30}"
  agent_need 名单外不应答 || return 0
  # 桥的轮次超时通知（单轮 10 分钟）不针对谁：上一轮还在跑时，它的超时通知会落进下面的无声窗口，被算成
  # “Bot 回了外人”。先打一个往返：Bot 回了话就说明在跑的轮次已经结束（桥按轮次排队，回话前不会再开新的
  # 未完成轮次），再开窗。往返没回答说明可能有轮次还在跑，窗口判定不可信，这一项记 N/A。
  if out="$(agent_say --reply any --settle 5 --wait "${AGENT_WAIT:-120}" --text '冒烟：请只回答 ping，不要调用工具。' 2>&1)"; then
    sleep 10
  else
    extra_item N/A 名单外不应答 "预检往返没回答，可能有轮次还在跑，窗口判定不可信：$(agent_tail "$out")"
    return 0
  fi
  admin="$(docker exec "$SMOKE_CORE" cat "$SMOKE_DATA_DIR/core/matrix-admin-token")" ||
    { extra_item FAIL 名单外不应答 "读不到核心的 Matrix 管理令牌"; return 0; }
  owner="@$SMOKE_OWNER:${AGENT_BOT#*:}"
  owner_token="$(agent_matrix "$admin" POST "/_synapse/admin/v1/users/$(jq -rn --arg u "$owner" '$u | @uri')/login" '{}' |
    jq -r '.access_token // empty')"
  [[ -n "$owner_token" ]] || { extra_item FAIL 名单外不应答 "代登录用户 $owner 失败"; return 0; }
  # shellcheck disable=SC2016 # 单引号里是核心容器里的变量
  secret="$(docker exec "$SMOKE_CORE" sh -c 'cat "$WONTON_MATRIX_REGISTRATION_SECRET_FILE"')" ||
    { extra_item FAIL 名单外不应答 "读不到 Matrix 服务器的注册共享密钥"; return 0; }
  # 注册接口不认令牌，带上管理令牌只是不发空的 Authorization 头。
  nonce="$(agent_matrix "$admin" GET /_synapse/admin/v1/register | jq -r '.nonce // empty')"
  pass="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  name="smoke-outsider-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  # 共享密钥注册的签名：HMAC-SHA1(nonce \0 用户名 \0 密码 \0 admin)。用服务器管理员注册：Bot 的名单不看对方是不是管理员，临时用户随冒烟实例一起删。
  mac="$(python3 -c 'import hmac,hashlib,sys; print(hmac.new(sys.argv[1].encode(), "\0".join(sys.argv[2:]).encode(), hashlib.sha1).hexdigest())' \
    "$secret" "$nonce" "$name" "$pass" admin)"
  reg="$(agent_matrix "$admin" POST /_synapse/admin/v1/register "$(jq -cn --arg n "$nonce" --arg u "$name" --arg p "$pass" \
    --arg m "$mac" '{nonce: $n, username: $u, password: $p, admin: true, mac: $m}')")"
  outsider="$(jq -r '.user_id // empty' <<<"$reg" 2>/dev/null)"
  outsider_token="$(jq -r '.access_token // empty' <<<"$reg" 2>/dev/null)"
  [[ -n "$outsider" && -n "$outsider_token" ]] ||
    { extra_item FAIL 名单外不应答 "注册名单外的临时用户失败：$(agent_tail "$reg")"; return 0; }
  room_url="$(jq -rn --arg r "$AGENT_ROOM" '$r | @uri')"
  agent_matrix "$owner_token" POST "/_matrix/client/v3/rooms/$room_url/invite" \
    "$(jq -cn --arg u "$outsider" '{user_id: $u}')" >/dev/null
  agent_matrix "$outsider_token" POST "/_matrix/client/v3/rooms/$room_url/join" '{}' | jq -e '.room_id' >/dev/null ||
    { extra_item FAIL 名单外不应答 "名单外的人进不了主房间（用户邀请他失败？）"; return 0; }
  since="$(($(date +%s) * 1000))"
  agent_matrix "$outsider_token" PUT "/_matrix/client/v3/rooms/$room_url/send/m.room.message/smoke-outsider-$since" \
    "$(jq -cn --arg b "$AGENT_BOT" '{msgtype: "m.text", body: "outsider smoke: please reply", "m.mentions": {user_ids: [$b]}}')" |
    jq -e '.event_id' >/dev/null || { extra_item FAIL 名单外不应答 "名单外的人发不出消息"; return 0; }
  sleep "$wait"
  seen="$(agent_matrix "$owner_token" GET "/_matrix/client/v3/rooms/$room_url/messages?dir=b&limit=100" |
    jq --arg b "$AGENT_BOT" --argjson t "$since" '[.chunk[]? | select(.sender == $b and (.origin_server_ts // 0) >= $t
      and (.type == "m.room.message" or .type == "m.room.encrypted"))] | length')"
  if [[ "$seen" != 0 ]]; then
    agent_outsider_hit_dump "$owner_token" "$room_url" "$since" "$outsider"
  fi
  # 踢掉以后房间回到两个人，Bot 按私聊处理（有的 Agent 在三人房间里整个不回）。
  agent_matrix "$owner_token" POST "/_matrix/client/v3/rooms/$room_url/kick" \
    "$(jq -cn --arg u "$outsider" '{user_id: $u}')" >/dev/null
  agent_matrix "$outsider_token" POST /_matrix/client/v3/logout '{}' >/dev/null
  agent_matrix "$owner_token" POST /_matrix/client/v3/logout '{}' >/dev/null
  if [[ "$seen" != 0 ]]; then
    extra_item FAIL 名单外不应答 "名单外的人（$outsider）发消息后 Bot 回了 ${seen:-?} 条"
    return 0
  fi
  if [[ "${1:-}" == silent ]]; then
    extra_item PASS 名单外不应答 "名单外的人发消息 30 秒没有回答（不做同一房间的对照）"
    return 0
  fi
  sleep 10
  expect="名单内通过"
  [[ -n "${WONTON_DEV_MODEL_BASE_URL:-}" ]] || expect=""
  out="$(agent_say --reply any --settle 15 --wait "${AGENT_WAIT:-240}" --mention "$AGENT_BOT" \
    --text '同一个房间里的对照：请只回答 名单内通过' 2>&1)" || rc=$?
  printf '%s\n' "$out"
  if ((rc == 0)) && grep -qF "$expect" <<<"$out"; then
    extra_item PASS 名单外不应答 "名单外的人发消息 $wait 秒没有回答，用户随后在同一房间得到回答"
  else
    extra_item FAIL 名单外不应答 "名单外的人没得到回答，但用户随后在同一房间也没得到回答：$(agent_tail "$out")"
  fi
}
