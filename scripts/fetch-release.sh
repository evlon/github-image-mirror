#!/usr/bin/env bash
# =============================================================================
# 断点续传取件：从 GitHub Release 的分片资产下载镜像，合并后 docker load
#
# 这是给「单个大 blob 长连接中途断掉、docker/skopeo 都不做 Range 续传」准备的路子：
#   * curl -C - 断点续传，断了从断点接着下，不从头再来
#   * 分片下载 + 每片 sha256 校验，某片坏了只重下那一片
#   * 可以走 GitHub 镜像前缀（--base-url 整个换掉）
#
# 用法：
#   bash fetch-release.sh <owner/repo> <release-tag>
#   bash fetch-release.sh <owner/repo> <release-tag> --base-url https://<你的镜像>/https://github.com/<owner/repo>/releases/download/<tag>
#   bash fetch-release.sh <owner/repo> <release-tag> --dir /data/weights/_staging/image --keep
#
# 参数：
#   --base-url URL   整个下载基址（默认 https://github.com/<repo>/releases/download/<tag>）
#   --dir DIR        工作目录（默认当前目录下的 _release_dl）
#   --require-arch A 载入后校验架构（如 arm64 或 linux/arm64），不符只告警不中止
#   --keep / --no-keep  合并后是否保留分片（默认保留，便于二次重试）
#
# 依赖：curl、sha256sum、docker、以及 zstd 或 gzip（按实际压缩方式）
# =============================================================================
set -euo pipefail

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[中止] %s\033[0m\n' "$*" >&2; exit 1; }

REPO="${1:-}"; TAG="${2:-}"
[[ -n "$REPO" && -n "$TAG" ]] || { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }
shift 2

BASE_URL=""
WORK_DIR=""
KEEP=1
REQUIRE=""
while (( $# > 0 )); do
  case "$1" in
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --base-url=*) BASE_URL="${1#*=}"; shift ;;
    --dir) WORK_DIR="${2:-}"; shift 2 ;;
    --dir=*) WORK_DIR="${1#*=}"; shift ;;
    --require-arch) REQUIRE="${2:-}"; shift 2 ;;
    --require-arch=*) REQUIRE="${1#*=}"; shift ;;
    --keep) KEEP=1; shift ;;
    --no-keep) KEEP=0; shift ;;
    *) die "不认识的参数：$1" ;;
  esac
done

DOCKER="${DOCKER:-docker}"
BASE_URL="${BASE_URL:-https://github.com/$REPO/releases/download/$TAG}"
WORK_DIR="${WORK_DIR:-./_release_dl}"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

command -v curl >/dev/null 2>&1 || die "没有 curl"
command -v "$DOCKER" >/dev/null 2>&1 || die "找不到 docker：$DOCKER"

log "下载基址"
printf '  %s\n' "$BASE_URL"
printf '  工作目录：%s\n' "$(pwd)"

# ---------------------------------------------------------------------------
# 1) 先拿 SHA256SUMS.txt，从里面知道分片有几个、叫什么
# ---------------------------------------------------------------------------
fetch_small() {
  local name="$1" out="$2" i
  for i in 1 2 3 4 5; do
    if curl -fL --connect-timeout 20 --retry 5 --retry-delay 3 -C - -o "$out" "$BASE_URL/$name"; then
      return 0
    fi
    warn "第 $i 次下载 $name 失败，5 秒后重试"
    sleep 5
  done
  return 1
}

log "获取 SHA256SUMS.txt"
fetch_small "SHA256SUMS.txt" "SHA256SUMS.txt" || die "下载 SHA256SUMS.txt 失败（确认 Release 标签和 --base-url 是否正确）"
sed 's/^/  /' SHA256SUMS.txt

