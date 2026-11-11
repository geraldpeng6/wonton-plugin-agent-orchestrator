#!/usr/bin/env bash
# 检查插件包：和安装时同一套解析和校验，再检查商店信息和图片，最后给出插件包里的文件和摘要
# （核心镜像里的 wonton-core plugin check）。不连 Docker 里的核心，也不联网。
#
#   scripts/check.sh              不合格时退出码 1；只有提醒时照常通过
#   scripts/check.sh --official   按官方索引的要求：镜像按摘要固定、长期运行的服务有健康检查、写了标签、许可证、作者和声明
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

need docker python3
case "${1:-}" in
  '' | --official) ;;
  *) die "用法：scripts/check.sh [--official]" ;;
esac
need_core_command check

# 核心只在清单 spec 太新时报错，并顺带说出支持到哪一版；插件 spec 旧于核心时静默通过，模板照抄旧 spec 也不吭声。
# 拿一个必报太新的最小清单去问核心支持到哪版（问不到就不提醒），比清单的 spec 旧就提醒一句。
spec_reminder() {
  local facts plugin_spec core_max probe core_out a1 a2 b1 b2
  facts="$(docker compose -f "$root/docker-compose.yml" config --no-interpolate --format json 2>/dev/null)" || return 0
  plugin_spec="$(python3 - "$facts" <<'PY'
import json, sys
try:
    print(json.loads(sys.argv[1]).get("x-wonton", {}).get("spec", ""))
except Exception:
    pass
PY
)" || return 0
  [[ "$plugin_spec" =~ ^[0-9]+\.[0-9]+$ ]] || return 0
  probe="$(mktemp -d)" || return 0
  printf 'x-wonton:\n  spec: "99.0"\n' >"$probe/docker-compose.yml"
  core_out="$(in_core "$probe" plugin check /plugin 2>&1 || true)"
  rm -rf "$probe"
  [[ "$core_out" =~ 只支持到[[:space:]]+([0-9]+\.[0-9]+) ]] || return 0
  core_max="${BASH_REMATCH[1]}"
  IFS=. read -r a1 a2 <<<"$plugin_spec"
  IFS=. read -r b1 b2 <<<"$core_max"
  if ((a1 > b1 || (a1 == b1 && a2 >= b2))); then
    return 0
  fi
  echo "提醒：清单是 spec $plugin_spec，核心镜像 $(core_image) 支持到 $core_max；新插件建议写现行版本（字段见 https://github.com/wontonapp/wonton-docs/blob/main/plugin-spec.md）。" >&2
}

output="$(mktemp)"
trap 'rm -f "$output"' EXIT
set +e
in_core "$root" plugin check /plugin "$@" >"$output" 2>&1
status=$?
set -e
cat "$output"
# 清单的 spec 比测试用的核心新：错在核心太旧，不在插件，核心也不会往下逐项检查。单独给一句结论，CI 上再标成
# 注解，免得读的人以为插件写坏了。
if [[ "$(cat "$output")" =~ 插件按规范[[:space:]]+([0-9]+\.[0-9]+).*只支持到[[:space:]]+([0-9]+\.[0-9]+) ]]; then
  verdict="需要核心支持 spec ≥ ${BASH_REMATCH[1]}，测试用的核心 $(core_image) 只到 ${BASH_REMATCH[2]}：换新核心（WONTON_CORE_IMAGE，CI 手动触发时填 core-image），不是插件的问题。"
  echo "$verdict" >&2
  [[ -z "${GITHUB_ACTIONS:-}" ]] || echo "::error title=核心镜像太旧::$verdict"
  exit "$status"
fi
spec_reminder
exit "$status"
