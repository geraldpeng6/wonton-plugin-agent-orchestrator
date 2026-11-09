#!/usr/bin/env bash
# 插件的开发环境：用发布的核心镜像在本机起一套云吞（核心、身份提供方、Matrix 服务器，和正式安装同一份 compose），
# 把这个仓库的插件装进去。设置、密钥和数据都在 .wonton/ 里，不装进系统，不要 root。
#
#   scripts/dev.sh up                         起开发环境，等到都健康；再执行一次就是拉最新的核心镜像重启
#   scripts/dev.sh install [--yes] [<引用>]   预览后安装插件：默认装工作区里的，给了 git 引用（tag、分支、提交）就装那个版本
#   scripts/dev.sh reinstall [--yes]          卸载（保留数据）再装上工作区里的：改了插件包以后用
#   scripts/dev.sh rebuild                    强制重建核心栈，再保数据重装工作区插件；其他插件容器不重建
#   scripts/dev.sh uninstall [--purge]        卸载；--purge 连插件的数据一起删
#   scripts/dev.sh status                     开发环境的服务和装着的插件
#   scripts/dev.sh logs [<服务>]              跟着看核心的日志；给了插件的服务名就看那个服务的
#   scripts/dev.sh token                      用户令牌：浏览器登录和调接口都用它
#   scripts/dev.sh session [--new]            建立用户会话（--new 重建），cookie 存在 .wonton/session.cookies
#   scripts/dev.sh web [--jar <文件>] [--fresh] [--sso] [<路径> [<curl 参数>…]]
#                                             以用户的身份请求插件网页；--sso 会从清单 webui.path 的入口提交 JS 自动表单并跟完重定向
#   scripts/dev.sh api <方法> <路径> [<curl 参数>…] 带用户令牌调用核心管理接口
#   scripts/dev.sh egress <地址>                读取设置后用同样的 restarts 和直连网段设置出口代理
#   scripts/dev.sh mcp list                   Bot 经 MCP 总线能调到的工具（JSON）
#   scripts/dev.sh mcp call <工具> [<JSON>]   经 MCP 总线调用工具，参数是 JSON 对象，默认 {}
#   scripts/dev.sh mcp --direct list|call …   直连工作区清单的 MCP 服务，只调试插件本身，不走总线权限和确认
#   scripts/dev.sh approve [--watch]          用主人令牌批准确认卡片；--watch 持续批准，Ctrl-C 停止
#   scripts/dev.sh smoke                      对工作区的插件跑合并前的端到端冒烟：起一套一次性实例，跑完清理
#   scripts/dev.sh probes [<探针名>…]          对装着的工作区插件跑冒烟探针（web_assert、identity_check、mcp、data_write、data_check），不起新实例；给了名字就只跑那几项
#   scripts/dev.sh pair                       在终端里出配对二维码，给 App 用
#   scripts/dev.sh down                       停下核心，数据都留着；插件的容器由核心管，照常运行
#   scripts/dev.sh reset                      删掉当前实例的插件容器和网络，保留核心和 .wonton 数据
#   scripts/dev.sh purge [--yes]              删掉整个开发环境；非交互执行必须带 --yes
#   scripts/dev.sh kit-update [<ref>]          更新开发套件（默认 main），不需要 Docker
#
# 第一次 up 时可以用环境变量定下：WONTON_CORE_IMAGE（核心镜像，默认 ghcr.io/geraldpeng6/wonton-core:main）、
# WONTON_INSTANCE（实例名）、WONTON_PORT（网页端口，隧道用下一个端口）、WONTON_PULL=never（用本机构建的核心镜像，
# 不拉取）。之后改 .wonton/.env 再 up。WONTON_DEV_CORE_SUBNET（如 10.214.1.0/24）让核心网络用这个子网，不占 Docker 的
# 默认地址池（只有约 30 个网络，几套栈共用一台 Docker 时会用光）；写进 .wonton/compose.subnet.yaml，栈拆掉之前一直沿用。
set -euo pipefail
# forget_environment 会清掉所有 WONTON_*，先留一份。
core_subnet="${WONTON_DEV_CORE_SUBNET:-}"
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
# kit-update 只要 lib.sh：套件缺文件、或者从没有套件的旧仓库只复制了 dev.sh 和 lib.sh 时，它也要能跑。
if [[ "${1:-}" != kit-update ]]; then
  # shellcheck source=scripts/dev-resources.sh
  . "$root/scripts/dev-resources.sh"
