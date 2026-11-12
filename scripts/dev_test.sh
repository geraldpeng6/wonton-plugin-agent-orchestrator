#!/usr/bin/env bash
# dev.sh 的 logs、diag 在没有 Docker 的机器上测：假的 docker 和 curl 放在 PATH 前面，只用真的 bash、python3。
# 结果看退出码和输出，不连网。
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
state="$work/state"
mkdir -p "$bin" "$state"
touch "$state/compose.yaml"
printf 'WONTON_INSTANCE=test\n' >"$state/.env"

# 假 docker：只回答这些命令要问的几件事。FAKE_* 决定答案。
cat >"$bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "${1:-}" in
  compose)
    shift
    while [[ "${1:-}" == -p || "${1:-}" == -f ]]; do shift 2; done
    case "${1:-}" in
      config) printf 'core\nhydra\nhydra-migrate\ntusd\ntuwunel\n' ;;
      logs) printf 'core-logs:%s\n' "${@: -1}" ;;
    esac
    ;;
  ps) printf 'wonton-test--app-web--web\nwonton-test--app-web--web--bot\nwonton-test--db--db\n' ;;
  logs) printf 'plugin-logs:%s\n' "$*" ;;
  inspect) printf '%s\n' "${FAKE_RUNNING:-true}" ;;
  run)
    # in_core：plugin check 回清单行，plugin pack 回假的包字节。
    case "$*" in
      *"plugin check"*) printf '插件 com.example.app 1.2.3\n' ;;
      *"plugin pack"*) printf 'fake-package\n' ;;
      *) exit 1 ;;
    esac
    ;;
  exec)
    shift
    case "$1" in
      *--core)
        case "${2:-}" in
          cat) printf 'token\n' ;;
          getent)
            [[ -n "${FAKE_DNS:-}" ]] || exit 2
            printf '%s\n' "$FAKE_DNS"
            ;;
          timeout) [[ "${FAKE_PROXY:-ok}" == ok ]] ;;
        esac
        ;;
      *)
        if [[ "${2:-}" == sh ]]; then
          printf 'http_proxy=%s\nno_proxy=%s\n' "${FAKE_HTTP_PROXY-}" "${FAKE_NO_PROXY-.wonton.internal}"
          [[ -z "${FAKE_HTTP_PROXY-}" || -n "${FAKE_NO_PROXY-}" ]]
        fi
        ;;
    esac
    ;;
  *) exit 1 ;;
esac
DOCKER
chmod +x "$bin/docker"

# 假 curl：按方法+路径回话。GET 卡片列表回 FAKE_CARDS；POST 回答按核心的匹配规则校验
# （answer + choice_id 得是那张卡片上真有的按钮，不是就 400）。FAKE_API=fail 时像接口出错
# 一样退出；FAKE_ANSWER_FAIL=<卡片 id> 让那张卡的 POST 像被核心拒掉一样回 409。
cat >"$bin/curl" <<'CURL'
#!/usr/bin/env bash
url="${*: -1}"
method=GET
body=""
args=("${@:1:$#-1}")
i=0
while ((i < ${#args[@]})); do
  case "${args[$i]}" in
    -X) method="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    -d) body="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    *) i=$((i + 1)) ;;
  esac
done
[[ "${FAKE_API:-ok}" == ok ]] || exit 22
case "$url" in
  */_wonton/api/confirmations)
    printf '%s\n' "$FAKE_CARDS"
    ;;
  */_wonton/confirmations/*)
    python3 - "$url" "$method" "$body" <<'PY'
import json, os, sys

url, method, body = sys.argv[1], sys.argv[2], sys.argv[3]
cards = json.loads(os.environ.get("FAKE_CARDS", '{"confirmations":[]}'))["confirmations"]
card = next((c for c in cards if c.get("id") == url.rstrip("/").rsplit("/", 1)[-1]), None)
if card is None:
    print(json.dumps({"error": {"kind": "not_found", "message": "没有这张卡片"}}))
    sys.exit(22)
if card["id"] == os.environ.get("FAKE_ANSWER_FAIL"):
    print(json.dumps({"error": {"kind": "already_answered", "message": "这张卡片已经回答过了"}}))
    sys.exit(22)
sent = json.loads(body)
# 学核心 answer_with_secrets 的匹配：发来的 answer + choice_id 必须是卡片上真有的按钮。
if any(
    c.get("answer") == sent.get("answer") and c.get("choice_id") == sent.get("choice_id")
    for c in card.get("choices", [])
):
    print(json.dumps({"state": {"type": "running"}}))
else:
    print(json.dumps({"error": {"kind": "invalid_input", "message": "卡片上没有这个按钮"}}))
    sys.exit(22)
PY
    ;;
  */upgrade/preview)
    [[ -n "${FAKE_HIT_FILE:-}" ]] && printf 'POST %s\n' "$url" >>"$FAKE_HIT_FILE"
    if [[ -n "${FAKE_PREVIEW_FAIL:-}" ]]; then
      printf '%s\n' "$FAKE_PREVIEW_FAIL"
      exit 22
    fi
    cat "${FAKE_PREVIEW_FILE:?}"
    ;;
  */upgrade*)
    [[ -n "${FAKE_HIT_FILE:-}" ]] && printf 'POST %s\n' "$url" >>"$FAKE_HIT_FILE"
    cat "${FAKE_RESULT_FILE:?}"
    ;;
  *)
    printf '%s\n' "$FAKE_SETTINGS"
    ;;
