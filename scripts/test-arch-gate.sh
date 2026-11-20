#!/usr/bin/env bash
# =============================================================================
# 零网络回归测试 —— 架构门（target_has_arch）与清单产出（write_inventory）
#
# 为什么需要它：
#   `require_arch=` 是"别把 amd64 镜像部署到 arm64 机器上"的保险，而这条逻辑
#   很难用真 registry 去测 —— 要么网络不通（很多内网机器拉不到 docker.io），
#   要么不想为了测个判定去拉几个 GB。这里用一个**假 skopeo** 喂真实形态的
#   manifest JSON，把判定逻辑单独测掉，几毫秒跑完，不联网。
#
# 用法：
#   bash scripts/test-arch-gate.sh
#   PYTHON=/path/to/python3 bash scripts/test-arch-gate.sh   # 额外校验 JSON 合法性
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# 假 skopeo：行为对齐真 skopeo
#   inspect --raw        → 吐出清单原文（index / 单架构，由 FAKE_KIND 决定）
#   inspect --format ... → 按 --override-arch 报告架构；平台不存在则非零退出
# ---------------------------------------------------------------------------
cat > "$TMP/fake-skopeo.sh" <<'STUB'
#!/usr/bin/env bash
set -u
KIND="${FAKE_KIND:-index}"
ARCHS="${FAKE_ARCHS:-amd64 arm64}"
arch=""; raw=0
while (( $# > 0 )); do
  case "$1" in
    --override-arch) arch="${2:-}"; shift 2 ;;
    --override-os|--tmpdir|--authfile|--format) shift 2 ;;
    --raw) raw=1; shift ;;
    inspect|copy) shift ;;
    *) shift ;;
  esac
done
if (( raw )); then
  if [[ "$KIND" == "index" ]]; then
    printf '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.list.v2+json","manifests":['
    first=1
    for a in $ARCHS; do
      (( first )) || printf ','
      first=0
      printf '{"digest":"sha256:deadbeef","platform":{"architecture":"%s","os":"linux"}}' "$a"
    done
    printf ']}\n'
  else
    printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":"sha256:cafe"}}\n'
  fi
  exit 0
fi
[[ -z "$arch" ]] && arch="amd64"
for a in $ARCHS; do
  if [[ "$a" == "$arch" ]]; then printf '%s\n' "$arch"; exit 0; fi
done
printf 'FATA no image found in manifest list for architecture %s\n' "$arch" >&2
exit 1
STUB
chmod +x "$TMP/fake-skopeo.sh"

export MIRROR_LIB_ONLY=1
# shellcheck source=mirror.sh
source scripts/mirror.sh
export SKOPEO_BIN="$TMP/fake-skopeo.sh"
SYNC_MODE=skopeo
resolve_mode

printf '\n== 架构门（require_arch）==\n'
check() { # check <期望rc> <描述> <want> <kind> <archs索引里有什么>
  local want_rc="$1" desc="$2" want="$3" kind="$4" archs="$5" rc
  export FAKE_KIND="$kind" FAKE_ARCHS="$archs"
  if target_has_arch docker://fake/img:1 "$want" >/dev/null 2>&1; then rc=0; else rc=1; fi
  if [[ "$rc" == "$want_rc" ]]; then ok "$desc"; else bad "$desc（期望 rc=$want_rc，实际 rc=$rc）"; fi
}

check 0 "多架构 index 含 arm64 → 检出"                 linux/arm64  index  "amd64 arm64"
check 0 "只写 arm64（自动补 linux/）→ 检出"             arm64        index  "amd64 arm64"
check 0 "问 amd64 → 检出"                              linux/amd64  index  "amd64 arm64"
check 1 "index 里没有 riscv64 → 判无"                  linux/riscv64 index "amd64 arm64"
check 1 "index 里既没 arm64 也没 amd64 → 判无"          linux/arm64  index  "s390x ppc64le"
check 0 "单架构 arm64 镜像，问 arm64 → 检出"            linux/arm64  single "arm64"
check 1 "单架构 arm64 镜像，问 amd64 → 判无"            linux/amd64  single "arm64"

SKOPEO_PLAT=linux/arm64
target_has_arch docker://fake/img:1 linux/amd64 >/dev/null 2>&1 || true
if [[ "$SKOPEO_PLAT" == "linux/arm64" ]]; then
  ok "调用后 SKOPEO_PLAT 被还原（不污染调用方）"
else
  bad "SKOPEO_PLAT 被污染成 '$SKOPEO_PLAT'"
fi

printf '\n== 清单产出（inventory）==\n'
RESULT_FILE="$(mktemp)"
# 第 2 条故意留空 digest —— 这正是过去会串位的那种情况
emit 1 OK   docker.io/library/nginx:1.27-alpine ghcr.io/me/docker-io-library-nginx:1.27-alpine sha256:abc123 "含 linux/arm64"
emit 2 SKIP quay.io/ascend/vllm-ascend:v1        ghcr.io/me/quay-io-ascend-vllm-ascend:v1        ""          "tag 已存在"
emit 3 FAIL registry.k8s.io/pause:3.10           ghcr.io/me/registry-k8s-io-pause:3.10           -           "搬运失败"

INVENTORY_DIR="$TMP/inv"
TARGET_REGISTRY=ghcr.io
TARGET_NAMESPACE=me
MODE=skopeo
DRY_RUN=
export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=me/img-mirror GITHUB_RUN_ID=123
write_inventory >/dev/null

if grep -q '^OK=1$' "$TMP/inv/counts.env" && grep -q '^SKIP=1$' "$TMP/inv/counts.env" \
   && grep -q '^FAIL=1$' "$TMP/inv/counts.env" && grep -q '^TOTAL=3$' "$TMP/inv/counts.env"; then
  ok "counts.env 计数正确（OK=1 SKIP=1 FAIL=1 TOTAL=3）"
else
  bad "counts.env 计数不对：$(tr '\n' ' ' < "$TMP/inv/counts.env")"
fi

if grep -q 'quay.io/ascend/vllm-ascend:v1' "$TMP/inv/INVENTORY.md" \
   && grep -q '⏭️ 已存在' "$TMP/inv/INVENTORY.md"; then
  ok "INVENTORY.md 三个镜像与状态都在"
else
  bad "INVENTORY.md 内容缺失"
fi

# digest 为空时 note 不应串位（历史 bug）
if grep -q '"status": "SKIP", "note": "tag 已存在"' "$TMP/inv/inventory.json"; then
  ok "空 digest 不再导致字段串位"
else
  bad "空 digest 的字段串位了"
fi

PY="${PYTHON:-python3}"
if command -v "$PY" >/dev/null 2>&1; then
  # 走 stdin：避免把 $TMP 的 MSYS 路径交给原生 Windows 版 python（它解析不了 /tmp/...）
  if "$PY" -c 'import json,sys; json.load(sys.stdin)' < "$TMP/inv/inventory.json" 2>/dev/null; then
    ok "inventory.json 是合法 JSON"
  else
    bad "inventory.json 不是合法 JSON"
  fi
else
  printf '  \033[33m-\033[0m 跳过 JSON 解析校验（没找到 %s；可用 PYTHON=... 指定）\n' "$PY"
fi

printf '\n%d 通过 / %d 失败\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