fi

usage() {
  sed -n 's/^#   //p' "$0" >&2
  exit 2
}

# 开发环境要用本机的 Docker：插件的数据目录是本机的路径，网页也只在本机的端口上。
local_docker() {
  local host="${DOCKER_HOST:-}"
  [[ -n "$host" ]] || host="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
  case "$host" in
    ssh://* | tcp://*) die "Docker 在别的主机上（$host）：把仓库放到那台主机上，在那里执行（见 https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md#在远程主机上开发）" ;;
  esac
}

# .env 里的路径不加引号，compose 和这些脚本都按原样读。
check_path() {
  case "$root" in
    *[[:space:]\'\"\$\\\#]*) die "仓库的路径里有空白、引号或 \$\\# 这类字符：$root，换个目录" ;;
  esac
}

random_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

port_free() {
  ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# 第一次 up：定下实例名、基础域名和端口。实例名默认取目录名（去掉 wonton-plugin- 前缀）加 4 位随机数，同一个仓库的
# 两份检出也不会撞上。
first_settings() {
  instance="${WONTON_INSTANCE:-}"
  if [[ -z "$instance" ]]; then
    local base
    base="$(basename "$root")"
    base="${base#wonton-plugin-}"
    base="$(printf '%s' "${base#wonton-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-10)"
    instance="${base:-dev}$(random_hex 2)"
  fi
  [[ "$instance" =~ ^[a-z0-9]{1,16}$ ]] || die "实例名 $instance 不合法：只能用小写字母和数字，最长 16 个字符"
  port="${WONTON_PORT:-}"
  if [[ -z "$port" ]]; then
    local _
    for _ in $(seq 1 20); do
      port=$((20000 + 2 * ($(od -An -N2 -tu2 /dev/urandom) % 5000)))
      port_free "$port" && break
    done
  fi
  source="${WONTON_CORE_IMAGE:-$default_image}"
  pull="${WONTON_PULL:-}"
  owner_email="${WONTON_OWNER_EMAIL:-owner@$instance.wonton.localhost}"
}

load_settings() {
  instance="$(setting WONTON_INSTANCE)"
  [[ "$instance" =~ ^[a-z0-9]{1,16}$ ]] || die "实例名 $instance 不合法：只能用小写字母和数字，最长 16 个字符"
  port="$(setting WONTON_PORT)"
  source="$(setting WONTON_CORE_SOURCE)"
  pull="${WONTON_PULL:-$(setting WONTON_PULL)}"
  owner_email="$(setting WONTON_OWNER_EMAIL)"
  [[ -n "$owner_email" ]] || owner_email="owner@$instance.wonton.localhost"
}

write_settings() {
  mkdir -p "$state/data"
  (
    umask 077
    python3 "$root/scripts/dev_settings.py" "$env_file" <<EOF
WONTON_CORE_SOURCE=$source
WONTON_CORE_IMAGE=$image
WONTON_PULL=$pull
WONTON_INSTANCE=$instance
WONTON_CORE_CONTAINER=wonton-$instance--core
WONTON_BASE_DOMAIN=$instance.wonton.localhost
WONTON_PORT=$port
WONTON_TUNNEL_PORT=$((port + 1))
WONTON_INSTALL_DIR=$state
WONTON_DATA_DIR=$state/data
WONTON_OWNER_EMAIL=$owner_email
WONTON_PUID=$(id -u)
WONTON_PGID=$(id -g)
WONTON_LAN_ADDRESSES=
WONTON_EGRESS_PROXY=
WONTON_EGRESS_PROXY_DETECTED=
WONTON_PLUGIN_SLICE=
TZ=UTC
RUST_LOG=info
EOF
  )
}

# 设置读进来以后，去掉环境里的 WONTON_*：docker compose 先看环境变量再看 .env，调用时带着的会盖过 .env。
forget_environment() {
  local name
  for name in $(compgen -v WONTON_ || true); do
    unset "$name"
  done
}

# plugin pack 和实例名（WONTON_INSTANCE）是同一个版本加进核心的。更早的核心不认实例名，会按正式安装的名字管资源，
# 卸载插件时可能删掉这台 Docker 上别的核心装的同一个插件，所以不能用。
check_core_image() {
  local usage
  usage="$(docker run --rm --network none "$1" plugin pack 2>&1 || true)"
  [[ "$usage" == *"plugin pack"* ]] ||
    die "核心镜像 $1 太旧，不支持开发环境（没有 wonton-core plugin pack 和 WONTON_INSTANCE）：换新版本"
}

compose() {
  local files=(-f "$state/compose.yaml")
  [[ -z "$core_subnet" ]] ||
    printf 'networks:\n  core:\n    ipam:\n      config:\n        - subnet: %s\n' "$core_subnet" >"$state/compose.subnet.yaml"
  [[ ! -f "$state/compose.subnet.yaml" ]] || files+=(-f "$state/compose.subnet.yaml")
  docker compose -p "wonton-$instance" "${files[@]}" "$@"
}

up() {
  local_docker
  check_path
  if [[ -f "$env_file" ]]; then load_settings; else first_settings; fi
  forget_environment
  if [[ "$pull" == never ]]; then
    docker image inspect "$source" >/dev/null 2>&1 || die "本机没有核心镜像 $source"
  else
    info "拉取核心镜像 $source"
    docker pull -q "$source" >/dev/null || die "拉不到核心镜像 $source"
  fi
  # 和正式安装一样按 digest 写下用的是哪个镜像；本机构建的镜像没有 digest，照原样写。
  image="$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$source")"
  image="${image:-$source}"
  check_core_image "$image"
  write_settings
  info "生成密钥和配置（已有的沿用）"
  docker run --rm --user "$(id -u):$(id -g)" -v "$state:$state" "$image" init "$state" "$instance.wonton.localhost" >/dev/null
  info "启动核心、身份提供方和 Matrix 服务器（第一次要拉镜像，几分钟）"
  compose up -d --wait --wait-timeout 600 || die "没有在 10 分钟内就绪，看看日志：scripts/dev.sh logs"
  need_env
  fill_profile
  echo "开发环境就绪：http://$instance.wonton.localhost:$port/（实例 $instance）"
  echo "浏览器打开它，用 scripts/dev.sh token 输出的用户令牌登录；接着 scripts/dev.sh install 装插件"
}

# 下面的命令要开发环境已经 up 过。
need_env() {
  [[ -f "$env_file" && -f "$state/compose.yaml" ]] || die "还没有开发环境：先 scripts/dev.sh up"
  load_settings
  forget_environment
  core="wonton-$instance--core"
  base_url="http://$instance.wonton.localhost:$port"
}

token() {
  docker exec "$core" cat "$state/data/core/owner-token" 2>/dev/null ||
    die "读不到用户令牌：核心没在运行？先 scripts/dev.sh up"
}

# 调核心的管理接口。*.localhost 由 curl 自己解析到本机，不经代理。常在 $(…) 里调用，bash 在那里不带 set -e，
# 所以读不到令牌时要自己退出。
api() {
  local method="$1" path="$2" owner
  shift 2
  owner="$(token)" || exit 1
  curl -sS --noproxy '*' --fail-with-body -X "$method" \
    -H "Authorization: Bearer $owner" -H "Accept-Language: zh-CN,zh;q=0.9" \
    "$@" "$base_url$path"
}

api_command() {
  [[ $# -ge 2 ]] || usage
  need_env
  api "$@"
}

egress_proxy() {
  local address="${1:-}" current body result
  [[ $# -eq 1 ]] || usage
  need_env
  current="$(api GET /_wonton/api/egress-proxy)" ||
    die "读不到出口代理设置：$(error_text "$current")"
  body="$(python3 - "$current" "$address" <<'PY'
import json, sys

settings = json.loads(sys.argv[1])
print(json.dumps({
    "url": sys.argv[2],
    "direct_cidrs": settings["direct_cidrs"],
    "restarts": [item["id"] for item in settings["restarts"]],
}, ensure_ascii=False))
PY
  )" || die "看不懂核心回的出口代理设置：$current"
  result="$(api PUT /_wonton/api/egress-proxy -H 'Content-Type: application/json' -d "$body")" ||
    die "设置出口代理失败：$(error_text "$result")"
  printf '%s\n' "$result"
}

# 要邮箱的插件装不上没填资料的核心。用户在 App 里填，开发环境没有 App，这里替他填；填过的不动。显示名用用户名，和没填过
# 名字时一样。没有这个接口（404）的核心从 .env 读邮箱。
fill_profile() {
  local result status body
  result="$(api GET /_wonton/api/me -w '\n%{http_code}' 2>/dev/null)" || true
  status="${result##*$'\n'}"
  body="${result%$'\n'*}"
  [[ "$status" != 404 ]] || return 0
  [[ "$status" == 200 ]] || die "读不到你的资料：$(error_text "$body")"
  body="$(python3 - "$body" "$owner_email" <<'PY'
import json, sys
profile = json.loads(sys.argv[1])
if not profile.get("email"):
    print(json.dumps({"display_name": profile.get("display_name") or profile["username"], "email": sys.argv[2]}))
PY
  )" || die "看不懂核心回的资料：$result"
  [[ -n "$body" ]] || return 0
  info "填上你的资料（$owner_email）"
  result="$(api PUT /_wonton/api/me -H 'Content-Type: application/json' -d "$body")" ||
    die "填不上你的资料：$(error_text "$result")"
}

# 接口报错时给人看的一行：核心回的是 {"error": {"kind", "message"}}，别的原样给出。
error_text() {
  python3 - "$1" <<'PY'
import json, sys
text = sys.argv[1]
try:
    error = json.loads(text)["error"]
    print(f"{error['message']}（{error['kind']}）")
except Exception:
    print(text.strip() or "没有回应")
PY
}

# 把安装预览给人看（标准错误），标准输出是要授予的权限，逗号分隔；装不了时退出码 1。
show_preview() {
  python3 - "$1" <<'PY'
import json, sys
p = json.loads(sys.argv[1])
say = lambda line: print(line, file=sys.stderr)
say(f"{p['title']}  {p['id']} {p['version']}")
for line in p["permissions"]:
    mark = "（高权限）" if line.get("risk") else ""
    say(f"  权限：{line['text']}（{line['permission']}）{mark}")
if not p["permissions"]:
    say("  不需要权限")
for notice in p["notices"]:
    say(f"  提示：{notice['text']}")
if p.get("blocked"):
    say(f"装不了：{p['blocked']}")
    sys.exit(1)
print(",".join(line["permission"] for line in p["permissions"]))
PY
}

install_plugin() {
  local yes="" ref="" dir="$root" arg preview grants result answer
  for arg in "$@"; do
    case "$arg" in
      --yes) yes=1 ;;
      -*) usage ;;
      *) [[ -z "$ref" ]] || usage; ref="$arg" ;;
    esac
  done
  need_env
  # 放在 .wonton/ 里：Docker Desktop 一定能挂载仓库下面的目录。退出时才删，所以 tmp 不是局部变量。
  tmp="$(mktemp -d "$state/tmp.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  if [[ -n "$ref" ]]; then
    mkdir "$tmp/src"
    git -C "$root" archive "$ref" | tar -x -C "$tmp/src" || die "导不出 $ref（git archive 失败）"
    dir="$tmp/src"
  fi
  in_core "$dir" plugin pack /plugin >"$tmp/package.tar" || die "打包失败，原因见上面"
  preview="$(api POST /_wonton/api/plugins/preview -H 'Content-Type: application/x-tar' --data-binary @"$tmp/package.tar")" ||
    die "预览失败：$(error_text "$preview")"
  grants="$(show_preview "$preview")" || exit 1
  if [[ -z "$yes" ]]; then
    read -r -p "确认安装？[y/N] " answer
    [[ "$answer" == [yY] ]] || die "没装"
  fi
  result="$(api POST "/_wonton/api/plugins?grant=$grants" -H 'Content-Type: application/x-tar' --data-binary @"$tmp/package.tar")" ||
    die "安装失败：$(error_text "$result")"
  python3 - "$result" <<'PY'
import json, sys
p = json.loads(sys.argv[1])
print(f"装好了：{p['title']}" + (f"，网页 {p['web_url']}" if p.get("web_url") else ""))
PY
}

uninstall_plugin() {
  local purge="" id result
  case "${1:-}" in
    '') ;;
    --purge) purge=1 ;;
    *) usage ;;
  esac
  need_env
  id="$(plugin_id)"
  result="$(api DELETE "/_wonton/api/plugins/$id${purge:+?purge=true}")" || die "卸载失败：$(error_text "$result")"
  if [[ -n "$purge" ]]; then echo "卸载了 $id，数据也删了"; else echo "卸载了 $id，数据留着，再装时接着用"; fi
}

