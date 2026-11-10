# shellcheck shell=bash
# 探针套件：准备探针环境、逐项调用 scripts/smoke-probes.sh 的探针并打印 PASS/FAIL/N/A。
# smoke.sh 和 dev.sh probes 共用这份逻辑，两边都不复制。调用方先设好：
#   PROBES_LOG     探针输出和失败详情追加到这里，FAIL 行摘录末尾
#   SMOKE_DIR      工作区目录（跑 scripts/dev.sh、找 smoke-probes.sh 的地方）
#   SMOKE_DEV_STATE 开发环境的状态目录（.wonton，里面有 .env），套件自己用，不给插件钩子
#   SMOKE_STATE    数据标记文件：调用方先建成空文件，data_write 覆盖写、data_check 读（插件钩子只认它是文件）
#   SMOKE_INSTANCE 实例名
#   SMOKE_JAR      用户会话 cookie 的存放文件
#   SMOKE_TOOLS    MCP tools/list 的输出文件
# 然后按顺序：
#   probes_facts <目录>   解析清单，备好 PROBES_PLUGIN_ID/SLUG/HAS_WEBUI/SSO/HAS_MCP（原文在 PROBES_FACTS）
#   probes_load           读插件的 smoke-probes.sh（没有这个文件时，后面按“没写探测”处理）
#   probes_env            实例起来以后调用：备好 SMOKE_* 变量和 dweb/web_get/mcp/smoke_api 助手
#   probes_run [探针名…]  跑 web_assert / identity_check / mcp / data_write / data_check 各项，不给名字就全跑
# 有 FAIL 时 DID_FAIL=1，退出码由调用方定；这里的函数不 exit，停不停由调用方决定。
# 数据探针 data_write / data_check：插件不存用户数据时写 DATA_NA=1（两项记 N/A）。
DID_FAIL=0

say() { echo "== $*"; }
pass() { echo "PASS $1：$2"; }
fail() { echo "FAIL $1：$2"; DID_FAIL=1; }
na() { echo "N/A  $1：$2"; }

# 探针里跑 dev.sh 子命令都走这里：cd 到工作区，指到自己的状态目录和实例。
probes_dev() {
  (cd "$SMOKE_DIR" && WONTON_DEV_STATE="$SMOKE_DEV_STATE" WONTON_INSTANCE="$SMOKE_INSTANCE" nice -n 19 scripts/dev.sh "$@")
}

# 装 tag、reinstall 限时：卡住时如实记 FAIL，不把名额占死。
probes_dev_t() { # <秒数> <dev.sh 参数…>
  local secs="$1"; shift
  (cd "$SMOKE_DIR" && WONTON_DEV_STATE="$SMOKE_DEV_STATE" WONTON_INSTANCE="$SMOKE_INSTANCE" nice -n 19 timeout "$secs" scripts/dev.sh "$@")
}

probes_setting() { # 状态目录 .env 里的一项设置
  sed -n "s/^$1=//p" "$SMOKE_DEV_STATE/.env" | tail -1
}

# 核心的基础域名，不是实例名：别的栈写 WONTON_BASE_DOMAIN，从主仓库抄成 WONTON_DEV_DOMAIN 的也认；都没写时按
# 实例名兜底。
probes_domain() {
  local domain
  domain="$(probes_setting WONTON_BASE_DOMAIN)"
  [[ -n "$domain" ]] || domain="$(probes_setting WONTON_DEV_DOMAIN)"
  printf '%s\n' "${domain:-$SMOKE_INSTANCE.wonton.localhost}"
}

# 插件钩子限时跑：函数开在子 shell 里（能看见调用方的函数和变量），超时就杀掉。
probes_hook() { # <函数名> [秒数]
  local fn="$1" secs="${2:-300}" pid i
  "$fn" >>"$PROBES_LOG" 2>&1 &
  pid=$!
  for ((i = 0; i < secs; i++)); do
    jobs -pr | grep -qx "$pid" || { wait "$pid"; return $?; }
    sleep 1
  done
  kill "$pid" 2>/dev/null
  wait "$pid"
  echo "$fn 超过 ${secs}s 没结束" >>"$PROBES_LOG"
  return 124
}

probes_data_write() { # 跑 data_write；标记由插件存进 $SMOKE_STATE
  probes_hook data_write
}