# 只取分片
mapfile -t PARTS < <(awk '{print $2}' SHA256SUMS.txt | sed 's/^\*//' | grep -E '\.part\.[0-9]+$' | sort)
(( ${#PARTS[@]} > 0 )) || die "SHA256SUMS.txt 里没有 .part.NNN 分片，这不是本仓库导出的资产"

NAME0="${PARTS[0]}"
MERGED="${NAME0%.part.*}"
log "共 ${#PARTS[@]} 个分片，合并后为：$MERGED"

# ---------------------------------------------------------------------------
# 2) 逐个分片断点续传下载 + 校验
# ---------------------------------------------------------------------------
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

expected_of() {
  awk -v n="$1" '{f=$2; sub(/^\*/,"",f); if (f==n) print $1}' SHA256SUMS.txt
}

for p in "${PARTS[@]}"; do
  want="$(expected_of "$p")"
  have=""
  [[ -f "$p" ]] && have="$(sha_of "$p")"

  if [[ -n "$want" && "$have" == "$want" ]]; then
    printf '  [已完整] %s\n' "$p"
    continue
  fi

  attempt=0
  while (( attempt < 20 )); do
    attempt=$((attempt + 1))
    printf '  [下载] %s（第 %s 次，-C - 断点续传）\n' "$p" "$attempt"
    if curl -fL --connect-timeout 20 --retry 5 --retry-delay 3 -C - -o "$p" "$BASE_URL/$p"; then
      have="$(sha_of "$p")"
      if [[ -z "$want" || "$have" == "$want" ]]; then
        printf '  [完成] %s  sha256=%s\n' "$p" "${have:0:16}…"
        break
      fi
      warn "$p 校验不一致（期望 ${want:0:16}… 实际 ${have:0:16}…），删掉重下"
      rm -f "$p"
    else
      warn "$p 第 $attempt 次中断，继续续传"
      sleep 3
    fi
    if (( attempt >= 20 )); then
      die "$p 反复失败，链路太差 —— 建议换个时间或用镜像前缀重试"
    fi
  done
done

# ---------------------------------------------------------------------------
# 3) 合并
# ---------------------------------------------------------------------------
log "合并分片 -> $MERGED"
: > "$MERGED"
for p in "${PARTS[@]}"; do cat "$p" >> "$MERGED"; done
ls -lh "$MERGED"

if [[ -n "$(expected_of "$MERGED")" ]]; then
  [[ "$(sha_of "$MERGED")" == "$(expected_of "$MERGED")" ]] && echo "  合并后校验通过" || die "合并后校验失败"
fi

# 校验"合并包"的完整性：直接校验每个分片就够了，这里再核一遍总数
if command -v sha256sum >/dev/null 2>&1; then
  echo "  逐片校验："
  sha256sum -c SHA256SUMS.txt 2>/dev/null | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# 4) 解压 + docker load
# ---------------------------------------------------------------------------
log "导入 docker（几分钟，别中断）"
case "$MERGED" in
  *.tar.zst) command -v zstdcat >/dev/null 2>&1 || die "需要 zstd：apt install -y zstd"
             zstdcat "$MERGED" | "$DOCKER" load ;;
  *.tar.gz|*.tgz) gunzip -c "$MERGED" | "$DOCKER" load ;;
  *.tar.xz) xz -dc "$MERGED" | "$DOCKER" load ;;
  *.tar) "$DOCKER" load -i "$MERGED" ;;
  *) die "不认识的后缀：$MERGED" ;;
esac

# ---------------------------------------------------------------------------
# 5) 核对架构（910c 必须 arm64）
# ---------------------------------------------------------------------------
log "载入完成"
"$DOCKER" images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | head -5
if [[ -n "$REQUIRE" ]]; then
  LINE="$("$DOCKER" images --format '{{.Repository}}:{{.Tag}}' | head -1)"
  A="$("$DOCKER" image inspect "$LINE" --format '{{.Architecture}}' 2>/dev/null || echo '')"
  printf '  最近导入：%s  架构：%s\n' "$LINE" "${A:-<取不到>}"
  [[ "$A" == "${REQUIRE##*/}" ]] || warn "架构是 ${A:-?}，不是 ${REQUIRE##*/} —— 导出时请用 platform=${REQUIRE}"
fi

if (( KEEP == 0 )); then
  log "清理分片"
  rm -f "${PARTS[@]}"
fi

printf '\n完成。镜像已在本地 docker 里，按需 docker tag / docker compose up 即可。\n'