# 装着就先卸载（保留数据），没装就直接装。
reinstall() {
  local yes="" arg id result
  for arg in "$@"; do
    case "$arg" in
      --yes) yes=--yes ;;
      *) usage ;;
    esac
  done
  need_env
  id="$(plugin_id)"
  if result="$(api GET "/_wonton/api/plugins/$id" 2>/dev/null)"; then
    uninstall_plugin
  elif [[ "$result" != *'"not_installed"'* ]]; then
    die "查不到 $id 装没装：$(error_text "$result")"
  fi
  install_plugin $yes
}

rebuild() {
  [[ $# -eq 0 ]] || usage
  need_env
  info "重建核心栈（其他插件容器由核心管理，不重建）"
  compose up -d --force-recreate --wait --wait-timeout 600 || die "没有在 10 分钟内就绪，看看日志：scripts/dev.sh logs"
  reinstall
}

status() {
  need_env
  compose ps --format 'table {{.Service}}\t{{.Status}}'
  local list
  list="$(api GET /_wonton/api/plugins)" || die "列不出插件：$(error_text "$list")"
  python3 - "$list" <<'PY'
import json, sys
plugins = json.loads(sys.argv[1])["plugins"]
print()
for p in plugins:
    status = p["status"]
    detail = status.get("health") or status.get("reason") or ""
    print(f"{p['id']}\t{p['version']}\t{status['state']} {detail}\t{p.get('web_url') or ''}")
if not plugins:
    print("还没有装插件")
PY
}

logs() {
  need_env
  if [[ -z "${1:-}" ]]; then
    compose logs -f --tail 200 core
    return
  fi
  local id
  id="$(plugin_id)"
  docker logs -f --tail 200 "wonton-$instance--${id//./-}--$1"
}

# 插件网页入口：核心把清单的 webui.path（没写就是 /）拼在域名后面，从这里开始走应用的登录链。
plugin_web_entry() {
  local id="$1" list
  list="$(api GET /_wonton/api/plugins)" || die "列不出插件：$(error_text "$list")"
  python3 - "$list" "$id" <<'PY'
import json, sys
plugin = next((p for p in json.loads(sys.argv[1])["plugins"] if p["id"] == sys.argv[2]), None)
if plugin is None:
    sys.exit(f"{sys.argv[2]} 还没装：先 scripts/dev.sh install")
if not plugin.get("web_url"):
    sys.exit(f"{sys.argv[2]} 没有网页入口（清单里没写 webui）")
print(plugin["web_url"])
PY
}

plugin_web_url() {
  local entry
  entry="$(plugin_web_entry "$1")" || exit 1
  python3 -c 'import urllib.parse, sys; p = urllib.parse.urlsplit(sys.argv[1]); print(f"{p.scheme}://{p.netloc}")' "$entry"
}

session_jar() {
  echo "${WONTON_DEV_JAR:-$state/session.cookies}"
}

# 应用用 JS 自动提交隐藏字段的 POST 表单时，取字段并提交，跟完 SSO 重定向。
sso_form_login() {
  local jar="$1" url="$2"
  local method=GET request_url="$url" data="" page_file effective form action
  for _ in $(seq 1 8); do
    page_file="$(mktemp)"
    if [[ "$method" == GET ]]; then
      effective="$(curl -sS --noproxy '*' --fail-with-body -L -b "$jar" -c "$jar" \
        -H 'Accept: text/html' -o "$page_file" -w '%{url_effective}' "$request_url")" || {
        rm -f "$page_file"
        die "读取 SSO 页面失败"
      }
    else
      effective="$(curl -sS --noproxy '*' --fail-with-body -L -b "$jar" -c "$jar" \
        -H 'Accept: text/html' -o "$page_file" -w '%{url_effective}' \
        --data "$data" "$request_url")" || {
        rm -f "$page_file"
        die "提交 SSO 表单失败"
      }
    fi
    form="$(python3 - "$page_file" "$effective" <<'PY'
from html.parser import HTMLParser
from urllib.parse import urlencode, urljoin
import sys

class Forms(HTMLParser):
    def __init__(self):
        super().__init__()
        self.current = None
        self.forms = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "form" and self.current is None:
            self.current = {"action": attrs.get("action", ""),
                            "method": attrs.get("method", "post").lower(),
                            "fields": []}
        elif tag == "input" and self.current is not None:
            name = attrs.get("name")
            if name and attrs.get("type", "text").lower() == "hidden":
                self.current["fields"].append((name, attrs.get("value", "")))

    def handle_endtag(self, tag):
        if tag == "form" and self.current is not None:
            self.forms.append(self.current)
            self.current = None

page_file, base = sys.argv[1:]
parser = Forms()
with open(page_file, encoding="utf-8", errors="replace") as page:
    parser.feed(page.read())
for form in parser.forms:
    if form["method"] != "post" or not form["fields"]:
        continue
    print(urljoin(base, form["action"]))
    print(urlencode(form["fields"]))
    break
PY
    )" || {
      rm -f "$page_file"
      die "解析 SSO 页面失败"
    }
    rm -f "$page_file"
    [[ -n "$form" ]] || return 0
    action="${form%%$'\n'*}"
    data="${form#*$'\n'}"
    [[ "$form" == *$'\n'* && -n "$action" ]] || die "SSO 表单缺少提交地址"
    method=POST
    request_url="$action"
  done
  die "SSO 表单重复出现，超过 8 次"
}