esac
CURL
chmod +x "$bin/curl"

failed=0
# run <期望退出码> <变量…> -- <参数…>：跑 dev.sh，输出留在 $out、$err。
run() {
  local want="$1" status=0
  shift
  local -a env=()
  while [[ "$1" != -- ]]; do env+=("$1"); shift; done
  shift
  env "${env[@]}" PATH="$bin:$PATH" HOME="$work" WONTON_DEV_STATE="$state" \
    bash "$root/scripts/dev.sh" "$@" >"$work/out" 2>"$work/err" || status=$?
  out="$(cat "$work/out")"
  err="$(cat "$work/err")"
  if [[ $status == "$want" ]]; then return 0; fi
  echo "FAIL 退出码 $status，应该是 $want：dev.sh $*" >&2
  printf 'stdout:\n%s\nstderr:\n%s\n' "$out" "$err" >&2
  failed=$((failed + 1))
}

# has <文本> <应包含> <说明>
has() {
  if [[ "$1" == *"$2"* ]]; then return 0; fi
  echo "FAIL $3：输出里没有 $2" >&2
  printf '%s\n' "$1" >&2
  failed=$((failed + 1))
}

settings='{"url":"http://host.docker.internal:7899","source":"settings","provider":null,"plugin_path":null,"core_path":null,"host_cidrs":[],"direct_cidrs":[],"notices":[],"restarts":[]}'
bad_settings='{"url":"http://host.docker.internal:1","source":"settings","provider":null,"plugin_path":null,"core_path":null,"host_cidrs":[],"direct_cidrs":[],"notices":[],"restarts":[]}'
# upgrade 假接口的默认回答：预览带一项权限（断言 grant 带进了升级请求），结果按核心的 UpgradeResult。
# 存成文件经环境变量传给假 curl：JSON 里的引号过不了 shellcheck 的 export 检查。
printf '%s\n' '{"title":"示例","id":"com.example.app","version":"1.2.4","permissions":[{"permission":"network.egress","text":"访问外网","risk":false}],"notices":[],"blocked":null}' >"$work/preview.json"
printf '%s\n' '{"plugin":{"id":"com.example.app","title":"示例","version":"1.2.4","web_url":"http://app.example.localhost:18480"},"added_tools":{"type":"none"}}' >"$work/result.json"
printf '%s\n' '{"title":"示例","id":"com.example.app","version":"1.2.4","permissions":[],"notices":[],"blocked":"这台主机缺 GPU"}' >"$work/blocked.json"
export FAKE_PREVIEW_FILE="$work/preview.json" FAKE_RESULT_FILE="$work/result.json"
not_installed='{"error":{"kind":"not_installed","message":"插件 com.example.app 没有安装"}}'

run 0 -- logs || true
has "$out" core-logs:core "不给参数时跟核心"
run 0 -- logs hydra || true
has "$out" core-logs:hydra "核心服务走 compose"
run 0 -- logs web || true
has "$out" wonton-test--app-web--web "插件服务走 docker logs"
has "$out" wonton-test--app-web--web--bot "同一个服务的多份（Bot）一起跟"
run 1 -- logs nope || true
has "$err" "没有叫 nope 的服务" "未知服务要报错"
has "$err" "hydra" "未知服务要列出核心服务"
has "$err" "web" "未知服务要列出插件服务"

run 0 "FAKE_SETTINGS=$settings" "FAKE_DNS=192.0.2.53 auth.wonton.internal" -- diag || true
has "$out" "都通了" "全通时给出结论"
has "$out" "http_proxy=" "要看插件容器里的代理变量"

# 没配代理：可达性那一项说清楚，不算失败。
nop='{"url":null,"source":"none","provider":null,"plugin_path":null,"core_path":null,"host_cidrs":[],"direct_cidrs":[],"notices":[],"restarts":[]}'
run 0 "FAKE_SETTINGS=$nop" "FAKE_DNS=192.0.2.53 auth.wonton.internal" -- diag || true
has "$out" "没有配出口代理" "没配代理时说明"