probes_data_check() { # <结果项> [补充说明]：跑 data_check，对不上记该项 FAIL
  local item="$1" note="${2:+$2：}"
  if probes_hook data_check; then
    pass "$item" "${note}data_check 找到了写进去的数据"
  else
    fail "$item" "${note}data_check 对不上，见 $PROBES_LOG 末尾：$(tail -c 200 "$PROBES_LOG" | tr '\n' ' ')"
  fi
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
  DATA_NA=0
  MCP_TOOL=""
  MCP_ARGS='{}'
  SMOKE_NOTE=""
  export WONTON_OWNER_EMAIL="${WONTON_OWNER_EMAIL:-owner@$(probes_domain)}"
  if [[ -f "$SMOKE_DIR/scripts/smoke-probes.sh" ]]; then
    # shellcheck source=scripts/smoke-probes.sh
    . "$SMOKE_DIR/scripts/smoke-probes.sh"
  fi
  DATA_HOOKS=0
  if declare -F data_write >/dev/null && declare -F data_check >/dev/null; then DATA_HOOKS=1; fi
}

probes_env() { # 实例起来以后调用；读不到用户令牌时返回 1
  local port
  port="$(probes_setting WONTON_PORT)"
  SMOKE_BASE="http://$(probes_domain):$port"
  SMOKE_TOKEN="$(probes_dev token)" || return 1
  SMOKE_OWNER="$(docker exec "wonton-$SMOKE_INSTANCE--core" cat "$(probes_setting WONTON_DATA_DIR)/core/owner.json" 2>/dev/null | jq -r '.username // empty')"
  SMOKE_OWNER="${SMOKE_OWNER:-owner}"
  SMOKE_OWNER_EMAIL="$(probes_setting WONTON_OWNER_EMAIL)"
  SMOKE_PLUGIN_ID="$PROBES_PLUGIN_ID" SMOKE_SLUG="$PROBES_SLUG" SMOKE_SSO="$PROBES_SSO"
  SMOKE_MCP="$PROBES_HAS_MCP" SMOKE_WEBUI="$PROBES_HAS_WEBUI"
  SMOKE_CORE="wonton-$SMOKE_INSTANCE--core"
  SMOKE_DATA_DIR="$(probes_setting WONTON_DATA_DIR)"
  export SMOKE_DIR SMOKE_STATE SMOKE_INSTANCE SMOKE_JAR SMOKE_TOOLS SMOKE_BASE SMOKE_TOKEN SMOKE_OWNER SMOKE_OWNER_EMAIL
  export SMOKE_PLUGIN_ID SMOKE_SLUG SMOKE_SSO SMOKE_MCP SMOKE_WEBUI SMOKE_CORE SMOKE_DATA_DIR
  export SMOKE_WEB_MAX_TIME SMOKE_API_MAX_TIME
}

# 公共助手，给探针用：dweb / web_get 带用户的会话，mcp 走同一套 dev.sh 入口，smoke_api 带用户令牌调核心。
# SMOKE_WEB_URL 是网页入口（probes_web_url 已去尾斜杠，但可能带路径，如 SSO 登录页），web_get 把路径直接接在它后面；
# 探针拼应用的 API 路径用 SMOKE_WEB_ORIGIN（只有 scheme://host:port，入口的路径不掺进来）。
dweb() { probes_dev web --jar "$SMOKE_JAR" "$@"; }
# web_get 和 smoke_api 的秒数由调用方定（SMOKE_WEB_MAX_TIME / SMOKE_API_MAX_TIME，见 lib.sh），超时在 stderr
# 写清地址和秒数，git grep 得到的调用处不用各自再记时间。
web_get() { local path="$1"; shift; curl_t "$SMOKE_WEB_MAX_TIME" "$SMOKE_WEB_URL$path" --noproxy '*' -b "$SMOKE_JAR" "$@"; }
mcp() {
  local sub="${1:-}"
  shift || true
  if [[ "${1:-}" == http* ]]; then shift; fi
  probes_dev mcp "$sub" "$@"
}
smoke_api() {
  local method="$1" path="$2"
  shift 2
  curl_t "$SMOKE_API_MAX_TIME" "$SMOKE_BASE$path" --noproxy '*' -X "$method" \
    -H "Authorization: Bearer $SMOKE_TOKEN" "$@"
}

