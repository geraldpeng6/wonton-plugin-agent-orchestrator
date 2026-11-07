#!/usr/bin/env bash
# 发布插件的一个版本：scripts/publish.sh [--official]
#
# 先把清单里的 version 改成新版本、写好 release_notes，提交，再执行它。脚本按顺序：
#   1. 检查：工作区是干净的，tag v<版本> 还没有，插件包合格。
#   2. images/<名字>/ 下的每个 Dockerfile：按清单 requirements.arch 构建镜像（没写就是 linux/amd64 和 linux/arm64），
#      推到 compose 里写的那个镜像仓库，
#      把 compose 里引用它的地方改成这个版本的摘要，提交。
#   3. 再检查一遍（--official 时按官方索引的要求）。
#   4. 打 tag v<版本>，推送当前分支和 tag（远端 origin）。
#
# 仓库公开时在 GitHub Actions 里执行（.github/workflows/publish.yml），不用本机登录镜像仓库；私有仓库的免费额度很少，
# 几个插件一起开发时很快用完，在本机执行。
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

official=""
case "${1:-}" in
  '') ;;
  --official) official=--official ;;
  *) die "用法：scripts/publish.sh [--official]" ;;
esac
need docker git python3
cd "$root"
[[ -z "$(git status --porcelain)" ]] || die "工作区有没提交的改动：先提交"
version="$(plugin_version)"
tag="v$version"
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "已经有 tag $tag：先把清单的 version 改成新版本"

# 清单的 release_notes，规格化成一行 JSON（键序无关），比较用。compose config 要求引用的文件都在：
# 发版时工作区是干净的；上一个 tag 的用 git archive 整包解出再解析。
release_notes() {
  docker compose -f "$1" config --no-interpolate --format json 2>/dev/null |
    jq -cS '."x-wonton".release_notes // empty'
}

# Dependabot 的升级 PR 只改镜像，version 和 release_notes 攒到发版时一起改：少改一样就停下提示，不自动编。
last_tag="$(git tag -l 'v*' --sort=-v:refname | head -1)"
if [[ -n "$last_tag" ]]; then
  [[ "$(printf '%s\n%s\n' "$tag" "$last_tag" | sort -V | tail -1)" == "$tag" ]] ||
    die "version $version 不比上一个 tag $last_tag 新：发版前把清单的 version 改成新版本"
  notes="$(release_notes "$root/docker-compose.yml")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/wonton-lasttag.XXXXXX")"
  git archive "$last_tag" | tar -C "$tmp" -xf -
  [[ "$notes" != "$(release_notes "$tmp/docker-compose.yml")" ]] ||
    die "release_notes 和 $last_tag 的相同：发版前把这个版本改了什么写进清单的 release_notes"
  rm -rf "$tmp"
fi

info "检查插件包"
in_core "$root" plugin check /plugin >/dev/null || die "插件包不合格，scripts/check.sh 看原因"

# 把 compose 里引用 <镜像仓库>（任意标签或摘要）的 image 行改成 <镜像仓库>:<版本>@<摘要>；YAML 锚点（&name）保留。
# 没有引用它的行时退出码 1。
pin_image() {
  python3 - "$root/docker-compose.yml" "$1" "$2" <<'PY'
import re, sys
path, name, pinned = sys.argv[1:]
line = re.compile(r"^(\s*image:\s*(?:&\S+\s+)?)(\S+/" + re.escape(name) + r")(?::[^@\s]+)?(?:@sha256:[0-9a-f]{64})?(\s*(?:#.*)?)$")
text = open(path, encoding="utf-8").read().split("\n")
found = False
for i, current in enumerate(text):
    m = line.match(current)
    if m:
        text[i] = f"{m.group(1)}{m.group(2)}:{pinned}{m.group(3)}"
        found = True
if not found:
    sys.exit(1)
open(path, "w", encoding="utf-8").write("\n".join(text))
PY
}

# compose 里引用 images/<名字>/ 的镜像仓库，如 ghcr.io/me/hello-web。
image_repo() {
  python3 - "$root/docker-compose.yml" "$1" <<'PY'
import re, sys
path, name = sys.argv[1:]
repos = {m.group(1) for m in re.finditer(r"^\s*image:\s*(?:&\S+\s+)?(\S+/" + re.escape(name) + r")(?=[:@\s]|$)",
                                          open(path, encoding="utf-8").read(), re.M)}
if len(repos) != 1:
    sys.exit(f"compose 里引用 …/{name} 的镜像有 {len(repos)} 种写法：{sorted(repos)}")
print(repos.pop())
PY
}

# origin 的网页地址，如 https://github.com/me/wonton-plugin-hello。
source_url() {
  local url host
  url="$(git remote get-url origin)"
  url="${url%.git}"
  if [[ "$url" == git@*:* ]]; then
    host="${url#git@}"
    url="https://${host%%:*}/${url#*:}"
  fi
  echo "$url"
}

# 清单 requirements.arch 写的架构，如 linux/amd64,linux/arm64；没写时两种都构建。只写 amd64 的插件（CUDA 镜像、
# 上游只发 amd64 的依赖）硬构建 arm64 会在依赖安装那一步失败。
build_platforms() {
  python3 - "$root/docker-compose.yml" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^(\s*)requirements:\s*\n((?:\1\s+.*\n?)*)", text, re.M)
arch = []
if m:
    a = re.search(r"^\s*arch:\s*\[([^\]]*)\]", m.group(2), re.M)
    if a:
        arch = [x.strip().strip("'\"") for x in a.group(1).split(",") if x.strip()]
    else:
        b = re.search(r"^(\s*)arch:\s*\n((?:\1\s*-\s*.*\n?)*)", m.group(2), re.M)
        if b:
            arch = re.findall(r"-\s*['\"]?([\w]+)", b.group(2))
print(",".join(f"linux/{x}" for x in (arch or ["amd64", "arm64"])))
PY
}

platforms="$(build_platforms)"
built=""
for dockerfile in images/*/Dockerfile; do
  [[ -e "$dockerfile" ]] || continue
  name="$(basename "$(dirname "$dockerfile")")"
  repo="$(image_repo "$name")" || exit 1
  info "构建并推送 $repo:$version（${platforms//,/、}）"
  meta="$(mktemp)"
  # 带上源码仓库，ghcr.io 据此把镜像关联到仓库；Actions 里用 GITHUB_TOKEN 推送要靠这个关联。
  source="$(source_url)"
  docker buildx build --platform "$platforms" --push --metadata-file "$meta" \
    --label "org.opencontainers.image.source=$source" \
    --annotation "index:org.opencontainers.image.source=$source" \
    -t "$repo:$version" "images/$name" || die "构建或推送 $repo 失败"
  digest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["containerimage.digest"])' "$meta")"
  rm -f "$meta"
  pin_image "$name" "$version@$digest" || die "compose 里没有引用 $repo 的 image"
  built="$built $name"
done
if [[ -n "$built" ]]; then
  git add docker-compose.yml
  built="${built# }"
  git commit -q -m "chore(release): $tag 的镜像按摘要固定（${built// /、}）"
fi

info "按发布的要求再检查一遍"
# shellcheck disable=SC2086 # $official 为空时不能变成一个空参数
in_core "$root" plugin check /plugin $official || die "插件包不合格"
git tag -a "$tag" -m "$tag"
git push origin HEAD
git push origin "$tag"
echo "发布了 $tag"
