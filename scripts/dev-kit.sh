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
  local origin sha stage path workflow keep=""
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
  # 下载走公网、不经 --noproxy：每个文件只有几十 KB，线路卡住时 3 分钟内必须结束、连接 30 秒不通也不再等
  # （SMOKE_DOWNLOAD_MAX_TIME / SMOKE_CONNECT_TIMEOUT，见 lib.sh），卡住时套件不会换到半份文件。
  curl_t "$SMOKE_DOWNLOAD_MAX_TIME" "$base/scripts/kit.files" -sSL --connect-timeout "$SMOKE_CONNECT_TIMEOUT" \
    -o "$stage/scripts/kit.files" || die "取不到开发套件清单（$sha）"
  local -a files=()
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ "$path" =~ ^[a-zA-Z0-9_./-]+$ && "$path" != /* && "/$path/" != */../* && "/$path/" != */./* ]] ||
      die "开发套件清单里的路径不合法：$path"
    [[ " ${files[*]} " != *" $path "* ]] || die "开发套件清单里重复的路径：$path"
    files+=("$path")
    [[ "$path" != scripts/kit.files ]] || continue
    mkdir -p "$stage/$(dirname "$path")"
    curl_t "$SMOKE_DOWNLOAD_MAX_TIME" "$base/$path" -sSL --connect-timeout "$SMOKE_CONNECT_TIMEOUT" \
      -o "$stage/$path" || die "取不到开发套件文件 $path（$sha），没有替换文件"
    case "$path" in scripts/*.sh) chmod +x "$stage/$path" ;; esac
  done <"$stage/scripts/kit.files"
  if ! grep -qxF scripts/kit.files "$stage/scripts/kit.files" ||
    ! grep -qxF .github/workflows/check.yml "$stage/scripts/kit.files"; then
    die "开发套件清单缺少 kit.files 或 check.yml"
  fi
  # 一个仓库放多家插件（仓库根没有 docker-compose.yml）：检查工作流按子目录分作业、发布按 <目录名>/v<版本> 打 tag，
  # 都是那个仓库自己写的，不换成模板的单插件版本。
  if [[ ! -f "$root/docker-compose.yml" ]]; then
    keep=" .github/workflows/check.yml scripts/publish.sh "
    info "一个仓库多家插件：保留本仓库的检查工作流和发布脚本。"
  else
    workflow="$stage/.github/workflows/check.yml"
    sed -E "s~uses: (\./|geraldpeng6/wonton-plugin-template/)\.github/workflows/plugin-check\.yml(@[^[:space:]]+)?~uses: geraldpeng6/wonton-plugin-template/.github/workflows/plugin-check.yml@$sha~" \
      "$workflow" >"$stage/check.yml"
    mv "$stage/check.yml" "$workflow"
    grep -qF "uses: geraldpeng6/wonton-plugin-template/.github/workflows/plugin-check.yml@$sha" "$workflow" ||
      die "开发套件的 check.yml 没有可固定的工作流引用，没有替换文件"
  fi
  printf '%s\n' "$sha" >"$stage/scripts/KIT"
  # 所有下载和改写完成后才替换；临时目录在仓库内，mv 不跨文件系统。
  for path in "${files[@]}" scripts/KIT; do
    [[ "$keep" != *" $path "* ]] || continue
    mkdir -p "$root/$(dirname "$path")"
  done
  for path in "${files[@]}" scripts/KIT; do
    [[ "$keep" != *" $path "* ]] || continue
    mv "$stage/$path" "$root/$path"
  done
  if [[ -f "$root/.github/workflows/plugin-check.yml" ]]; then
    rm "$root/.github/workflows/plugin-check.yml"
    info "已删除本地 .github/workflows/plugin-check.yml，CI 改为调用模板的固定提交。"
  fi
  git -C "$root" diff --stat
)
