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

# 假 curl：给 diag 读的出口代理设置。FAKE_API=fail 时像接口出错一样退出。
cat >"$bin/curl" <<'CURL'
#!/usr/bin/env bash
[[ "${FAKE_API:-ok}" == ok ]] || exit 22
printf '%s\n' "$FAKE_SETTINGS"
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

run 0 "FAKE_SETTINGS=$settings" "FAKE_DNS=10.213.0.2 auth.wonton.internal" -- diag || true
has "$out" "都通了" "全通时给出结论"
has "$out" "http_proxy=" "要看插件容器里的代理变量"

# 没配代理：可达性那一项说清楚，不算失败。
nop='{"url":null,"source":"none","provider":null,"plugin_path":null,"core_path":null,"host_cidrs":[],"direct_cidrs":[],"notices":[],"restarts":[]}'
run 0 "FAKE_SETTINGS=$nop" "FAKE_DNS=10.213.0.2 auth.wonton.internal" -- diag || true
has "$out" "没有配出口代理" "没配代理时说明"

# 连不上代理和解析不了主机名：两项各给一行原因，后面的项照样跑完。
run 1 FAKE_SETTINGS="$bad_settings" FAKE_PROXY=fail FAKE_DNS= -- diag || true
has "$out" "auth.wonton.internal" "要查身份提供方的主机名"
has "$out" "失败（退出码" "失败要写一行原因"
has "$out" "连不上：超时或被拒绝" "代理连不上要指着它"
has "$out" "no_proxy=" "前面的项失败后后面的项照样跑"
has "$out" "2 项失败" "数出失败项"

# 有 http_proxy 却没有 no_proxy：代理变量那一项失败。
run 1 "FAKE_SETTINGS=$settings" "FAKE_DNS=10.213.0.2 auth.wonton.internal" "FAKE_HTTP_PROXY=http://host.docker.internal:7899" "FAKE_NO_PROXY=" -- diag || true
has "$out" "有 http_proxy 却没有 no_proxy" "代理变量不对要写原因"

# 接口读不到设置：这一项失败，别的项不受影响。
run 1 FAKE_API=fail -- diag || true
has "$out" "当前代理设置" "要查当前设置"
has "$out" "读不到设置" "读不到设置要写原因"
has "$out" "http_proxy=" "接口失败后后面的项照样跑"

if ((failed > 0)); then
  echo "$failed 处失败" >&2
  exit 1
fi
echo "通过"
