# shellcheck shell=bash
# 由 dev.sh 加载；删除只认精确实例标签/前缀，Compose 资源另认完整项目名。
# shellcheck disable=SC2154 # instance 由 dev.sh 的 load_settings 设置。

instance_resources() {
  local kind="$1" rows
  case "$kind" in
    container) rows="$(docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Label "wonton.instance"}}\t{{.Label "com.docker.compose.project"}}')" ;;
    network) rows="$(docker network ls --format '{{.ID}}\t{{.Name}}\t{{.Label "wonton.instance"}}\t{{.Label "com.docker.compose.project"}}')" ;;
    volume) rows="$(docker volume ls --format '{{.Name}}\t{{.Name}}\t{{.Label "wonton.instance"}}\t{{.Label "com.docker.compose.project"}}')" ;;
    *) return 2 ;;
  esac || return 1
  python3 - "$instance" "$rows" <<'PY'
import sys
instance, rows = sys.argv[1:]
prefix = f"wonton-{instance}--"
for row in rows.splitlines():
    ident, name, label, project = row.split("\t")
    if label == instance or name.startswith(prefix) or project == f"wonton-{instance}":
        print(ident, name, sep="\t")
PY
}

remove_instance_containers() {
  local rows id name failed=0
  rows="$(docker ps -a --filter "label=wonton.instance=$instance" --format '{{.ID}}\t{{.Names}}')" ||
    die "列不出实例容器，未继续清理"
  while IFS=$'\t' read -r id name; do
    [[ -n "$id" && "$name" != "wonton-$instance--core" ]] || continue
    # 核心栈交给 compose down；先移走依赖它的插件和测试客户端。
    case "$name" in "wonton-$instance--"*) docker rm -f "$id" >/dev/null || failed=1 ;; esac
  done <<<"$rows"
  return "$failed"
}
remove_remaining_containers() {
  local rows id name failed=0
  rows="$(instance_resources container)" || die "列不出实例容器，未继续清理"
  while IFS=$'\t' read -r id name; do
    [[ -n "$id" && "$name" != "wonton-$instance--core" ]] || continue
    docker rm -f "$id" >/dev/null || failed=1
  done <<<"$rows"
  return "$failed"
}


check_instance_removed() {
  local kind rows found=""
  for kind in container network volume; do
    rows="$(instance_resources "$kind")" || die "核对 $kind 残留失败，实例状态保留"
    if [[ -n "$rows" ]]; then
      printf '残留 %s：\n%s\n' "$kind" "$rows" >&2
      found=1
    fi
  done
  [[ -z "$found" ]]
}

warn_shared_egress() {
  local containers networks details status=0
  # 新核心按实例命名出口；只提示旧核心遗留的全机共享资源，绝不自动删。
  containers="$(docker ps -a --filter 'name=^/?wonton-egress$' --format '{{.ID}}')" || return 1
  networks="$(docker network ls --filter 'name=^wonton-egress$' --format '{{.ID}}')" || return 1
  [[ -n "$containers$networks" ]] || return 0
  if [[ -n "$containers" ]]; then
    details="$(docker container inspect "$containers")" || return 1
  else
    details="$(docker network inspect "$networks")" || return 1
  fi
  # 只把共享出口自己接在共享网络上的情况算空闲；任何其他端点都不提示可删。
  python3 - "$details" "$containers" "$networks" <<'PY' || status=$?
import json, subprocess, sys
items = json.loads(sys.argv[1])
container, network = sys.argv[2:]
if network:
    items += json.loads(subprocess.check_output(["docker", "network", "inspect", network]))
for item in items:
    labels = item.get("Config", {}).get("Labels", item.get("Labels", {})) or {}
    if labels.get("wonton.instance") or labels.get("wonton.core.component") != "wonton-egress":
        sys.exit(3)
    if "NetworkSettings" in item and any(name != "wonton-egress" for name in item["NetworkSettings"]["Networks"]):
        sys.exit(3)
    if "Containers" in item and any(not container or not ident.startswith(container) for ident in item["Containers"]):
        sys.exit(3)
PY
  case "$status" in
    0) echo '共享 wonton-egress 没有其他网络端点；未自动删除。确认没有实例在使用后可手动执行：docker rm -f wonton-egress; docker network rm wonton-egress' >&2 ;;
    3) return 0 ;;
    *) return "$status" ;;
  esac
}
