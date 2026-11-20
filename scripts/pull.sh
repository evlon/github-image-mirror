#!/usr/bin/env bash
# =============================================================================
# pull.sh —— 从你自己的搬运仓库取件到本机（或任意服务器）
#
# 场景：某台机器拉不到上游镜像，但能连你自己的 registry（或能连它的镜像站），
#       用这个脚本按清单把镜像取回来。
#
# 用法：
#   export TARGET_NAMESPACE=<你的命名空间>
#   bash scripts/pull.sh                             # 取清单里的全部
#   bash scripts/pull.sh docker.io/library/nginx:1.27-alpine
#   bash scripts/pull.sh --platform linux/arm64 --require-arch arm64
#   bash scripts/pull.sh --tag-back                  # 取回后打回源镜像名
#
# 选项：
#   --platform P        指定平台（默认不指定 = 本机架构）
#   --require-arch A    取回后校验架构，如 arm64 或 linux/arm64
#   --tag-back          取回后 docker tag 回源镜像名
#                       （给"compose / 启动脚本里写死了上游名字"的场景用）
#   --dry-run           只打印命令
#
# 环境变量：
#   TARGET_REGISTRY     默认 ghcr.io
#   TARGET_NAMESPACE    必填（清单里推导目标名要用）
#   MIRROR_PREFIX       目标 registry 的镜像站前缀，如 ghcr.nju.edu.cn
#                       （包是 public 时才能匿名走镜像站）
#   IMAGES_FILE / MIRRORS_FILE
#   DOCKER              默认 docker（也可能是 /usr/local/bin/docker）
#   PULL_TIMEOUT        单次 pull 超时秒数，默认 1800；超时算失败并重试
#   PULL_RETRIES        重试次数，默认 3（已下完的层不会重下）
#
# 如果这台机器连 registry 也撑不住（单个大 blob 的长连接中途断、且工具不做
# Range 续传），走 Release 分片 + 断点续传：
#   bash scripts/fetch-release.sh <owner/repo> <release-tag> [--base-url <镜像前缀>]
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_REGISTRY="${TARGET_REGISTRY:-ghcr.io}"
MIRROR_PREFIX="${MIRROR_PREFIX:-}"
DOCKER="${DOCKER:-docker}"
PULL_TIMEOUT="${PULL_TIMEOUT:-1800}"
PULL_RETRIES="${PULL_RETRIES:-3}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[中止] %s\033[0m\n' "$*" >&2; exit 1; }

# 复用 mirror.sh 的命名推导（不执行它的 main）
export MIRROR_LIB_ONLY=1
export TARGET_REGISTRY
export IMAGES_FILE="${IMAGES_FILE:-$SELF_DIR/../images.txt}"
export MIRRORS_FILE="${MIRRORS_FILE:-$SELF_DIR/../mirrors.env}"
# shellcheck source=mirror.sh
source "$SELF_DIR/mirror.sh"

PLATFORM=""
REQUIRE=""
TAG_BACK=""
DRY_RUN=""
ARGS=()
while (( $# > 0 )); do
  case "$1" in
    --platform)       shift; PLATFORM="${1:-}"; shift ;;
    --platform=*)     PLATFORM="${1#*=}"; shift ;;
    --require-arch)   shift; REQUIRE="${1:-}"; shift ;;
    --require-arch=*) REQUIRE="${1#*=}"; shift ;;
    --tag-back)       TAG_BACK=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                ARGS+=("$1"); shift ;;
  esac
done

[[ -n "${TARGET_NAMESPACE:-}" ]] || die "先设置 TARGET_NAMESPACE，例如：export TARGET_NAMESPACE=你的GitHub用户名"
command -v "$DOCKER" >/dev/null 2>&1 || die "找不到 docker：$DOCKER"

