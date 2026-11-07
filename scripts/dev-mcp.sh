# shellcheck shell=bash
# shellcheck disable=SC2154 # root、instance 由 dev.sh 加载设置。
# 由 dev.sh 加载，直连插件网络时复用已有的 MCP 客户端。
mcp_direct() {
  local sub="$1" facts endpoint id service url container network image client
  facts="$(docker compose -f "$root/docker-compose.yml" config --no-interpolate --format json)" ||
    die "解析不了工作区的 docker-compose.yml"
  endpoint="$(python3 - "$facts" <<'PY'
import json, sys
manifest = json.loads(sys.argv[1])["x-wonton"]
mcp = manifest.get("mcp")
if not mcp:
    sys.exit("插件清单没有声明 mcp；直连只调试提供 MCP 的插件，总线请用 mcp list|call")
if mcp["transport"] != "streamable-http":
    sys.exit(f"不支持的 MCP 传输：{mcp['transport']}")
print(manifest["id"], mcp["service"], f"{mcp['port']}{mcp.get('path') or '/mcp'}", sep="\t")
PY
  )" || exit 1
  IFS=$'\t' read -r id service url <<<"$endpoint"
  container="wonton-$instance--${id//./-}--$service"
  network="wonton-$instance--${id//./-}"
  docker container inspect "$container" >/dev/null 2>&1 || die "找不到 MCP 服务容器 $container：先安装插件"
  docker network inspect "$network" >/dev/null 2>&1 ||
    die "找不到插件网络 $network：直连要求插件使用核心管理的独立网络"
  # 不在插件网络里下载依赖：它可能禁止出网。Hermes 自带 SDK；只读复用，不改它的容器或文件。
  image="$(docker container inspect --format '{{.Image}}' "wonton-$instance--com-nousresearch-hermes--gateway" 2>/dev/null)" ||
    die "没有 Hermes gateway：直连复用它的镜像和 MCP SDK，先装上 Hermes"
  client="wonton-$instance--mcp-client-$(random_hex 4)"
  shift
  docker run --rm -i --name "$client" --label "wonton.instance=$instance" --network "$network" \
    --entrypoint python3 -e HTTP_PROXY= -e HTTPS_PROXY= -e ALL_PROXY= -e NO_PROXY='*' \
    -e http_proxy= -e https_proxy= -e all_proxy= -e no_proxy='*' \
    "$image" - "$sub" "http://$container:$url" "$@" <"$root/scripts/mcp_client.py"
}
