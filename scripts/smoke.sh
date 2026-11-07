#!/usr/bin/env bash
# 插件合并前的端到端冒烟：用工作区的插件起一套一次性开发环境，四项真实请求，不用 mock。
#   scripts/dev.sh smoke
# 四项：装得上 / 网页打得开 / 用户身份能用 / 工具 Bot 调得到。任何 FAIL 退出非 0。
# 插件自己的探测在 scripts/smoke-probes.sh，写法见模板里的这个文件。
# 作者已有的 .wonton 不动：整个工作区复制到临时目录，用冒烟自己的实例，跑完删掉容器、网络、卷和目录。
#
# WONTON_DEV_EGRESS_PROXY：给了就先把它配成核心的出口代理（插件冷启动要出网时用），不给就不配。
set -uo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
# 探针环境、公共助手和三项探针的调用在探针套件里，和 dev.sh probes 共用。
# shellcheck source=scripts/probes.sh
. "$(dirname "$0")/probes.sh"

for tool in docker curl jq python3 timeout nice flock; do
  need "$tool"
done

mkdir -p "$root/.wonton"
exec 9>"$root/.wonton/smoke.lock"
flock -n 9 || die "同一仓库的另一套冒烟正在跑"

work="$(mktemp -d "${TMPDIR:-/tmp}/wonton-smoke.XXXXXX")"
copy="$work/repo"
LOG="$root/.wonton/smoke.log"
: >"$LOG"
instance="smoke$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
SMOKE_DIR="$copy"
SMOKE_STATE="$copy/.wonton"
SMOKE_INSTANCE="$instance"
SMOKE_JAR="$copy/.wonton/session.cookies"
SMOKE_TOOLS="$work/tools.json"
PROBES_LOG="$LOG"

# #121：宿主机配了 Docker 客户端代理时，容器会带上 HTTP_PROXY，Hydra 的回环健康检查一直失败。
# 去掉 config.json 的 proxies，其余（凭据、context）留着。
docker_config="${DOCKER_CONFIG:-$HOME/.docker}"
if [[ -f "$docker_config/config.json" ]]; then
  mkdir -p "$work/docker-config"
  cp -a "$docker_config/." "$work/docker-config/"
  jq 'del(.proxies)' "$docker_config/config.json" >"$work/docker-config/config.json"
  export DOCKER_CONFIG="$work/docker-config"
fi

cleanup() {
  local image=""
  image="$(sed -n 's/^WONTON_CORE_IMAGE=//p' "$copy/.wonton/.env" 2>/dev/null | tail -1)"
  if [[ -f "$copy/.wonton/.env" ]]; then
    say "清理实例 $instance"
    (cd "$copy" && nice -n 19 timeout 900 scripts/dev.sh purge --yes) >>"$LOG" 2>&1
  fi
  docker ps -aq --filter "label=wonton.instance=$instance" | xargs -r docker rm -f >/dev/null 2>&1
  docker network ls -q --filter "label=wonton.instance=$instance" | xargs -r docker network rm >/dev/null 2>&1
  docker volume ls -q --filter "label=wonton.instance=$instance" | xargs -r docker volume rm >/dev/null 2>&1
  # 核心以 root 写数据目录，普通用户的 rm 删不动；purge 也失败时交给容器里的 root 删。
  if ! rm -rf "$work" 2>/dev/null; then
    [[ -n "$image" ]] && docker run --rm --user 0 --entrypoint rm -v "${work%/*}:/host-tmp" "$image" \
      -rf "/host-tmp/${work##*/}" >/dev/null 2>&1
    rm -rf "$work" 2>/dev/null
  fi
  local left
  left="$(docker ps -aq --filter "label=wonton.instance=$instance" | wc -l)"
  say "残留资源（实例 $instance）：$left"
  if [[ "$left" != 0 ]]; then
    echo "FAIL 清理：残留 $left 个资源"
    DID_FAIL=1
  fi
}

finish() {
  local rc=$?
  trap - EXIT
  cleanup || true
  if ((rc != 0)); then
    exit "$rc"
  elif ((DID_FAIL)); then
    echo
    echo "失败详情：$LOG"
    exit 1
  fi
  exit 0
}
trap finish EXIT

