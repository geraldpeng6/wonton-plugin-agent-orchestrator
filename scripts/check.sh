#!/usr/bin/env bash
# 检查插件包：和安装时同一套解析和校验，再检查商店信息和图片，最后给出插件包里的文件和摘要
# （核心镜像里的 wonton-core plugin check）。不连 Docker 里的核心，也不联网。
#
#   scripts/check.sh              不合格时退出码 1；只有提醒时照常通过
#   scripts/check.sh --official   按官方索引的要求：镜像按摘要固定、长期运行的服务有健康检查、写了标签、许可证、作者和声明
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

need docker
case "${1:-}" in
  '' | --official) ;;
  *) die "用法：scripts/check.sh [--official]" ;;
esac
need_core_command check
output="$(mktemp)"
trap 'rm -f "$output"' EXIT
set +e
in_core "$root" plugin check /plugin "$@" >"$output" 2>&1
status=$?
set -e
cat "$output"
if [[ "${1:-}" == --official && "$(cat "$output")" =~ 插件按规范[[:space:]]+([0-9]+\.[0-9]+).*只支持到[[:space:]]+([0-9]+\.[0-9]+) ]]; then
  echo "核心镜像 $(core_image) 只支持到 spec ${BASH_REMATCH[2]}，当前清单是 spec ${BASH_REMATCH[1]}；请升级核心，或用 WONTON_CORE_IMAGE 指定支持当前 spec 的镜像。" >&2
fi
exit "$status"
