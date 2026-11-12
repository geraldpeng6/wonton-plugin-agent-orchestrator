# shellcheck shell=bash
# shellcheck disable=SC2154 # instance 由 dev.sh 加载设置。
# 由 dev.sh 加载：把一个 OpenAI 兼容的服务商接成开发环境模型网关的上游。开发环境的网关默认一个模型也没有，
# 申请了 models 的插件只能验到“没有模型”；接上以后才能端到端验对话。
#
# key 只从文件读，经标准输入交给核心：不进命令行参数（ps 看得到）、不进环境变量（docker inspect 看得到），也不打印。
# 它会存进开发环境模型网关的数据目录（.wonton/ 下，purge 时一起删），所以用一把一次性的、限定了模型的 key，
# 验完在服务商那边吊销，不用自己的主 key。
model_upstream() {
  local url="${1:-}" model="${2:-}" key_file="${3:-}" host gateway result
  [[ $# -eq 3 && -n "$model" && -n "$key_file" ]] || usage
  [[ "$url" =~ ^https?://[^/[:space:]]+ ]] || die "上游地址要以 http:// 或 https:// 开头：$url"
  [[ -f "$key_file" && -r "$key_file" && -s "$key_file" ]] || die "读不到 key 文件，或它是空的：$key_file"
  need_env
  # 地址是从模型网关的容器里看的。Docker Desktop、OrbStack 的容器能用 host.docker.internal 访问本机；Linux 上没有
  # 这个名字，换成模型网关所在插件网络的网关地址（就是本机在这个网络里的地址）。本机防火墙要放行这个网络访问上游的端口。
  host="${url#*://}"
  host="${host%%[:/]*}"
  if [[ "$host" == host.docker.internal ]] &&
    ! docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qE 'Docker Desktop|OrbStack'; then
    gateway="$(docker network inspect "wonton-$instance--ai-usemagpie-magpie" \
      --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)" || gateway=""
    if [[ -z "$gateway" ]]; then
      die "找不到模型网关的插件网络 wonton-$instance--ai-usemagpie-magpie：核心没装好模型网关？看 scripts/dev.sh status"
    fi
    url="${url/host.docker.internal/$gateway}"
  fi
  # 核心先用这个模型发一次真实请求再保存：key 被拒、模型不存在会如实报错；连不上时网关照样保存，核心报连不上。
  # 网关不收同一地址和 key 的第二条服务商（magpie 实测），换模型重试前要在“模型设置”里删掉上一次存下的。
  result="$(python3 - "$url" "$model" "$key_file" <<'PY' |
import json, sys

url, model, path = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    key = f.read().strip()
if not key or any(c.isspace() for c in key):
    sys.exit("key 文件里应该只有一行 key")
print(json.dumps({"base_url": url, "model": model, "key": key}))
PY
    api PUT /_wonton/api/models/custom-provider -H 'Content-Type: application/json' --data-binary @-)" ||
    die "接模型失败：$(error_text "$result")"
  echo "模型网关接上了 $url 的 $model；默认模型会优先用它"
}
