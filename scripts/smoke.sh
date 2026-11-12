#!/usr/bin/env bash
# 插件合并前的端到端冒烟：用工作区的插件起一套一次性开发环境，六项真实请求，不用 mock。
#   scripts/dev.sh smoke [--upgrade-from <tag>]
# 六项：装得上 / 网页打得开 / 用户身份能用 / 工具 Bot 调得到 / 升级保数据 / 重装保数据。任何 FAIL 退出非 0。
# 插件自己的探测在 scripts/smoke-probes.sh，写法见模板里的这个文件。
# 作者已有的 .wonton 不动：整个工作区复制到临时目录，用冒烟自己的实例，跑完删掉容器、网络、卷和目录。
#
# --upgrade-from：从哪个 tag 升级验证数据；默认取 git describe 到的最近 tag，本仓库没有 tag 时“升级保数据”记 N/A。
# WONTON_DEV_EGRESS_PROXY：给了就先把它配成核心的出口代理（插件冷启动要出网时用），不给就不配。
set -uo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
# 探针环境、公共助手和三项探针的调用在探针套件里，和 dev.sh probes 共用。
# shellcheck source=scripts/probes.sh
. "$(dirname "$0")/probes.sh"

usage() { sed -n '2,4p' "$0" >&2; exit 2; }
upgrade_from=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade-from) [[ $# -ge 2 && -n "$2" ]] || usage; upgrade_from="$2"; shift 2 ;;
    *) usage ;;
  esac
done

for tool in docker curl jq python3 timeout nice flock git; do
  need "$tool"
done

mkdir -p "$root/.wonton"
exec 9>"$root/.wonton/smoke.lock"
flock -n 9 || die "同一仓库的另一套冒烟正在跑"

# 状态目录放短路径：宿主网络插件的中继套接字在 <状态>/data/apps/<插件 id 把 . 换成 ->/relay/webui.sock，unix 套接字
# 路径最多 107 字节。/tmp/ws.XXXXXX/s 是 16 字节，id 最长 63 时正好 107。不用 TMPDIR：macOS 的 TMPDIR 在
# /var/folders/… 下，本身就有 40 多字节。
work="$(mktemp -d /tmp/ws.XXXXXX)"
copy="$work/repo"
LOG="$root/.wonton/smoke.log"
: >"$LOG"
instance="smoke$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
SMOKE_DIR="$copy"
SMOKE_DEV_STATE="$work/s"
# 数据标记是个空文件（与 e2e 冒烟的约定一致）：插件钩子只当它是文件，不往里建目录。
SMOKE_STATE="$work/data-marker"
: >"$SMOKE_STATE"
SMOKE_INSTANCE="$instance"
SMOKE_JAR="$SMOKE_DEV_STATE/session.cookies"
SMOKE_TOOLS="$work/tools.json"
PROBES_LOG="$LOG"

# #121：宿主机给 Docker 客户端配了代理时，容器会带上 HTTP_PROXY，Hydra 的回环健康检查一直失败。
# 剥代理的逻辑在 lib.sh 的 strip_docker_proxies，副本放在 $work 里跟着清理。
strip_docker_proxies "$work/docker-config"

cleanup() {
  local image=""
  image="$(sed -n 's/^WONTON_CORE_IMAGE=//p' "$SMOKE_DEV_STATE/.env" 2>/dev/null | tail -1)"
  if [[ -f "$SMOKE_DEV_STATE/.env" ]]; then
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

# 升级验证的起点：--upgrade-from 指定的 tag，或 git describe 到的最近 tag；没有 tag 就不测升级。
if [[ -z "$upgrade_from" ]]; then
  upgrade_from="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || true)"
else
  git -C "$root" rev-parse -q --verify "refs/tags/$upgrade_from^{commit}" >/dev/null ||
    die "本机没有 tag $upgrade_from"
fi
if [[ -n "$upgrade_from" && ! -d "$root/.git" ]]; then
  die "工作区没有 .git，装不了 tag $upgrade_from"
fi

say "复制工作区（不动 .wonton）"
mkdir "$copy"
tar -C "$root" --exclude=.wonton --exclude=.git -cf - . | tar -C "$copy" -xf - || die "复制工作区失败"
# dev.sh 从复制出来的工作区里 git archive 出 tag：.git 用符号链接指回原仓库，不复制对象。
[[ ! -d "$root/.git" ]] || ln -s "$root/.git" "$copy/.git"
chmod -R a+rX "$copy"

probes_facts "$copy"
probes_load

# ---------- 1. 装得上 ----------
say "1. 装得上（check、install、running healthy）"
chk_out="$(cd "$copy" && nice -n 19 timeout 900 scripts/check.sh 2>&1)" && chk_rc=0 || chk_rc=$?
printf '%s\n' "$chk_out" >>"$LOG"
chk_first="$(head -1 <<<"$chk_out")"
if ((chk_rc != 0)); then
  fail 装得上 "check.sh 退出 $chk_rc：$chk_first"
  chk_note="check 不合格（$chk_first）；"
else
  chk_note="check 通过；"
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

# 数据：先装升级起点（有 tag 时）写一条数据，再装工作区版本验证升级不丢；重装同理。
data_wrote=0
data_upgrade_base=0
if [[ "$DATA_NA" != 1 ]] && (( DATA_HOOKS )) && [[ -n "$upgrade_from" ]]; then
  say "装 tag $upgrade_from（写数据后升级）"
  if probes_dev_t 600 install --yes "$upgrade_from" >>"$LOG" 2>&1 &&
    probes_status_wait "$PROBES_PLUGIN_ID" 40 >/dev/null; then
    data_upgrade_base=1
    # 钩子要用网页地址和用户会话：这一轮在主安装之前，probes_run 还没取过、也没登录过。
    probes_dev session >>"$LOG" 2>&1 || say "升级起点上会话建立失败（data_write 可能 401）"
    if probes_web_url 升级保数据 && probes_data_write; then data_wrote=1; else
      fail 升级保数据 "data_write 失败（tag $upgrade_from），见 $LOG 末尾：$(tail -c 200 "$LOG" | tr '\n' ' ')"
    fi
  else
    fail 升级保数据 "装 tag $upgrade_from 失败或 600 秒超时，看 $LOG"
  fi
fi

# 装过升级起点时，核心不接受 install 覆盖已装的插件（同一版本号也一样）：升级用 reinstall，保留数据。
install_cmd=install
((data_upgrade_base == 1)) && install_cmd=reinstall
if ! probes_dev "$install_cmd" --yes >>"$LOG" 2>&1; then
  fail 装得上 "dev.sh $install_cmd --yes 失败，看 $LOG"
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
probes_run web_assert identity_check mcp

# ---------- 5/6. 升级/重装保数据 ----------
say "5/6. 升级保数据、重装保数据"
if [[ "$DATA_NA" == 1 ]]; then
  na 升级保数据 "${SMOKE_NOTE:+$SMOKE_NOTE；}插件声明 DATA_NA=1"
  na 重装保数据 "${SMOKE_NOTE:+$SMOKE_NOTE；}插件声明 DATA_NA=1"
elif (( DATA_HOOKS == 0 )); then
  fail 升级保数据 "没写数据钩子：在 scripts/smoke-probes.sh 写 data_write 和 data_check（没有用户数据就写 DATA_NA=1）"
  fail 重装保数据 "没写数据钩子：在 scripts/smoke-probes.sh 写 data_write 和 data_check（没有用户数据就写 DATA_NA=1）"
else
  if [[ -n "$upgrade_from" && "$data_upgrade_base" == 1 && "$data_wrote" == 1 ]]; then
    probes_data_check 升级保数据 "升级自 tag $upgrade_from"
  elif [[ -z "$upgrade_from" ]]; then
    na 升级保数据 "本仓库没有 tag，只测重装（可用 --upgrade-from 指定）"
  fi
  if [[ "$data_wrote" != 1 ]]; then
    if probes_data_write; then data_wrote=1; else
      fail 重装保数据 "data_write 失败，见 $LOG 末尾：$(tail -c 200 "$LOG" | tr '\n' ' ')"
    fi
  fi
  if [[ "$data_wrote" == 1 ]]; then
    if probes_dev_t 900 reinstall --yes >>"$LOG" 2>&1 &&
      probes_status_wait "$PROBES_PLUGIN_ID" 40 >/dev/null; then
      probes_data_check 重装保数据 "reinstall 后"
    else
      fail 重装保数据 "dev.sh reinstall 失败或 900 秒超时，看 $LOG"
    fi
  fi
fi
