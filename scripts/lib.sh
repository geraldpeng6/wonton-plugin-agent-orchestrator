# scripts/ 里几个脚本共用的函数，由它们 source，不单独执行。
# shellcheck shell=bash

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 开发环境：compose 文件、密钥、数据，都不提交（.gitignore）。WONTON_DEV_STATE 给冒烟用另一份目录。
state="${WONTON_DEV_STATE:-$root/.wonton}"
env_file="$state/.env"
# 没有开发环境时，检查和打包用这个核心镜像：main 每次合并都会更新，插件跟着主干的规范走，不等发版。
default_image="ghcr.io/wontonapp/wonton-core:main"

die() {
  echo "$*" >&2
  exit 1
}

info() {
  echo "==> $*" >&2
}

need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "没有找到 $tool，先装上它（见 https://github.com/wontonapp/wonton-docs/blob/main/develop.md#准备）"
  done
}

# 所有 curl 都带超时，网页或接口不回时冒烟和它占的验证栈名额不跟着挂死。网页 120 秒、接口 600 秒；
# 下载是几十 KB 的套件文件，公网线路卡住时 3 分钟内必须结束，连接阶段 30 秒不通也不等。
# 调用方（或探针）用同名变量覆盖，单个请求还可以在自己的 curl 参数里再给更短的时间。
: "${SMOKE_WEB_MAX_TIME:=120}"
: "${SMOKE_API_MAX_TIME:=600}"
: "${SMOKE_DOWNLOAD_MAX_TIME:=180}"
: "${SMOKE_CONNECT_TIMEOUT:=30}"

# 带超时的 curl：<秒数> <地址> [<curl 参数>…]，地址放在最后交给 curl。超时（curl 退出码 28）时在 stderr
# 写地址和秒数，curl 自己只会给“curl: (28)”；调用方在自己的参数里给的 --max-time 优先，报的也是那个数。
curl_t() {
  local secs="$1" url="$2" rc=0
  shift 2
  local -a args=("$@")
  local i
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
      --max-time) secs="${args[$((i + 1))]}" ;;
      --max-time=*) secs="${args[$i]#--max-time=}" ;;
    esac
  done
  curl -sS --fail-with-body --max-time "$secs" "$@" "$url" || rc=$?
  if ((rc == 28)); then
    echo "超时退出（上限 ${secs} 秒）：$url" >&2
  fi
  return "$rc"
}

# 开发环境的一项设置（.wonton/.env），没有时为空。
setting() {
  [[ -f "$env_file" ]] || return 0
  sed -n "s/^$1=//p" "$env_file" | tail -n 1
}

# 检查和打包用的核心镜像：环境变量 WONTON_CORE_IMAGE，其次开发环境正在用的，最后是默认的。
core_image() {
  local image="${WONTON_CORE_IMAGE:-}"
  [[ -n "$image" ]] || image="$(setting WONTON_CORE_IMAGE)"
  echo "${image:-$default_image}"
}

# 核心镜像里要有这个 plugin 子命令：need_core_command <子命令>。更早的镜像没有，直接执行只报“未知命令”，看不出是
# 镜像太旧。docker run 自己出错（如拉不到镜像）时退出码是 125。
need_core_command() {
  local image usage status=0
  image="$(core_image)"
  usage="$(docker run --rm --network none "$image" plugin 2>&1)" || status=$?
  ((status != 125)) || die "运行不了核心镜像 $image：$usage"
  [[ "$usage" == *"plugin $1"* ]] ||
    die "核心镜像 $image 太旧，没有 wonton-core plugin $1：换新版本，或用 WONTON_CORE_IMAGE 指定（见 https://github.com/wontonapp/wonton-docs/blob/main/develop.md#开发环境）"
}

# 在核心镜像里执行 wonton-core：in_core <插件包目录> <参数…>，目录只读挂在 /plugin。
in_core() {
  local dir="$1"
  shift
  docker run --rm --network none -v "$dir:/plugin:ro" "$(core_image)" "$@"
}

# 在跑的容器里按名字前缀找一个：running_container <前缀>，找不到时返回 1、标准输出为空。核心给 Bot 服务的
# 容器名带上 `--<Bot 名>`（plugin/names.rs 的 bot_container），调用方只按 `<插件网络>--<服务>` 找，旧核心
# 没有这个后缀也能命中；同一个服务有多个 Bot 时取第一个。
running_container() {
  local names
  names="$(docker container ls --filter "name=$1" --format '{{.Names}}')" || return 1
  grep -x -m1 -E "$1(--[a-z0-9-]+)?" <<<"$names"
}

# `plugin check` 输出里的「插件 <ID> <版本>」行去掉前缀。核心 4cdfe16 前后会先打一行 tracing
# （图片助手启动），清单行不再固定是第一行：在全部输出里找。
manifest_line() {
  { in_core "$root" plugin check /plugin 2>/dev/null || true; } | sed -n 's/^插件 //p' | head -1
}

plugin_id() {
  local line
  line="$(manifest_line)"
  [[ -n "$line" ]] || die "插件包解析不了，先运行 scripts/check.sh 看原因"
  echo "${line%% *}"
}

plugin_version() {
  local line
  line="$(manifest_line)"
  [[ -n "$line" ]] || die "插件包解析不了，先运行 scripts/check.sh 看原因"
  echo "${line#* }"
}

# #121：宿主机给 Docker 客户端配了代理（config.json 的 proxies）时，docker CLI 建的每个容器都带上 HTTP_PROXY
# 这类变量，容器里访问代理挡住的地址会报 proxyconnect tcp，极易误判成插件的问题。
# strip_docker_proxies [目标目录]：把 config.json 复制一份去掉 proxies（凭据、context 留着），DOCKER_CONFIG 指过去，
# 之后这个进程用 docker CLI 起的容器不再带代理。没配代理、读不了或目标就是原目录时原样保留，一个进程只剥一次。
strip_docker_proxies() {
  local docker_config="${DOCKER_CONFIG:-$HOME/.docker}" stripped target="${1:-$state/docker-config}"
  [[ -n "${WONTON_DOCKER_PROXIES_STRIPPED:-}" ]] && return 0
  WONTON_DOCKER_PROXIES_STRIPPED=1
  [[ -f "$docker_config/config.json" ]] || return 0
  stripped="$(python3 - "$docker_config/config.json" <<'PY'
import json, sys
try:
    config = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
if config.pop("proxies", None) is None:
    sys.exit(3)
print(json.dumps(config))
PY
)" || return 0
  [[ "$target" -ef "$docker_config" ]] && return 0
  rm -rf "$target"
  mkdir -p "$target"
  cp -a "$docker_config/." "$target/"
  printf '%s\n' "$stripped" >"$target/config.json"
  export DOCKER_CONFIG="$target"
}