# ---- 收集要取的镜像（源名 -> 目标名）----
declare -a PAIRS=()
if (( ${#ARGS[@]} > 0 )); then
  for a in "${ARGS[@]}"; do
    src="$(normalize_src "$a")"
    PAIRS+=("$src"$'\t'"$(derive_target "$src")")
  done
else
  [[ -f "$IMAGES_FILE" ]] || die "找不到清单：$IMAGES_FILE（也可以把镜像名当参数传进来）"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#$'\xef\xbb\xbf'}"     # 去掉 Windows 编辑器可能加的 UTF-8 BOM
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -s '[:space:]' ' ')"
    line="${line# }"; line="${line% }"
    [[ -z "$line" ]] && continue
    set -f; set -- $line; set +f
    src="$(normalize_src "$1")"
    PAIRS+=("$src"$'\t'"$(derive_target "$src")")
  done < "$IMAGES_FILE"
fi
(( ${#PAIRS[@]} > 0 )) || die "没有要取的镜像"

# 把目标 registry 换成镜像站前缀（如果有）
apply_prefix() {
  local ref="$1"
  [[ -z "$MIRROR_PREFIX" ]] && { printf '%s' "$ref"; return 0; }
  printf '%s/%s' "${MIRROR_PREFIX%/}" "${ref#*/}"
}

# 单次 pull，带超时
pull_once() {
  local ref="$1"
  local -a args=(pull)
  if [[ -n "$PLATFORM" ]]; then args+=(--platform "$PLATFORM"); fi
  args+=("$ref")
  if [[ "$PULL_TIMEOUT" != "0" ]] && command -v timeout >/dev/null 2>&1; then
    timeout "$PULL_TIMEOUT" "$DOCKER" "${args[@]}"
  else
    "$DOCKER" "${args[@]}"
  fi
}

fail=0
idx=0
for pair in "${PAIRS[@]}"; do
  IFS=$'\t' read -r src target <<< "$pair"
  idx=$((idx + 1))
  pull_ref="$(apply_prefix "$target")"

  log "[$idx/${#PAIRS[@]}] $src"
  printf '  取件地址：%s\n' "$pull_ref"
  if [[ -n "$PLATFORM" ]]; then printf '  平台    ：%s\n' "$PLATFORM"; fi

  if [[ -n "$DRY_RUN" ]]; then
    printf '  [dry-run] %s pull %s%s\n' "$DOCKER" "${PLATFORM:+--platform $PLATFORM }" "$pull_ref"
    if [[ -n "$TAG_BACK" ]]; then printf '  [dry-run] %s tag %s %s\n' "$DOCKER" "$pull_ref" "$src"; fi
    continue
  fi

  ok=""
  attempt=0
  while (( attempt < PULL_RETRIES )); do
    attempt=$((attempt + 1))
    printf '  第 %s/%s 次拉取…\n' "$attempt" "$PULL_RETRIES"
    if pull_once "$pull_ref"; then ok=1; break; fi
    warn "第 $attempt 次失败或被超时打断（已下完的层不会重下）"
    sleep 5
  done

  if [[ -z "$ok" ]]; then
    fail=$((fail + 1))
    printf '\033[1;31m  取件失败：%s\033[0m\n' "$pull_ref"
    printf '  可以试：\n'
    printf '    - 换镜像前缀：MIRROR_PREFIX=<镜像站> bash %s\n' "${BASH_SOURCE[0]}"
    printf '    - 确认包可见性（private 需要 docker login %s）\n' "$TARGET_REGISTRY"
    printf '    - 改用断点续传通道：bash %s/fetch-release.sh <owner/repo> <release-tag>\n' "$SELF_DIR"
    continue
  fi

  if [[ -n "$REQUIRE" ]]; then
    actual_os="$("$DOCKER" image inspect "$pull_ref" --format '{{.Os}}' 2>/dev/null || true)"
    actual="$("$DOCKER" image inspect "$pull_ref" --format '{{.Architecture}}' 2>/dev/null || true)"
    printf '  实际平台：%s/%s\n' "${actual_os:-?}" "${actual:-?}"
    want_os=""; want_arch="$REQUIRE"
    if [[ "$REQUIRE" == */* ]]; then want_os="${REQUIRE%%/*}"; want_arch="${REQUIRE##*/}"; fi
    if [[ "$actual" != "$want_arch" || ( -n "$want_os" && "$actual_os" != "$want_os" ) ]]; then
      fail=$((fail + 1))
      printf '\033[1;31m  平台不符（要 %s，拿到 %s/%s），这个镜像在本机跑不起来，已跳过\033[0m\n' \
        "$REQUIRE" "${actual_os:-?}" "${actual:-?}"
      continue
    fi
  fi

  if [[ -n "$TAG_BACK" && "$pull_ref" != "$src" ]]; then
    "$DOCKER" tag "$pull_ref" "$src"
    printf '  已 tag：%s -> %s\n' "$pull_ref" "$src"
  fi
done

log "取件完成"
"$DOCKER" images --format '  {{.Repository}}:{{.Tag}}   {{.Size}}   {{.CreatedSince}}' | head -20

if (( fail > 0 )); then
  printf '\n\033[1;31m有 %s 个镜像没取到\033[0m\n' "$fail" >&2
  exit 1
fi