# 通知房间：核心以核心账号发进和主人的“Wonton”私聊。开发环境里主人不在宿主机上登录 Matrix，
# 这里用 Tuwunel 的管理接口临时登录主人拿一个令牌，探针结束后退出登录。Tuwunel 只在核心网络上，请求在核心
# 容器里用 bash 的 /dev/tcp 发出：核心镜像没有 curl，也不为此拉镜像。令牌只走环境变量，不进日志。
probes_matrix() { # <方法> <路径> [JSON 正文]：响应正文到标准输出
  local method="$1" path="$2" body="${3:-}"
  # shellcheck disable=SC2016 # 单引号里是核心容器里 bash 的变量
  docker exec -e MATRIX_TOKEN="${MATRIX_TOKEN:-}" "$SMOKE_CORE" bash -c '
    exec 3<>/dev/tcp/tuwunel.wonton.internal/8008 || exit 1
    printf "%s %s HTTP/1.0\r\nHost: tuwunel.wonton.internal\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
      "$1" "$2" "$MATRIX_TOKEN" "${#3}" "$3" >&3
    sed "1,/^\r$/d" <&3
  ' -- "$method" "$path" "$body"
}

# 以主人身份等通知房间里新出现包含这段文字的消息：<超时秒> <要找的文字>。成功返回 0 并打印命中的消息；超时
# 返回 1 并列出房间最新的消息和最后一次错误。要先把等待挂到后台再发通知（见 smoke-probes.sh 的例子）。
probes_owner_room_wait() { # <超时秒> <要找的文字>
  local secs="$1" text="$2" since deadline login user server who room="" room_url json found seen="" err="" rc=1
  [[ "$secs" =~ ^[1-9][0-9]*$ ]] || die "超时秒数要是正整数：$secs"
  [[ -n "${SMOKE_CORE:-}" ]] || die "probes_owner_room_wait 要在 probes_env 之后调用"
  since="$(($(date +%s) * 1000))"
  MATRIX_TOKEN="$(docker exec "$SMOKE_CORE" cat "$SMOKE_DATA_DIR/core/matrix-admin-token" 2>/dev/null)" ||
    { echo "读不到核心的 Matrix 管理令牌：核心没在运行？"; return 1; }
  # 服务器名以 Tuwunel 自己的为准，不按基础域名拼。
  who="$(probes_matrix GET /_matrix/client/v3/account/whoami)" || who=""
  server="$(jq -r '.user_id // empty | split(":")[1:] | join(":")' <<<"$who" 2>/dev/null)" || server=""
  if [[ -z "$server" ]]; then
    echo "认不出 Matrix 的服务器名：$(head -c 300 <<<"$who")"
    return 1
  fi
  user="@$SMOKE_OWNER:$server"
  login="$(probes_matrix POST "/_synapse/admin/v1/users/$(jq -rn --arg u "$user" '$u | @uri')/login" '{}')" || login=""
  MATRIX_TOKEN="$(jq -r '.access_token // empty' <<<"$login" 2>/dev/null)"
  if [[ -z "$MATRIX_TOKEN" ]]; then
    echo "登录 $user 拿不到 Matrix 令牌：$(head -c 300 <<<"$login")"
    return 1
  fi
  deadline=$((SECONDS + secs))
  while ((SECONDS < deadline)); do
    # 房间还没建（核心没发过通知）、或者旧的房间被换掉时会重读；只要开始之后发来的消息。
    local known
    known="$(docker exec "$SMOKE_CORE" cat "$SMOKE_DATA_DIR/core/matrix-notice-room" 2>/dev/null)" || known=""
    if [[ -n "$known" && "$known" != "$room" ]]; then
      room="$known"
      room_url="$(jq -rn --arg r "$room" '$r | @uri')"
    fi
    if [[ -z "$room" ]]; then
      err="通知房间还没建：核心还没发过通知"
    else
      json="$(probes_matrix GET "/_matrix/client/v3/rooms/$room_url/messages?dir=b&limit=30")" || json=""
      found="$(jq -r --arg t "$text" --argjson s "$since" \
        '[.chunk[]? | select(.type == "m.room.message" and (.origin_server_ts // 0) >= $s
          and ((.content.body // "") | contains($t))) | .content.body] | first // empty' <<<"$json" 2>/dev/null)" || found=""
      if [[ -n "$found" ]]; then
        echo "通知房间里出现了“$text”：$found"
        rc=0
        break
      fi
      seen="$(jq -r '[.chunk[]? | select(.type == "m.room.message") | .content.body // ""] | .[:3] | join(" ／ ")' <<<"$json" 2>/dev/null)" || seen=""
      err="$(jq -r '.errcode // empty' <<<"$json" 2>/dev/null)" || err=""
    fi
    sleep 1
  done
  probes_matrix POST /_matrix/client/v3/logout '{}' >/dev/null || true
  MATRIX_TOKEN=""
  if ((rc == 0)); then return 0; fi
  echo "等了 ${secs}s 没看到包含“$text”的消息；房间最新消息：${seen:-（没有消息）}${err:+；最后一次错误：$err}"
  return 1
}

probes_web_url() { # 从核心的插件列表拿网页地址，备好 SMOKE_WEB_URL 和 SMOKE_WEB_ORIGIN（见 smoke-probes.sh 顶部说明）；
                   # 拿不到时给列出的项标 FAIL，返回 1（后面的探针别跑了）
  local plugins_json item scheme host
  if plugins_json="$(smoke_api GET /_wonton/api/plugins)"; then
    SMOKE_WEB_URL="$(jq -rn --arg id "$SMOKE_PLUGIN_ID" --arg json "$plugins_json" '$json | fromjson | .plugins[] | select(.id==$id) | .web_url // ""')"
    SMOKE_WEB_URL="${SMOKE_WEB_URL%/}"
    scheme="${SMOKE_WEB_URL%%://*}"
    if [[ -n "$SMOKE_WEB_URL" && "$scheme" != "$SMOKE_WEB_URL" ]]; then
      host="${SMOKE_WEB_URL#"$scheme"://}"
      SMOKE_WEB_ORIGIN="$scheme://${host%%[/?#]*}"
    else
      SMOKE_WEB_ORIGIN=""
    fi
    export SMOKE_WEB_URL SMOKE_WEB_ORIGIN
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
  local unauth_code unauth_evi loc body rc=0
  if [[ "$SMOKE_WEBUI" != 1 ]]; then
    na 网页打得开 "清单没有 webui"
    return 0
  fi
  probes_dev session >>"$PROBES_LOG" 2>&1 || say "会话建立失败（后面的探测会失败）"
  unauth_code="$(curl_t "$SMOKE_WEB_MAX_TIME" "$SMOKE_WEB_URL/" --noproxy '*' -o /dev/null -w '%{http_code}')" || rc=$?
  unauth_evi="匿名返回 $unauth_code"
  ((rc == 28)) && unauth_evi="匿名请求超时（${SMOKE_WEB_MAX_TIME} 秒）"
  case "$unauth_code" in
    401) unauth_evi="匿名 401" ;;
    301|302|303|307|308)
      loc="$(curl_t "$SMOKE_WEB_MAX_TIME" "$SMOKE_WEB_URL/" --noproxy '*' -o /dev/null -w '%{redirect_url}')"
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

probes_run() { # [探针名…]：跑探针项，不给名字就全跑
  local name web=0 identity=0 mcp=0 data_write=0 data_check=0
  for name in "$@"; do
    case "$name" in
      web_assert | identity_check | mcp | data_write | data_check) ;;
      *) die "不认识的探针名：$name（可选 web_assert、identity_check、mcp、data_write、data_check）" ;;
    esac
  done
  if (($# == 0)); then
    web=1 identity=1 mcp=1 data_write=1 data_check=1
  else
    for name in "$@"; do
      case "$name" in
        web_assert) web=1 ;;
        identity_check) identity=1 ;;
        mcp) mcp=1 ;;
        data_write) data_write=1 ;;
        data_check) data_check=1 ;;
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
  if ((data_write || data_check)); then
    say "5. 数据写入与读回"
    if [[ "$DATA_NA" == 1 ]]; then
      na 数据 "${SMOKE_NOTE:-}${SMOKE_NOTE:+；}插件声明 DATA_NA=1"
    elif ((DATA_HOOKS == 0)); then
      fail 数据 "没写数据钩子：在 scripts/smoke-probes.sh 写 data_write 和 data_check（没有用户数据就写 DATA_NA=1）"
    else
      if ((data_write)); then
        probes_data_write || fail 数据写入 "data_write 失败，见 $PROBES_LOG 末尾：$(tail -c 200 "$PROBES_LOG" | tr '\n' ' ')"
      fi
      ((data_check)) && probes_data_check 数据还在
    fi
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
  SMOKE_DEV_STATE="$state"
  # 标记文件跨几次 dev.sh probes 保留：先跑 data_write、改完插件再跑 data_check 也读得到。
  SMOKE_STATE="$state/probes-data-marker"
  [[ -f "$SMOKE_STATE" ]] || : >"$SMOKE_STATE"
  SMOKE_INSTANCE="$instance"
  SMOKE_JAR="$(session_jar)"
  SMOKE_TOOLS="$state/probes-tools.json"
  probes_load
  probes_env || die "读不到用户令牌：核心没在运行？先 scripts/dev.sh up"
  probes_run "$@"
  if ((DID_FAIL)); then exit 1; fi
}
