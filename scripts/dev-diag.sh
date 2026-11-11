# shellcheck shell=bash
# 由 dev.sh 加载。只读诊断：每项打印命令和结果，失败只记一行原因、接着查下一项；不改设置、不动容器。
# shellcheck disable=SC2154 # core、state、api、service_of 由 dev.sh 设置。

# 一项诊断：<标题> <失败原因> <命令原文> <执行它的函数>。失败返回 1。
diag_item() {
  local title="$1" reason="$2" command="$3" output status=0 hook="$4"
  printf '\n== %s\n   %s\n' "$title" "$command"
  output="$("$hook" 2>&1)" || status=$?
  [[ -z "$output" ]] || printf '%s\n' "$output" | sed 's/^/   /'
  ((status == 0)) && return 0
  printf '   ↳ 失败（退出码 %d）：%s\n' "$status" "$reason"
  return 1
}

diag_core_running() {
  local running
  running="$(docker inspect -f '{{.State.Running}}' "$core" 2>/dev/null)" || return 1
  printf '%s\n' "$running"
  [[ "$running" == true ]]
}

# 核心在任何插件网络上带了 auth.wonton.internal 这个别名时才解析得到：声明了 OIDC 的插件在运行时，插件的登录才走得通。
diag_auth_host() {
  docker exec "$core" getent hosts auth.wonton.internal
}

diag_print_settings() {
  python3 - "$settings" <<'PY'
import json, sys

try:
    settings = json.loads(sys.argv[1])
except ValueError:
    sys.exit(f"设置接口回来不是 JSON：{sys.argv[1] or '（空）'}")
origin = {
    "env": "环境变量 WONTON_EGRESS_PROXY（设置里改不了）",
    "settings": "设置里的代理",
    "detected": "安装脚本检测到的代理",
    "plugin": "插件提供的代理",
    "none": "没有配出口代理",
}.get(settings["source"], settings["source"])
print(f"来源：{origin}")
print("地址：" + (settings["url"] or ("（空，地址由插件给）" if settings["source"] == "plugin" else "（空）")))
print("额外直连网段：" + ("、".join(settings["direct_cidrs"]) or "（无）"))
for name, label in (("plugin_path", "插件经出口容器"), ("core_path", "核心自己直连代理")):
    probe = settings.get(name)
    if probe is None:
        print(f"{label}：没测")
    else:
        problem = probe["problem"]
        print(f"{label}：通" if problem is None else f"{label}：{problem['reason']} {problem['message']}")
for notice in settings["notices"]:
    print(f"提示：{notice}")
PY
}

diag_proxy_reach() {
  local source host port
  source="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["source"])' <<<"$settings" 2>/dev/null)" ||
    { echo "读不到设置，没法取地址"; return 1; }
  case "$source" in
    none)
      echo "没有配出口代理：核心和出网插件都直连"
      return 0
      ;;
    plugin)
      echo "代理由插件提供：地址在插件自己的网络里，这里不测"
      return 0
      ;;
  esac
  if ! read -r host port < <(python3 - "$settings" <<'PY'
import json, sys

try:
    url = json.loads(sys.argv[1])["url"]
    rest = url.split("://", 1)[1].rsplit("@", 1)[-1]
    host, _, port = rest.rpartition(":")
    print(host.strip("[]"), port)
except (ValueError, IndexError):
    sys.exit(1)
PY
  ); then
    echo "地址解不出来：$settings"
    return 1
  fi
  printf '地址：%s:%s（凭据不打出来）\n' "$host" "$port"
  if ! docker exec "$core" timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
    echo "连不上：超时或被拒绝"
    return 1
  fi
  echo "连得上"
}

# 随便找一个在跑的插件容器，看核心注入的代理变量；出网代理配了而 no_proxy 空着时，插件连内部地址会被送去代理。
diag_no_proxy() {
  local name
  while read -r name; do
    [[ "$(service_of "$name")" == core ]] || break
  done < <(docker ps --filter "name=^wonton-$instance--" --format '{{.Names}}') || true
  if [[ -n "${name:-}" && "$(service_of "$name")" == core ]]; then name=""; fi
  if [[ -z "${name:-}" ]]; then
    echo "没有在运行的插件容器：装一个插件再看"
    return 0
  fi
  printf '容器：%s\n' "$name"
  docker exec "$name" sh -c '
    printf "http_proxy=%s\nno_proxy=%s\n" "${http_proxy-（空）}" "${no_proxy-（空）}"
    [ -z "${http_proxy-}" ] || [ -n "${no_proxy-}" ]
  ' || return 1
}

diag() {
  need_env
  local failed=0 settings=""
  diag_item "核心容器在跑" "核心没在运行：先 scripts/dev.sh up，起不来时看 scripts/dev.sh logs 的报错" \
    "docker inspect -f '{{.State.Running}}' $core" diag_core_running || failed=$((failed + 1))

  diag_item "核心容器里解析 auth.wonton.internal" \
    "解析不到：没有声明 OIDC 的插件在运行（核心只在那种插件网络上带这个别名），或 Docker 的内嵌 DNS 有问题；插件的登录会走不通" \
    "docker exec $core getent hosts auth.wonton.internal" diag_auth_host || failed=$((failed + 1))

  settings="$(api GET /_wonton/api/egress-proxy 2>&1)" || true
  diag_item "当前代理设置" \
    "读不到设置：核心没在运行，或接口出错（先看 scripts/dev.sh logs）" \
    "api GET /_wonton/api/egress-proxy（地址已打码）" diag_print_settings || failed=$((failed + 1))

  diag_item "代理地址从核心容器连得上" \
    "连不上：代理没开、地址写错，或防火墙挡了；核心和出网插件都经它出去" \
    "docker exec $core timeout 3 bash -c 'exec 3<>/dev/tcp/<主机>/<端口>'" diag_proxy_reach || failed=$((failed + 1))

  diag_item "插件容器里的代理变量" \
    "有 http_proxy 却没有 no_proxy：插件连内部地址（auth.wonton.internal 等）会被送去代理，解析不了插件网络里的名字" \
    "docker exec <插件容器> sh -c 'printenv http_proxy no_proxy'" diag_no_proxy || failed=$((failed + 1))

  printf '\n'
  if ((failed > 0)); then
    echo "$failed 项失败。"
    exit 1
  fi
  echo "都通了。"
}
