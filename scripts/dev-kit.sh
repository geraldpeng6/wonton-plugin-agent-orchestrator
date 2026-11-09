# shellcheck shell=bash
# shellcheck disable=SC2154 # root 由 lib.sh 设置。
# 由 dev.sh 只在 kit-update 时加载。

kit_commit() {
  local ref="$1" refs sha name branch="" tag="" peeled="" head=""
  refs="$(git ls-remote https://github.com/geraldpeng6/wonton-plugin-template.git \
    "$ref" "$ref^{}" "refs/heads/$ref" "refs/tags/$ref" "refs/tags/$ref^{}")" ||
    die "取不到开发套件的引用 $ref"
  while read -r sha name; do
    case "$name" in
      "refs/heads/${ref#refs/heads/}") branch="$sha" ;;
      "refs/tags/${ref#refs/tags/}") tag="$sha" ;;
      "refs/tags/${ref#refs/tags/}^{}") peeled="$sha" ;;
      HEAD) head="$sha" ;;
    esac
  done <<<"$refs"
  [[ -z "$branch" || -z "$tag" ]] || die "开发套件的分支和 tag 同名：$ref，请写完整 refs/heads/ 或 refs/tags/ 引用"
  sha="${branch:-${peeled:-${tag:-$head}}}"
  # ls-remote 只列引用；完整提交 SHA 已经固定版本，后续下载仍逐个确认文件存在。
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then sha="$ref"; fi
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "找不到开发套件的引用 $ref"
  printf '%s\n' "$sha"
}

kit_update() (
  [[ $# -le 1 ]] || usage
  need git curl
  local origin sha stage path workflow
  origin="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
  case "${origin%.git}" in
    https://github.com/geraldpeng6/wonton-plugin-template | \
      http://github.com/geraldpeng6/wonton-plugin-template | \
      git@github.com:geraldpeng6/wonton-plugin-template | \
      ssh://git@github.com/geraldpeng6/wonton-plugin-template)
      echo "这里就是套件的源头，不需要 kit-update；用 git pull 更新。"
      exit 0
      ;;
  esac
  sha="$(kit_commit "${1:-main}")" || exit 1
  stage="$(mktemp -d "$root/.kit-update.XXXXXXXX")"
  trap 'rm -rf "$stage"' EXIT
  mkdir -p "$stage/scripts"
  local base="https://raw.githubusercontent.com/geraldpeng6/wonton-plugin-template/$sha"
  info "下载开发套件 $sha"
  curl -fsSL "$base/scripts/kit.files" -o "$stage/scripts/kit.files" || die "取不到开发套件清单（$sha）"
  local -a files=()
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ "$path" =~ ^[a-zA-Z0-9_./-]+$ && "$path" != /* && "/$path/" != */../* && "/$path/" != */./* ]] ||
      die "开发套件清单里的路径不合法：$path"
    [[ " ${files[*]} " != *" $path "* ]] || die "开发套件清单里重复的路径：$path"
    files+=("$path")
    [[ "$path" != scripts/kit.files ]] || continue
    mkdir -p "$stage/$(dirname "$path")"
    curl -fsSL "$base/$path" -o "$stage/$path" || die "取不到开发套件文件 $path（$sha），没有替换文件"
    case "$path" in scripts/*.sh) chmod +x "$stage/$path" ;; esac
  done <"$stage/scripts/kit.files"
  if ! grep -qxF scripts/kit.files "$stage/scripts/kit.files" ||
    ! grep -qxF .github/workflows/check.yml "$stage/scripts/kit.files"; then
    die "开发套件清单缺少 kit.files 或 check.yml"
  fi
  workflow="$stage/.github/workflows/check.yml"
  sed -E "s~uses: (\./|geraldpeng6/wonton-plugin-template/)\.github/workflows/plugin-check\.yml(@[^[:space:]]+)?~uses: geraldpeng6/wonton-plugin-template/.github/workflows/plugin-check.yml@$sha~" \
    "$workflow" >"$stage/check.yml"
  mv "$stage/check.yml" "$workflow"
  grep -qF "uses: geraldpeng6/wonton-plugin-template/.github/workflows/plugin-check.yml@$sha" "$workflow" ||
    die "开发套件的 check.yml 没有可固定的工作流引用，没有替换文件"
  printf '%s\n' "$sha" >"$stage/scripts/KIT"
  # 所有下载和改写完成后才替换；临时目录在仓库内，mv 不跨文件系统。
  for path in "${files[@]}" scripts/KIT; do
    mkdir -p "$root/$(dirname "$path")"
  done
  for path in "${files[@]}" scripts/KIT; do
    mv "$stage/$path" "$root/$path"
  done
  if [[ -f "$root/.github/workflows/plugin-check.yml" ]]; then
    rm "$root/.github/workflows/plugin-check.yml"
    info "已删除本地 .github/workflows/plugin-check.yml，CI 改为调用模板的固定提交。"
  fi
  git -C "$root" diff --stat
)