# 共用一台 Docker 时可以限制同时跑的验证栈：WONTON_SMOKE_MAX_STACKS=<套数>（只数别人的，自己还没起），
# WONTON_SMOKE_WAIT_MINUTES 是最多等多久（默认 45）。不设就不排队：自己的开发环境也算一套，默认限制会挡住只有一个人的主机。
if [[ -n "${WONTON_SMOKE_MAX_STACKS:-}" ]]; then
  [[ "$WONTON_SMOKE_MAX_STACKS" =~ ^[1-9][0-9]*$ ]] || die "WONTON_SMOKE_MAX_STACKS 要是正整数：$WONTON_SMOKE_MAX_STACKS"
  wait_minutes="${WONTON_SMOKE_WAIT_MINUTES:-45}"
  [[ "$wait_minutes" =~ ^[0-9]+$ ]] || die "WONTON_SMOKE_WAIT_MINUTES 要是整数：$wait_minutes"
  waited=0
  while foreign="$(docker ps --filter 'label=wonton.instance' --format '{{.Label "wonton.instance"}}' | sort -u | wc -l)"
    ((foreign >= WONTON_SMOKE_MAX_STACKS)); do
    ((waited == 0)) && say "已有 $foreign 套验证栈在跑（上限 $WONTON_SMOKE_MAX_STACKS），排队等待"
    ((waited >= wait_minutes)) && die "等了 $wait_minutes 分钟还是 $foreign 套验证栈，排队放弃（没有跑任何插件检查）"
    sleep 60
    waited=$((waited + 1))
  done
fi

say "复制工作区（不动 .wonton）"
mkdir "$copy"
tar -C "$root" --exclude=.wonton --exclude=.git -cf - . | tar -C "$copy" -xf - || die "复制工作区失败"
chmod -R a+rX "$copy"

probes_facts "$copy"
probes_load

# ---------- 1. 装得上 ----------
say "1. 装得上（check --official、install、running healthy）"
chk_out="$(cd "$copy" && nice -n 19 timeout 900 scripts/check.sh --official 2>&1)" && chk_rc=0 || chk_rc=$?
printf '%s\n' "$chk_out" >>"$LOG"
chk_first="$(head -1 <<<"$chk_out")"
if ((chk_rc != 0)); then
  fail 装得上 "check.sh --official 退出 $chk_rc：$chk_first"
  chk_note="check 不合格（$chk_first）；"
else
  chk_note="check --official 通过；"
fi

if ! probes_dev up >>"$LOG" 2>&1; then
  fail 装得上 "dev.sh up 失败，看 $LOG"
  for item in 网页打得开 用户身份能用 工具Bot调得到; do fail "$item" "环境没起来"; done
  exit 0
fi
probes_env || { fail 装得上 "读不到用户令牌"; exit 0; }

if [[ -n "${WONTON_DEV_EGRESS_PROXY:-}" ]]; then
  say "配置出口代理 $WONTON_DEV_EGRESS_PROXY"
  cur="$(smoke_api GET /_wonton/api/egress-proxy)" || { fail 装得上 "读不到出口代理设置"; exit 0; }
  body="$(jq -nc --arg u "$WONTON_DEV_EGRESS_PROXY" --argjson r "$(jq -c '[.restarts[].id]' <<<"$cur")" \
    '{url:$u,direct_cidrs:[],restarts:$r}')"
  smoke_api PUT /_wonton/api/egress-proxy -H 'Content-Type: application/json' -d "$body" >/dev/null ||
    { fail 装得上 "配置出口代理失败"; exit 0; }
  probe="$cur"
  for _ in $(seq 1 60); do
    probe="$(smoke_api GET /_wonton/api/egress-proxy)" || break
    [[ "$(jq -r '.plugin_path.problem // "none"' <<<"$probe")" == none ]] && break
    sleep 2
  done
  [[ "$(jq -r '.plugin_path.problem // "none"' <<<"$probe")" == none ]] ||
    { fail 装得上 "出口代理探测没通：$(jq -c '.plugin_path' <<<"$probe")"; exit 0; }
fi

# Hermes 是核心预装的默认 Agent：工具 Bot 要用，装得上这项也确认它健康（不锁版本）。
hermes_line="$(probes_status_wait com.nousresearch.hermes 40)" ||
  { fail 装得上 "预装 Hermes 不是 running healthy：$hermes_line"; exit 0; }
say "Hermes：$hermes_line"
if [[ "$(jq -r '(."x-wonton".permissions // []) | index("models") // empty' <<<"$PROBES_FACTS")" != "" ]]; then
  magpie_line="$(probes_status_wait ai.usemagpie.magpie 30)" ||
    { fail 装得上 "模型网关不是 running healthy：$magpie_line"; exit 0; }
fi

if declare -F before_install >/dev/null; then
  say "装前准备（before_install）"
  before_install >>"$LOG" 2>&1 || { fail 装得上 "before_install 失败，看 $LOG"; exit 0; }
fi
if ! probes_dev install --yes >>"$LOG" 2>&1; then
  fail 装得上 "dev.sh install --yes 失败，看 $LOG"
  for item in 网页打得开 用户身份能用 工具Bot调得到; do fail "$item" "装不上"; done
  exit 0
fi
line="$(probes_status_wait "$PROBES_PLUGIN_ID" 40)" || { fail 装得上 "状态不是 running healthy：$line"; exit 0; }
if ((chk_rc != 0)); then
  fail 装得上 "$chk_note install 后状态 running healthy"
else
  pass 装得上 "${chk_note}install 后状态 running healthy（$line）；Hermes running healthy"
fi

# 探针部分：网页打得开、用户身份能用、工具 Bot 调得到，和 dev.sh probes 共用。
probes_run
