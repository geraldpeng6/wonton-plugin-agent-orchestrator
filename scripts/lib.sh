# scripts/ 里几个脚本共用的函数，由它们 source，不单独执行。
# shellcheck shell=bash

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 开发环境：compose 文件、密钥、数据，都不提交（.gitignore）。WONTON_DEV_STATE 给冒烟用另一份目录。
state="${WONTON_DEV_STATE:-$root/.wonton}"
env_file="$state/.env"
# 没有开发环境时，检查和打包用这个核心镜像。
default_image="ghcr.io/geraldpeng6/wonton-core:beta"

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
    command -v "$tool" >/dev/null 2>&1 || die "没有找到 $tool，先装上它（见 https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md#准备）"
  done
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
    die "核心镜像 $image 太旧，没有 wonton-core plugin $1：换新版本，或用 WONTON_CORE_IMAGE 指定（见 https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md#开发环境）"
}

# 在核心镜像里执行 wonton-core：in_core <插件包目录> <参数…>，目录只读挂在 /plugin。
in_core() {
  local dir="$1"
  shift
  docker run --rm --network none -v "$dir:/plugin:ro" "$(core_image)" "$@"
}

# `plugin check` 输出的第一行去掉“插件 ”，即“<ID> <版本>”。有不合格的地方时 check 的退出码是 1，第一行照常有；
# 插件包解析不了时为空。
manifest_line() {
  { in_core "$root" plugin check /plugin 2>/dev/null || true; } | sed -n '1s/^插件 //p'
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
