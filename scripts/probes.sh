# shellcheck shell=bash
# 探针套件：准备探针环境、逐项调用 scripts/smoke-probes.sh 的探针并打印 PASS/FAIL/N/A。
# smoke.sh 和 dev.sh probes 共用这份逻辑，两边都不复制。调用方先设好：
#   PROBES_LOG     探针输出和失败详情追加到这里，FAIL 行摘录末尾
#   SMOKE_DIR      工作区目录（跑 scripts/dev.sh、找 smoke-probes.sh 的地方）
#   SMOKE_STATE    开发环境的状态目录（.wonton，里面有 .env）
#   SMOKE_INSTANCE 实例名
#   SMOKE_JAR      用户会话 cookie 的存放文件
#   SMOKE_TOOLS    MCP tools/list 的输出文件
# 然后按顺序：
#   probes_facts <目录>   解析清单，备好 PROBES_PLUGIN_ID/SLUG/HAS_WEBUI/SSO/HAS_MCP（原文在 PROBES_FACTS）
#   probes_load           读插件的 smoke-probes.sh（没有这个文件时，后面按“没写探测”处理）
#   probes_env            实例起来以后调用：备好 SMOKE_* 变量和 dweb/web_get/mcp/smoke_api 助手
#   probes_run [探针名…]  跑 web_assert / identity_check / mcp 三项，不给名字就全跑
# 有 FAIL 时 DID_FAIL=1，退出码由调用方定；这里的函数不 exit，停不停由调用方决定。
DID_FAIL=0

say() { echo "== $*"; }
pass() { echo "PASS $1：$2"; }
fail() { echo "FAIL $1：$2"; DID_FAIL=1; }
na() { echo "N/A  $1：$2"; }

# 探针里跑 dev.sh 子命令都走这里：cd 到工作区，指到自己的状态目录和实例。
probes_dev() {
  (cd "$SMOKE_DIR" && WONTON_DEV_STATE="$SMOKE_STATE" WONTON_INSTANCE="$SMOKE_INSTANCE" nice -n 19 scripts/dev.sh "$@")
}

probes_setting() { # 状态目录 .env 里的一项设置
  sed -n "s/^$1=//p" "$SMOKE_STATE/.env" | tail -1
}

probes_facts() { # <仓库目录>：清单事实；compose 自己解析，不引额外依赖
  local dir="$1" facts
  facts="$(cd "$dir" && docker compose -f docker-compose.yml config --no-interpolate --format json)" ||
    die "解析不了 docker-compose.yml"
  # shellcheck disable=SC2034 # PROBES_FACTS 给调用方用（smoke 按它决定要不要等模型网关）
  PROBES_FACTS="$facts"
  PROBES_PLUGIN_ID="$(jq -r '."x-wonton".id // empty' <<<"$facts")"
  [[ -n "$PROBES_PLUGIN_ID" ]] || die "清单没有 x-wonton.id"
  PROBES_SLUG="${PROBES_PLUGIN_ID//./-}"
  PROBES_HAS_WEBUI="$(jq -r 'if ."x-wonton".webui.service then 1 else 0 end' <<<"$facts")"
  PROBES_SSO="$(jq -r '."x-wonton".webui.sso // "none"' <<<"$facts")"
  PROBES_HAS_MCP="$(jq -r 'if ."x-wonton".mcp.service then 1 else 0 end' <<<"$facts")"
}

probes_load() { # 读插件的探针；探针里可用的变量和助手在 probes_env 里备齐
  IDENTITY_NA=0
  MCP_TOOL=""
  MCP_ARGS='{}'
  SMOKE_NOTE=""
  export WONTON_OWNER_EMAIL="${WONTON_OWNER_EMAIL:-owner@$SMOKE_INSTANCE.wonton.localhost}"
  if [[ -f "$SMOKE_DIR/scripts/smoke-probes.sh" ]]; then
    # shellcheck source=scripts/smoke-probes.sh
    . "$SMOKE_DIR/scripts/smoke-probes.sh"
  fi
}