# 连不上代理和解析不了主机名：两项各给一行原因，后面的项照样跑完。
run 1 FAKE_SETTINGS="$bad_settings" FAKE_PROXY=fail FAKE_DNS= -- diag || true
has "$out" "auth.wonton.internal" "要查身份提供方的主机名"
has "$out" "失败（退出码" "失败要写一行原因"
has "$out" "连不上：超时或被拒绝" "代理连不上要指着它"
has "$out" "no_proxy=" "前面的项失败后后面的项照样跑"
has "$out" "2 项失败" "数出失败项"

# 有 http_proxy 却没有 no_proxy：代理变量那一项失败。
run 1 "FAKE_SETTINGS=$settings" "FAKE_DNS=192.0.2.53 auth.wonton.internal" "FAKE_HTTP_PROXY=http://host.docker.internal:7899" "FAKE_NO_PROXY=" -- diag || true
has "$out" "有 http_proxy 却没有 no_proxy" "代理变量不对要写原因"

# 接口读不到设置：这一项失败，别的项不受影响。
run 1 FAKE_API=fail -- diag || true
has "$out" "当前代理设置" "要查当前设置"
has "$out" "读不到设置" "读不到设置要写原因"
has "$out" "http_proxy=" "接口失败后后面的项照样跑"

# approve：权限卡（ACP session/request_permission 转来的，选项带 choice_id）要把允许选项的
# answer 和 choice_id 一起发，只发 answer 核心回 400；普通卡照旧只发 answer。
cards='{"confirmations":[{"id":"perm-1","state":{"type":"pending"},"title":"dsh 想跑命令","choices":[{"answer":"approve","label":"允许一次","choice_id":"acp-0"},{"answer":"reject","label":"拒绝","choice_id":"acp-2"}]},{"id":"plain-1","state":{"type":"pending"},"title":"Hermes 想装插件","choices":[{"answer":"approve","label":"允许"}]}]}'
run 0 "FAKE_CARDS=$cards" -- approve || true
has "$out" "已批准：dsh 想跑命令" "权限卡带 choice_id 批准"
has "$out" "已批准：Hermes 想装插件" "普通卡只发 answer"

# 只有拒绝类选项的卡代批不了：如实写原因，退出码 1。
rejonly='{"confirmations":[{"id":"rej-1","state":{"type":"pending"},"title":"dsh 想发网页","choices":[{"answer":"reject","label":"拒绝","choice_id":"acp-0"}]}]}'
run 1 "FAKE_CARDS=$rejonly" -- approve || true
has "$err" "没批准：dsh 想发网页：卡片上没有允许类的选项" "只有拒绝选项要写原因"

# 核心拒掉其中一张：报核心给的原因，别的卡片照批。
run 1 "FAKE_CARDS=$cards" "FAKE_ANSWER_FAIL=perm-1" -- approve || true
has "$err" "没批准：dsh 想跑命令：这张卡片已经回答过了" "核心拒批要报核心的原因"
has "$out" "已批准：Hermes 想装插件" "一张失败不影响下一张"

# 列表接口挂了：报错退出。
run 1 FAKE_API=fail -- approve || true
has "$err" "取不到等回答的卡片" "取不到卡片要报错"

# 没有等回答的卡片：说明，不算失败。
run 0 'FAKE_CARDS={"confirmations":[]}' -- approve || true
has "$out" "没有等回答的卡片" "没有卡片时说明"

# upgrade：打包→POST upgrade/preview→（--yes）→POST upgrade?grant=，grant 取自预览的权限。
: >"$work/hit"
run 0 "FAKE_HIT_FILE=$work/hit" -- upgrade --yes || true
has "$out" "升级好了：示例 1.2.4" "升级完要报新版本"
has "$(cat "$work/hit")" "/_wonton/api/plugins/com.example.app/upgrade/preview" "先打升级预览"
has "$(cat "$work/hit")" "/upgrade?grant=network.egress" "按预览的权限发升级"

# 没装着（预览回 not_installed，像核心一样回错误正文和非 2xx）：报核心的原因，退出码 1。
run 1 "FAKE_PREVIEW_FAIL=$not_installed" -- upgrade --yes || true
has "$err" "预览失败：插件 com.example.app 没有安装（not_installed）" "没装着要报预览失败"

# 预览说这台主机装不了：拦住，不升级。
run 1 "FAKE_PREVIEW_FILE=$work/blocked.json" -- upgrade --yes || true
has "$err" "装不了：这台主机缺 GPU" "blocked 要拦住升级"

# 接口挂了：报错退出。
run 1 FAKE_API=fail -- upgrade --yes || true
has "$err" "预览失败" "接口挂了要报错"

if ((failed > 0)); then
  echo "$failed 处失败" >&2
  exit 1
fi
echo "通过"