# 登进核心，再走一遍插件网页的登录跳转；--sso 还会跟完 JS 自动提交的隐藏字段表单。
session_into() {
  local jar="$1" new="$2" sso="${3:-}" owner entry
  [[ -n "$sso" ]] && new=1
  mkdir -p "$(dirname "$jar")"
  [[ -n "$new" ]] && rm -f "$jar"
  [[ -f "$jar" ]] && return 0
  owner="$(token)"
  entry="$(plugin_web_entry "$(plugin_id)")"
  curl -sS --noproxy '*' --fail-with-body -o /dev/null -c "$jar" --data-urlencode "token=$owner" \
    "$base_url/_wonton/login" || die "用户令牌登录不了核心"
  if [[ -n "$sso" ]]; then
    sso_form_login "$jar" "$entry"
  else
    curl -sS --noproxy '*' -o /dev/null -L -b "$jar" -c "$jar" -H 'Accept: text/html' "$entry" ||
      die "走不通插件网页的登录跳转"
  fi
}

session() {
  local new=""
  case "${1:-}" in
    '') ;;
    --new) new=1 ;;
    *) usage ;;
  esac
  need_env
  session_into "$(session_jar)" "$new"
  session_jar
}

# 带用户会话请求插件网页，其余参数原样交给 curl。`--sso` 会跟完应用登录页的隐藏字段表单。
web() {
  local path="/" jar fresh="" sso="" url
  jar="$(session_jar)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jar) [[ $# -ge 2 ]] || usage; jar="$2"; shift 2 ;;
      --fresh) fresh=1; shift ;;
      --sso) sso=1; shift ;;
      /*) path="$1"; shift; break ;;
      *) usage ;;
    esac
  done
  need_env
  [[ "$path" == /* ]] || usage
  session_into "$jar" "$fresh" "$sso"
  url="$(plugin_web_url "$(plugin_id)")"
  curl -sS --noproxy '*' --fail-with-body -b "$jar" -c "$jar" "$@" "$url$path"
}

if [[ "${1:-}" != kit-update ]]; then
  # shellcheck source=scripts/dev-mcp.sh
  . "$root/scripts/dev-mcp.sh"
fi

mcp() {
  local direct="" sub gw url
  if [[ "${1:-}" == --direct ]]; then direct=1; shift; fi
  sub="${1:-}"
  case "$sub" in
    list) [[ $# -eq 1 ]] || usage ;;
    call) [[ $# -ge 2 && $# -le 3 && -n "$2" ]] || usage ;;
    *) usage ;;
  esac
  need_env
  if [[ -n "$direct" ]]; then
    mcp_direct "$@"
    return
  fi
  gw="wonton-$instance--com-nousresearch-hermes--gateway"
  docker container inspect "$gw" >/dev/null 2>&1 ||
    die "没有 Hermes gateway 容器（$gw）：先装上 Hermes"
  url="$(docker exec "$gw" printenv WONTON_MCP_URL 2>/dev/null)" || true
  [[ -n "$url" ]] || die "gateway 容器里没有 WONTON_MCP_URL：它的清单没申请 tools？"
  case "$sub" in
    list) docker exec -i "$gw" python3 - list "$url" <"$root/scripts/mcp_client.py" ;;
    call) docker exec -i "$gw" python3 - call "$url" "$2" "${3:-{\}}" <"$root/scripts/mcp_client.py" ;;
  esac
}

approve_pending() {
  local list cards id title reply failed=0
  list="$(api GET /_wonton/api/confirmations)" || die "取不到等回答的卡片：$(error_text "$list")"
  cards="$(python3 - "$list" <<'PY'
import json, sys
for card in json.loads(sys.argv[1])["confirmations"]:
    print(card["id"], card["title"].replace("\t", " ").replace("\n", " "), sep="\t")
PY
  )" || die "看不懂核心回的确认卡片：$list"
  [[ -n "$cards" ]] || return 3
  while IFS=$'\t' read -r id title; do
    if reply="$(api POST "/_wonton/confirmations/$id" -H 'Content-Type: application/json' -d '{"answer":"approve"}')"; then
      echo "已批准：$title"
    else
      echo "没批准：$title：$(error_text "$reply")" >&2
      failed=1
    fi
  done <<<"$cards"
  return "$failed"
}

approve() {
  local watch="" status
  case "${1:-}" in
    '') ;;
    --watch) watch=1 ;;
    *) usage ;;
  esac
  [[ $# -le 1 ]] || usage
  need_env
  while true; do
    status=0
    approve_pending || status=$?
    if [[ -z "$watch" ]]; then
      if ((status == 3)); then echo "没有等回答的卡片"; return 0; fi
      return "$status"
    fi
    ((status == 0 || status == 3)) || return "$status"
    sleep 2
  done
}

pair() {
  need_env
  "$state/wonton" pair
}

remove_instance_runtime() {
  local label="label=wonton.instance=$instance" prefix="wonton-$instance--"
  remove_instance_containers
  docker network ls --filter "$label" --format '{{.ID}} {{.Name}}' |
    while read -r id name; do
      case "$name" in
        "$prefix"*) printf '%s\n' "$name" ;;
      esac
    done | while read -r network; do
      # 核心接在每个插件网络上；不摘线就删不掉网络。
      docker network disconnect -f "$network" "wonton-$instance--core" >/dev/null 2>&1 || true
      docker network rm "$network" >/dev/null
    done
}

reset_environment() {
  [[ $# -eq 0 ]] || usage
  need_env
  remove_instance_runtime
  echo "重置了实例 $instance（插件容器和网络已清理，数据保留）"
}


purge() {
  local yes="" answer image kind rows id name failed=""
  case "${1:-}" in
    '') ;;
    --yes) yes=1 ;;
    *) usage ;;
  esac
  [[ $# -le 1 ]] || usage
  [[ -f "$env_file" ]] || die "没有开发环境"
  load_settings
  forget_environment
  if [[ -z "$yes" ]]; then
    [[ -t 0 ]] || die "非交互执行 purge 必须带 --yes；交互执行请运行 scripts/dev.sh purge"
    read -r -p "删掉整个开发环境（实例 $instance），包括装着的插件和它们的数据？[y/N] " answer
    [[ "$answer" == [yY] ]] || die "没删"
  fi
  remove_instance_containers || failed=1
  [[ ! -f "$state/compose.yaml" ]] || compose down --volumes --remove-orphans || failed=1
  remove_remaining_containers || failed=1
  for kind in network volume; do
    rows="$(instance_resources "$kind")" || die "列不出实例 $kind，未继续清理"
    while IFS=$'\t' read -r id name; do
      [[ -n "$id" ]] || continue
      docker "$kind" rm "$id" >/dev/null || failed=1
    done <<<"$rows"
  done
  check_instance_removed || die "实例 $instance 还有残留；未删除设置和数据，请处理后再 purge"
  [[ -z "$failed" ]] || die "实例 $instance 清理时有命令失败；设置和数据保留，请核对后再 purge"
  warn_shared_egress || die "检查共享出口资源失败；设置和数据保留"
  # 核心以 root 运行，数据目录里有 root 的文件，所以在容器里以 root 删。
  image="$(setting WONTON_CORE_IMAGE)"
  docker run --rm --network none --user 0 --entrypoint rm -v "$(dirname "$state"):/state-parent" "$image" -rf "/state-parent/$(basename "$state")"
  echo "删掉了实例 $instance"
}

if [[ "${1:-}" == kit-update ]]; then
  # shellcheck source=scripts/dev-kit.sh
  . "$root/scripts/dev-kit.sh"
  kit_update "${@:2}"
  exit
fi

need docker curl python3
# 起容器前剥掉宿主机的 Docker 客户端代理（见 lib.sh 的 strip_docker_proxies；空参数=用 $state 下的默认目录）。
strip_docker_proxies ""
case "${1:-}" in
  up) up ;;
  install) install_plugin "${@:2}" ;;
  reinstall) reinstall "${@:2}" ;;
  rebuild) rebuild "${@:2}" ;;
  uninstall) uninstall_plugin "${@:2}" ;;
  status) status ;;
  logs) logs "${@:2}" ;;
  token)
    need_env
    token
    ;;
  web) web "${@:2}" ;;
  api) api_command "${@:2}" ;;
  egress) egress_proxy "${@:2}" ;;
  session) session "${@:2}" ;;
  mcp) mcp "${@:2}" ;;
  approve) approve "${@:2}" ;;
  smoke) "$root/scripts/smoke.sh" "${@:2}" ;;
  probes)
    # 探针套件在这里才 source：里面有的名字（如 mcp）会盖过本文件的函数，probes 自己的路不受影响。
    # shellcheck source=scripts/probes.sh
    . "$root/scripts/probes.sh"
    probes_cmd "${@:2}"
    ;;
  pair) pair ;;
  down)
    need_env
    compose down
    ;;
  reset) reset_environment "${@:2}" ;;
  purge) purge "${@:2}" ;;
  *) usage ;;
esac