probes_env() { # 实例起来以后调用；读不到用户令牌时返回 1
  local port
  port="$(probes_setting WONTON_PORT)"
  SMOKE_BASE="http://$SMOKE_INSTANCE.wonton.localhost:$port"
  SMOKE_TOKEN="$(probes_dev token)" || return 1
  SMOKE_OWNER="$(docker exec "wonton-$SMOKE_INSTANCE--core" cat "$(probes_setting WONTON_DATA_DIR)/core/owner.json" 2>/dev/null | jq -r '.username // empty')"
  SMOKE_OWNER="${SMOKE_OWNER:-owner}"
  SMOKE_OWNER_EMAIL="$(probes_setting WONTON_OWNER_EMAIL)"
  SMOKE_PLUGIN_ID="$PROBES_PLUGIN_ID" SMOKE_SLUG="$PROBES_SLUG" SMOKE_SSO="$PROBES_SSO"
  SMOKE_MCP="$PROBES_HAS_MCP" SMOKE_WEBUI="$PROBES_HAS_WEBUI"
  export SMOKE_DIR SMOKE_STATE SMOKE_INSTANCE SMOKE_JAR SMOKE_TOOLS SMOKE_BASE SMOKE_TOKEN SMOKE_OWNER SMOKE_OWNER_EMAIL
  export SMOKE_PLUGIN_ID SMOKE_SLUG SMOKE_SSO SMOKE_MCP SMOKE_WEBUI
}

# 公共助手，给探针用：dweb / web_get 带用户的会话，mcp 走同一套 dev.sh 入口，smoke_api 带用户令牌调核心。
dweb() { probes_dev web --jar "$SMOKE_JAR" "$@"; }
web_get() { local path="$1"; shift; curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" "$@" "$SMOKE_WEB_URL$path"; }
mcp() {
  local sub="${1:-}"
  shift || true
  if [[ "${1:-}" == http* ]]; then shift; fi
  probes_dev mcp "$sub" "$@"
}
smoke_api() {
  local method="$1" path="$2"
  shift 2
  curl -sS --noproxy '*' --fail-with-body -X "$method" -H "Authorization: Bearer $SMOKE_TOKEN" "$@" "$SMOKE_BASE$path"
}

probes_web_url() { # 从核心的插件列表拿网页地址；拿不到时给列出的项标 FAIL，返回 1（后面的探针别跑了）
  local plugins_json item
  if plugins_json="$(smoke_api GET /_wonton/api/plugins)"; then
    SMOKE_WEB_URL="$(jq -rn --arg id "$SMOKE_PLUGIN_ID" --arg json "$plugins_json" '$json | fromjson | .plugins[] | select(.id==$id) | .web_url // ""')"
    export SMOKE_WEB_URL
    return 0
  fi
  for item in "$@"; do fail "$item" "列不出插件"; done
  return 1
}

probes_status_wait() { # <插件 id> <次数>：等状态变成 running healthy
  local id="$1" tries="$2" i out line=""
  for ((i = 0; i < tries; i++)); do
    out="$(probes_dev status 2>>"$PROBES_LOG")"
    line="$(grep -F "$id" <<<"$out" | head -1)"
    if grep -q $'\trunning healthy\t' <<<"$line"; then
      printf '%s\n' "$line"
      return 0
    fi
    sleep 15
  done
  printf '%s\n' "$line"
  return 1
}

probes_web() { # 网页打得开：网关要拒绝匿名请求，页面特征要命中应用的真实页面
  local unauth_code unauth_evi loc body
  if [[ "$SMOKE_WEBUI" != 1 ]]; then
    na 网页打得开 "清单没有 webui"
    return 0
  fi
  probes_dev session >>"$PROBES_LOG" 2>&1 || say "会话建立失败（后面的探测会失败）"
  unauth_code="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 60 "$SMOKE_WEB_URL/")"
  unauth_evi="匿名返回 $unauth_code"
  case "$unauth_code" in
    401) unauth_evi="匿名 401" ;;
    301|302|303|307|308)
      loc="$(curl -sS --noproxy '*' -o /dev/null -w '%{redirect_url}' --max-time 60 "$SMOKE_WEB_URL/")"
      unauth_evi="匿名 $unauth_code → $loc"
      grep -q "/_wonton/login" <<<"$loc" && unauth_evi="$unauth_evi（核心登录页）" ;;
  esac
  case "$unauth_evi" in
    *"匿名 401"* | *"核心登录页"*) : ;;
    *) fail 网页打得开 "网关没拒绝匿名请求：$unauth_evi" ;;
  esac
  body="$(dweb / -L 2>>"$PROBES_LOG")" || { say "dweb 失败一次，重试"; body="$(dweb / -L 2>>"$PROBES_LOG")" || body=""; }
  if ! declare -F web_assert >/dev/null; then
    fail 网页打得开 "没写探测：在 scripts/smoke-probes.sh 里写 web_assert（标准输入读页面，命中真实页面时返回 0）；$unauth_evi"
  elif [[ -n "$body" ]] && web_assert <<<"$body" >>"$PROBES_LOG" 2>&1; then
    pass 网页打得开 "应用真实页面特征命中；$unauth_evi"
  else
    fail 网页打得开 "页面特征没命中，开头：$(head -c 200 <<<"$body" | tr '\n' ' ')"
  fi
}

probes_identity() { # 用户身份能用：应用认出的是用户管理员
  if [[ "$SMOKE_WEBUI" != 1 ]]; then
    na 用户身份能用 "清单没有 webui"
  elif [[ "$IDENTITY_NA" == 1 ]]; then
    na 用户身份能用 "${SMOKE_NOTE:-应用没有可断言的用户体系}"
  elif ! declare -F identity_check >/dev/null; then
    fail 用户身份能用 "没写探测：在 scripts/smoke-probes.sh 里写 identity_check（调应用自己的当前用户接口，断言是用户管理员；没有用户体系就写 IDENTITY_NA=1）"
  elif identity_check >>"$PROBES_LOG" 2>&1; then
    pass 用户身份能用 "sso=$SMOKE_SSO：应用认出用户 $SMOKE_OWNER（管理员）"
  else
    fail 用户身份能用 "identity_check 失败，见 $PROBES_LOG 末尾：$(tail -c 200 "$PROBES_LOG" | tr '\n' ' ')"
  fi
}

probes_mcp() { # 工具 Bot 调得到：tools/list 有本插件工具，只读调用返回符合预期
  local gw hermes_line out tool ann n_mine err
  if [[ "$SMOKE_MCP" != 1 ]]; then
    na 工具Bot调得到 "清单没有 mcp"
    return 0
  fi
  if [[ ! -f "$SMOKE_DIR/scripts/smoke-probes.sh" ]]; then
    fail 工具Bot调得到 "没写探测：在 scripts/smoke-probes.sh 里写 MCP_TOOL=<只读工具>、MCP_ARGS 和 mcp_assert（标准输入读结果）"
    return 0
  fi
  if [[ -z "$MCP_TOOL" ]] && ! declare -F mcp_check >/dev/null; then
    fail 工具Bot调得到 "没写探测：在 scripts/smoke-probes.sh 里写 MCP_TOOL=<只读工具>、MCP_ARGS 和 mcp_assert"
    return 0
  fi
  gw="wonton-$SMOKE_INSTANCE--com-nousresearch-hermes--gateway"
  hermes_line="$(probes_status_wait com.nousresearch.hermes 40)" ||
    { fail 工具Bot调得到 "Hermes 不是 running healthy：$hermes_line"; return 1; }
  if declare -F before_mcp >/dev/null; then
    before_mcp >>"$PROBES_LOG" 2>&1 ||
      { fail 工具Bot调得到 "工具的准备工作（before_mcp）失败，见 $PROBES_LOG 末尾：$(tail -c 200 "$PROBES_LOG" | tr '\n' ' ')"; return 0; }
  fi
  SMOKE_MCP_URL="$(docker exec "$gw" printenv WONTON_MCP_URL 2>>"$PROBES_LOG")" ||
    { fail 工具Bot调得到 "gateway 容器里没有 WONTON_MCP_URL"; return 1; }
  export SMOKE_MCP_URL
  err="$SMOKE_TOOLS.err"
  mcp list >"$SMOKE_TOOLS" 2>"$err" ||
    { fail 工具Bot调得到 "MCP initialize/tools/list 失败：$(head -c 300 "$err" | tr '\n' ' ')"; return 1; }
  n_mine="$(jq --arg s "$SMOKE_SLUG" '[.[] | select(.name | startswith($s + "__"))] | length' "$SMOKE_TOOLS")"
  say "MCP 通了，本插件前缀工具 $n_mine 个"
  if declare -F mcp_check >/dev/null; then
    if mcp_check >>"$PROBES_LOG" 2>&1; then
      pass 工具Bot调得到 "tools/list 有本插件工具，只读调用返回符合预期"
    else
      fail 工具Bot调得到 "mcp_check 失败，见 $PROBES_LOG 末尾：$(tail -c 200 "$PROBES_LOG" | tr '\n' ' ')"
    fi
  elif [[ "$n_mine" -lt 1 ]]; then
    fail 工具Bot调得到 "tools/list 没有 ${SMOKE_SLUG}__ 前缀工具"
  elif [[ -z "$MCP_TOOL" ]]; then
    pass 工具Bot调得到 "tools/list 有本插件工具（探测没指定只读工具）"
  else
    tool="$MCP_TOOL"
    grep -q "__" <<<"$tool" || tool="${SMOKE_SLUG}__${tool}"
    ann="$(jq -r --arg t "$tool" '.[] | select(.name == $t) | .annotations.readOnlyHint // "missing"' "$SMOKE_TOOLS")"
    if [[ "$ann" != true ]]; then
      fail 工具Bot调得到 "$tool 不在 tools/list 或没标 readOnlyHint=true（$ann）"
    elif out="$(mcp call "$SMOKE_MCP_URL" "$tool" "$MCP_ARGS" 2>&1)"; then
      if declare -F mcp_assert >/dev/null && ! mcp_assert <<<"$out" >>"$PROBES_LOG" 2>&1; then
        fail 工具Bot调得到 "$tool 的结果不符合预期：$(head -c 200 <<<"$out" | tr '\n' ' ')"
      else
        pass 工具Bot调得到 "tools/list 有本插件工具，真实调用只读工具 $tool 成功"
      fi
    else
      fail 工具Bot调得到 "调用只读工具 $tool 失败：$(head -c 300 <<<"$out" | tr '\n' ' ')"
    fi
  fi
}

probes_run() { # [探针名…]：跑探针项（web_assert、identity_check、mcp），不给名字就全跑
  local name web=0 identity=0 mcp=0
  for name in "$@"; do
    case "$name" in
      web_assert | identity_check | mcp) ;;
      *) die "不认识的探针名：$name（可选 web_assert、identity_check、mcp）" ;;
    esac
  done
  if (($# == 0)); then
    web=1 identity=1 mcp=1
  else
    for name in "$@"; do
      case "$name" in
        web_assert) web=1 ;;
        identity_check) identity=1 ;;
        mcp) mcp=1 ;;
      esac
    done
  fi
  if ((web || identity)); then
    say "2/3. 网页打得开与用户身份能用"
    local -a web_items=()
    ((web)) && web_items+=(网页打得开)
    ((identity)) && web_items+=(用户身份能用)
    if probes_web_url "${web_items[@]}"; then
      ((web)) && probes_web
      ((identity)) && probes_identity
    fi
  fi
  if ((mcp)); then
    say "4. 工具 Bot 调得到"
    probes_mcp
  fi
  return 0
}

# shellcheck disable=SC2154 # root、state、instance 由 dev.sh 加载设置。
probes_cmd() { # dev.sh probes 的入口：对开发环境里装着的工作区插件跑探针，不起新实例、不卸载、不清理
  need jq nice
  need_env
  probes_facts "$root"
  local result
  if ! result="$(api GET "/_wonton/api/plugins/$PROBES_PLUGIN_ID" 2>/dev/null)"; then
    [[ "$result" == *'"not_installed"'* ]] || die "查不到 $PROBES_PLUGIN_ID 装没装：$(error_text "$result")"
    die "$PROBES_PLUGIN_ID 还没装：先 scripts/dev.sh install"
  fi
  # 探针按 smoke 的容错跑：单项 FAIL 不中断，最后按 DID_FAIL 定退出码。
  set +e
  PROBES_LOG="$state/probes.log"
  : >"$PROBES_LOG"
  SMOKE_DIR="$root"
  SMOKE_STATE="$state"
  SMOKE_INSTANCE="$instance"
  SMOKE_JAR="$(session_jar)"
  SMOKE_TOOLS="$state/probes-tools.json"
  probes_load
  probes_env || die "读不到用户令牌：核心没在运行？先 scripts/dev.sh up"
  probes_run "$@"
  if ((DID_FAIL)); then exit 1; fi
}
