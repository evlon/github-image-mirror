#!/usr/bin/env bash
# =============================================================================
# mirror.sh —— 按清单把镜像从源 registry 搬运到你自己的 registry（默认 GHCR）
#
# 用途：源 registry 拉不动 / 太慢 / 被墙 / 需要认证时，用 GitHub Actions（或任意
#       有网机器）代拉，推到你自己的 registry，再从自己这边取件。
#       不限于某一个项目 —— 任何"拉不到的镜像"都能往清单里加一行。
#
# 用法：
#   bash scripts/mirror.sh --dry-run          # 只打印「源 -> 目标」计划
#   bash scripts/mirror.sh                    # 同步清单里的全部镜像
#   bash scripts/mirror.sh --force            # 已存在的 tag 也重推
#   bash scripts/mirror.sh --only quay.io/ascend/vllm-ascend:v0.32.0rc1-a3-openeuler
#   SYNC_MODE=skopeo bash scripts/mirror.sh   # 指定搬运方式
#   目标若是 http registry：bash scripts/mirror.sh --insecure-dest
#
# 三种搬运方式（都不落本地磁盘）：
#   skopeo       skopeo copy：registry → registry 直拷，自带 blob 级重试；
#                不依赖 docker daemon（Windows 上就一个 skopeo.exe 也能用）
#   imagetools   docker buildx imagetools create：纯客户端直拷，runner 上最快
#   pull         docker pull + tag + push：最笨但最兼容（需要 daemon，占磁盘）
#   auto（默认） 按上面顺序挑第一个可用的
#
# 默认完整保留多架构 index，所以同一份镜像 x86 机器和 arm64 机器都能取。
#
# 可调参数见 README「可调参数」。
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 参数默认值
# ---------------------------------------------------------------------------
TARGET_REGISTRY="${TARGET_REGISTRY:-ghcr.io}"   # 目标 registry，可换 docker.io 等
TARGET_NAMESPACE="${TARGET_NAMESPACE:-}"        # 必填：目标命名空间（GHCR 的用户/组织名）
IMAGES_FILE="${IMAGES_FILE:-images.txt}"
MIRRORS_FILE="${MIRRORS_FILE:-mirrors.env}"
SYNC_MODE="${SYNC_MODE:-auto}"                  # auto | skopeo | imagetools | pull
FORCE="${FORCE:-}"                              # 非空 = 已存在的 tag 也重推
PLATFORMS="${PLATFORMS:-}"                      # 全局默认平台限定，如 linux/arm64
REQUIRE_ARCH="${REQUIRE_ARCH:-}"                # 全局默认架构校验，如 linux/arm64 或 arm64
JOBS="${JOBS:-4}"                               # 并发批大小
DRY_RUN="${DRY_RUN:-}"
ALLOW_FAIL="${ALLOW_FAIL:-}"                    # 非空 = 有失败也返回 0
EXTRA_IMAGES="${EXTRA_IMAGES:-}"                # 临时追加的镜像，空白/换行分隔
ONLY="${ONLY:-}"                                # 只同步这些源镜像，逗号分隔
INVENTORY_DIR="${INVENTORY_DIR:-}"              # 产出清单文件的目录（空=不产出）

# 目标若是 http / 自签证书的 registry，置 false
SRC_TLS_VERIFY="${SRC_TLS_VERIFY:-true}"
DEST_TLS_VERIFY="${DEST_TLS_VERIFY:-true}"

# skopeo 相关
SKOPEO_BIN="${SKOPEO_BIN:-skopeo}"              # 可指向 skopeo.exe 的完整路径
SKOPEO_AUTHFILE="${SKOPEO_AUTHFILE:-}"          # auth.json / docker config.json
SKOPEO_TMPDIR="${SKOPEO_TMPDIR:-}"              # 临时目录（个别情况 skopeo 会落盘缓冲）
SKOPEO_RETRY_TIMES="${SKOPEO_RETRY_TIMES:-3}"
SKOPEO_PLAT="${SKOPEO_PLAT:-}"                  # 运行期：当前镜像的平台
SRC_CREDS="${SRC_CREDS:-}"                      # user:pass，拉源时的凭据
DEST_CREDS="${DEST_CREDS:-}"                    # user:token，推目标时的凭据

MODE=""
TOTAL=0
declare -a ITEMS=()
# skopeo 参数分两层（实测 1.24 与 1.8 一致的划分）：
#   全局（必须在子命令之前）：--tmpdir / --override-arch / --override-os
#   子命令级（跟在 copy|inspect 之后）：--authfile / --src-creds / --dest-creds / --retry-times / --all
declare -a SKOPEO_G=()
declare -a SKOPEO_A=()
declare -a SKOPEO_I=()                        # inspect 专用（如目标是非 https 时的 --tls-verify=false）

# ITEMS 内部字段分隔符。
# 不能用 \t：tab 属于 IFS 空白字符，连续两个会被折叠成一个，空字段就错位了。
# \x1f（US）是 IFS 非空白字符，连续出现时每个都算一个真正的分隔符。
SEP=$'\x1f'

if [[ -t 1 ]]; then
  C_CYAN=$'\033[1;36m'; C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_OFF=$'\033[0m'
else
  C_CYAN=""; C_RED=""; C_YEL=""; C_OFF=""
fi

log()  { printf '\n%s==> %s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
warn() { printf '%s[warn] %s%s\n' "$C_YEL" "$*" "$C_OFF" >&2; }
die()  { printf '\n%s[中止] %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# 镜像名解析
# ---------------------------------------------------------------------------
# "nginx:1.27" / "foo/bar:1" / "quay.io/a/b:1" -> "host/path:tag"
normalize_src() {
  local ref="$1" first="${1%%/*}"
  if [[ "$ref" != */* ]]; then
    printf 'docker.io/library/%s' "$ref"
  elif [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]]; then
    printf '%s' "$ref"
  else
    printf 'docker.io/%s' "$ref"
  fi
}

# 拆出名字与 tag：输出 "name<TAB>tag"
# 规则：冒号只有在**最后一段路径里**才是 tag 分隔符
#   localhost:5000/foo   → name=localhost:5000/foo  tag=latest（冒号是端口）
#   quay.io/a/b:v1       → name=quay.io/a/b         tag=v1
#   nginx                → name=nginx               tag=latest
split_ref() {
  local ref="$1" last tag
  if [[ "$ref" == *"@"* ]]; then
    printf '%s\t%s\n' "${ref%%@*}" "${ref#*@}"
    return 0
  fi
  last="${ref##*/}"
  if [[ "$last" == *:* ]]; then
    tag="${last##*:}"
    printf '%s\t%s\n' "${ref%:*}" "$tag"
  else
    printf '%s\t%s\n' "$ref" "latest"
  fi
}

# 源镜像 -> 目标镜像。规则：<registry>/<namespace>/<源全名，/ 和 . 换成 -，转小写>:<tag>
# 想改名/换结构就在清单里写第二列显式覆盖。
derive_target() {
  local ref="$1" name tag flat
  IFS=$'\t' read -r name tag <<< "$(split_ref "$ref")"
  flat="${name//\//-}"
  flat="${flat//./-}"
  flat="$(printf '%s' "$flat" | tr 'A-Z' 'a-z')"
  flat="$(printf '%s' "$flat" | tr -c 'a-z0-9_-' '-')"
  flat="${flat%-}"
  printf '%s/%s/%s:%s' "$TARGET_REGISTRY" "$TARGET_NAMESPACE" "$flat" "$tag"
}

# 查 mirrors.env：某 host 是否有替换前缀
mirror_for_host() {
  local want="$1" line key val
  [[ -f "$MIRRORS_FILE" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#$'\xef\xbb\xbf'}"
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    [[ "$key" == "$want" ]] && { printf '%s' "$val"; return 0; }
  done < "$MIRRORS_FILE"
  return 0
}

# 实际去拉的那个引用：逐行 mirror= 优先，其次 mirrors.env
apply_mirror() {
  local ref="$1" override="${2:-}" host rest prefix
  if [[ "$ref" != */* ]]; then printf '%s' "$ref"; return 0; fi
  host="${ref%%/*}"
  rest="${ref#*/}"
  if [[ -n "$override" ]]; then
    printf '%s/%s' "${override%/}" "$rest"
    return 0
  fi
  prefix="$(mirror_for_host "$host")"
  if [[ -n "$prefix" ]]; then printf '%s/%s' "${prefix%/}" "$rest"; else printf '%s' "$ref"; fi
}

# ---------------------------------------------------------------------------
# 读清单，填 ITEMS。每项 5 个字段（TAB 分隔）：
#   src  dst  platform  require_arch  mirror
#
# 清单行格式：<源镜像> [目标镜像] [key=value ...]
#   platform=linux/arm64        只搬这个平台（多平台用逗号；仅 skopeo/pull 生效）
#   require_arch=linux/arm64    搬完校验目标里必须有这个平台
#   mirror=<host>               这一行单独指定源镜像站
# ---------------------------------------------------------------------------
load_items() {
  local line src dst tok plat arch mir item
  local -a toks=()
  [[ -f "$IMAGES_FILE" ]] || die "找不到清单文件：$IMAGES_FILE"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#$'\xef\xbb\xbf'}"     # 去掉 Windows 编辑器可能加的 UTF-8 BOM
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -s '[:space:]' ' ')"
    line="${line# }"; line="${line% }"
    [[ -z "$line" ]] && continue

    toks=()
    set -f
    # shellcheck disable=SC2086
    for tok in $line; do toks+=("$tok"); done
    set +f

    src="$(normalize_src "${toks[0]}")"
    if [[ "$src" == *"@"* ]]; then
      die "清单里的 '$src' 是 digest 引用（@sha256:...），本仓库只按 tag 搬运"
    fi
    dst=""; plat=""; arch=""; mir=""
    for tok in "${toks[@]:1}"; do
      case "$tok" in
        platform=*)     plat="${tok#*=}" ;;
        require_arch=*) arch="${tok#*=}" ;;
        mirror=*)       mir="${tok#*=}" ;;
        *=*)            die "清单里的 '$src' 有不认识的选项 '$tok'（支持 platform= / require_arch= / mirror=）" ;;
        *)
          if [[ -n "$dst" ]]; then
            die "清单里的 '$src' 有多个目标名：'$dst' 和 '$tok'"
          fi
          dst="$tok" ;;
      esac
    done
    if [[ -z "$dst" ]]; then dst="$(derive_target "$src")"; fi
    ITEMS+=("$src${SEP}$dst${SEP}$plat${SEP}$arch${SEP}$mir")
  done < "$IMAGES_FILE"

  if [[ -n "$EXTRA_IMAGES" ]]; then
    set -f
    # shellcheck disable=SC2086
    for src in $EXTRA_IMAGES; do
      set +f
      src="$(normalize_src "$src")"
      if [[ "$src" == *"@"* ]]; then
        die "临时镜像 '$src' 是 digest 引用，本仓库只按 tag 搬运"
      fi
      ITEMS+=("$src${SEP}$(derive_target "$src")${SEP}${SEP}${SEP}")
      set -f
    done
    set +f
  fi

  if [[ -n "$ONLY" ]]; then
    local -a keep=() want_list=()
    local IFS=','
    for item in $ONLY; do want_list+=("$(normalize_src "$(printf '%s' "$item" | tr -d '[:space:]')")"); done
    unset IFS
    for item in "${ITEMS[@]}"; do
      src="${item%%"$SEP"*}"
      for tok in "${want_list[@]}"; do
        if [[ "$src" == "$tok" ]]; then keep+=("$item"); fi
      done
    done
    [[ ${#keep[@]} -gt 0 ]] || die "--only 没匹配到任何镜像（源名会被规范化：nginx:1.27 → docker.io/library/nginx:1.27）"
    ITEMS=("${keep[@]}")
  fi

  [[ ${#ITEMS[@]} -gt 0 ]] || die "$IMAGES_FILE 里没有任何镜像"
}

# ---------------------------------------------------------------------------
# 能力探测
# ---------------------------------------------------------------------------
resolve_mode() {
  case "$SYNC_MODE" in
    auto)
      # 优先 skopeo：registry→registry 直拷、不落本地磁盘，且自带 blob 级重试
      if have "$SKOPEO_BIN"; then MODE=skopeo
      elif have docker && docker buildx version >/dev/null 2>&1; then MODE=imagetools
      elif have docker; then MODE=pull
      else die "没有可用的 $SKOPEO_BIN，也没有 docker —— 无法搬运"; fi
      ;;
    skopeo)     have "$SKOPEO_BIN" || die "SYNC_MODE=skopeo 需要 $SKOPEO_BIN（可用 SKOPEO_BIN 指定完整路径，如 D:/bin/skopeo.exe）"; MODE=skopeo ;;
    imagetools) have docker || die "SYNC_MODE=imagetools 需要 docker"; MODE=imagetools ;;
    pull)       have docker || die "SYNC_MODE=pull 需要 docker";      MODE=pull ;;
    *)          die "不认识的 SYNC_MODE=$SYNC_MODE（可选 auto|skopeo|imagetools|pull）" ;;
  esac

  SKOPEO_A=()
  SKOPEO_I=()
  # 注意：这里必须写成 if，不能写 `[[ ... ]] && ...`。
  # 那种写法在条件为假时会让函数返回 1，配合 set -e 会把整个脚本静默杀掉。
  if [[ -n "$SKOPEO_AUTHFILE" ]]; then
    SKOPEO_A+=(--authfile "$SKOPEO_AUTHFILE")
  fi
  # target_* 系列都是查看"目标侧"，所以用目标的 TLS 设置
  if [[ "$DEST_TLS_VERIFY" == "false" ]]; then
    SKOPEO_I+=(--tls-verify=false)
  fi
}

# 按当前 SKOPEO_PLAT 组装全局参数
skopeo_args_g() {
  SKOPEO_G=()
  if [[ -n "$SKOPEO_TMPDIR" ]]; then
    SKOPEO_G+=(--tmpdir "$SKOPEO_TMPDIR")
  fi
  if [[ -n "$SKOPEO_PLAT" ]]; then
    local p="${SKOPEO_PLAT%%,*}"
    SKOPEO_G+=(--override-os "${p%%/*}" --override-arch "${p##*/}")
  fi
}

skopeo_inspect() {
  skopeo_args_g
  "$SKOPEO_BIN" ${SKOPEO_G[@]+"${SKOPEO_G[@]}"} inspect ${SKOPEO_A[@]+"${SKOPEO_A[@]}"} ${SKOPEO_I[@]+"${SKOPEO_I[@]}"} "$@"
}

skopeo_copy() {
  skopeo_args_g
  "$SKOPEO_BIN" ${SKOPEO_G[@]+"${SKOPEO_G[@]}"} copy ${SKOPEO_A[@]+"${SKOPEO_A[@]}"} "$@"
}

have_skopeo() { have "$SKOPEO_BIN"; }

# 目标镜像存在吗？优先用当前模式自己的工具，避免平白依赖 docker
target_exists() {
  local ref="$1"
  if [[ "$MODE" == "skopeo" ]] && have_skopeo; then
    if skopeo_inspect --raw "docker://$ref" >/dev/null 2>&1; then return 0; else return 1; fi
  fi
  if have docker && docker buildx version >/dev/null 2>&1; then
    if docker buildx imagetools inspect "$ref" >/dev/null 2>&1; then return 0; else return 1; fi
  fi
  if have_skopeo; then
    if skopeo_inspect --raw "docker://$ref" >/dev/null 2>&1; then return 0; else return 1; fi
  fi
  if docker manifest inspect "$ref" >/dev/null 2>&1; then return 0; else return 1; fi
}

target_digest() {
  local ref="$1" d=""
  if [[ "$MODE" != "skopeo" ]] && have docker && docker buildx version >/dev/null 2>&1; then
    d="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$ref" 2>/dev/null || true)"
  elif have_skopeo; then
    d="$(skopeo_inspect --format '{{.Digest}}' "docker://$ref" 2>/dev/null || true)"
  elif have docker; then
    d="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$ref" 2>/dev/null || true)"
  fi
  printf '%s' "$d"
}

# 目标里有 want（如 linux/arm64，或只写 arm64）这个平台吗
#
# 思路：让 skopeo 自己"按这个平台去选"——选得到就说明有：
#   * 多架构 index：里面没有该平台时，skopeo 直接报错
#   * 单架构镜像：选中后报出来的就是它真实的架构，对不上就是没有
# 再用 manifest 原文兜一层（防 skopeo 版本间行为差异）。
target_has_arch() {
  local ref="$1" want="${2:-$REQUIRE_ARCH}"
  local want_arch="$want" got="" raw="" out="" saved="$SKOPEO_PLAT"

  if [[ "$want" != */* ]]; then want="linux/$want"; fi    # 只写 arm64 时补上 os
  want_arch="${want##*/}"
  local want_os="${want%%/*}"

  if have_skopeo && { [[ "$MODE" == "skopeo" ]] || ! have docker; }; then
    SKOPEO_PLAT="$want"        # 让 skopeo_args_g 生成 --override-os / --override-arch
    got="$(skopeo_inspect --format '{{.Architecture}}' "docker://$ref" 2>/dev/null || true)"
    SKOPEO_PLAT="$saved"
    if [[ "$got" == "$want_arch" ]]; then return 0; fi

    raw="$(skopeo_inspect --raw "docker://$ref" 2>/dev/null || true)"
    if grep -q "\"architecture\"[[:space:]]*:[[:space:]]*\"$want_arch\"" <<< "$raw"; then
      return 0
    fi
    return 1
  fi

  out="$(docker buildx imagetools inspect "$ref" 2>&1 || true)"
  [[ -n "$out" ]] || out="$(docker manifest inspect "$ref" 2>&1 || true)"
  if grep -q -- "$want_os/$want_arch" <<< "$out"; then return 0; fi
  grep -q -- "$want_arch" <<< "$out"
}

# ---------------------------------------------------------------------------
# 三种搬运方式
# ---------------------------------------------------------------------------
do_imagetools() {
  # 整份 index 复制（含全部平台）。imagetools 不支持平台过滤。
  docker buildx imagetools create --tag "$2" "$1"
}

do_skopeo() {
  local src="$1" dst="$2"
  # 注意：这里不要写 `copy` —— skopeo_copy 已经拼了子命令，重复会变成
  # `skopeo copy copy ...`，skopeo 会把 "copy" 当成源镜像名而报 transport 错误。
  local -a cargs=(--retry-times "$SKOPEO_RETRY_TIMES")
  if [[ -n "$SRC_CREDS" ]];  then cargs+=(--src-creds "$SRC_CREDS"); fi
  if [[ -n "$DEST_CREDS" ]]; then cargs+=(--dest-creds "$DEST_CREDS"); fi
  if [[ "$SRC_TLS_VERIFY" == "false" ]];  then cargs+=(--src-tls-verify=false); fi
  if [[ "$DEST_TLS_VERIFY" == "false" ]]; then cargs+=(--dest-tls-verify=false); fi
  if [[ -n "$SKOPEO_PLAT" ]]; then
    # 只留一个平台：--override-arch 与 --all 互斥，二选一（已在全局参数里）
    :
  else
    # 完整保留多架构 index
    cargs+=(--all)
  fi
  skopeo_copy "${cargs[@]}" "docker://$src" "docker://$dst"
}

do_pull() {
  local src="$1" dst="$2"
  local -a args=(pull)
  if [[ -n "$SKOPEO_PLAT" ]]; then
    if [[ "$SKOPEO_PLAT" == *,* ]]; then
      die "pull 模式一次只支持一个平台；多平台请用 SYNC_MODE=skopeo"
    fi
    args+=(--platform "$SKOPEO_PLAT")
  fi
  docker "${args[@]}" "$src"
  docker tag "$src" "$dst"
  docker push "$dst"
}

# 带前缀地实时透传子进程输出，并返回子进程退出码
run_logged() {
  local label="$1"; shift
  set +e
  "$@" 2>&1 | sed "s/^/  [$label] /"
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

RESULT_FILE=""
# 字段分隔符同样用 \x1f 而不是 \t：\t 是 IFS 空白字符，会把空字段折叠掉
# （digest 取不到时，note 会串到 digest 列上）
emit() {
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$RESULT_FILE"
}

# ---------------------------------------------------------------------------
# 搬运单个镜像（永远返回 0，成败记在结果文件里，由汇总决定退出码）
# ---------------------------------------------------------------------------
sync_one() {
  local idx="$1" src="$2" dst="$3" plat="${4:-}" arch="${5:-}" mir="${6:-}"
  local pull_src rc=0 note="" digest=""

  # 逐行选项优先，其次全局默认
  SKOPEO_PLAT="${plat:-$PLATFORMS}"
  arch="${arch:-$REQUIRE_ARCH}"
  pull_src="$(apply_mirror "$src" "$mir")"

  printf '\n%s==> [%s/%s] %s%s\n' "$C_CYAN" "$idx" "$TOTAL" "$src" "$C_OFF"
  printf '    目标：%s\n' "$dst"
  if [[ "$pull_src" != "$src" ]]; then printf '    取源走镜像站：%s\n' "$pull_src"; fi
  if [[ -n "$SKOPEO_PLAT" ]]; then printf '    平台限定：%s\n' "$SKOPEO_PLAT"; fi

  if [[ -n "$DRY_RUN" ]]; then
    emit "$idx" "DRY" "$src" "$dst" "-" "只演示，未执行"
    return 0
  fi

  if [[ -z "$FORCE" ]] && target_exists "$dst"; then
    printf '    tag 已存在，跳过（FORCE=1 可强制重推）\n'
    emit "$idx" "SKIP" "$src" "$dst" "$(target_digest "$dst")" "tag 已存在"
    return 0
  fi

  case "$MODE" in
    skopeo)     run_logged "$idx" do_skopeo     "$pull_src" "$dst" || rc=$? ;;
    imagetools) run_logged "$idx" do_imagetools "$pull_src" "$dst" || rc=$? ;;
    pull)       run_logged "$idx" do_pull       "$pull_src" "$dst" || rc=$? ;;
  esac

  if (( rc != 0 )); then
    emit "$idx" "FAIL" "$src" "$dst" "-" "搬运失败（退出码 $rc）"
    return 0
  fi

  if [[ -n "$arch" ]]; then
    if ! target_has_arch "$dst" "$arch"; then
      warn "$dst 推上去了，但里面没有 $arch"
      emit "$idx" "FAIL" "$src" "$dst" "-" "目标里没有 $arch 平台"
      return 0
    fi
    note="含 $arch"
  fi

  digest="$(target_digest "$dst")"
  printf '    完成，digest=%s\n' "${digest:-<未取到>}"
  emit "$idx" "OK" "$src" "$dst" "${digest:--}" "$note"
  return 0
}

run_all() {
  local item src dst plat arch mir idx=0 p
  local -a pids=()
  for item in "${ITEMS[@]}"; do
    IFS="$SEP" read -r src dst plat arch mir <<< "$item"
    idx=$((idx + 1))
    ( sync_one "$idx" "$src" "$dst" "$plat" "$arch" "$mir" ) &
    pids+=("$!")
    if (( ${#pids[@]} >= JOBS )); then
      for p in "${pids[@]}"; do wait "$p" || true; done
      pids=()
    fi
  done
  if (( ${#pids[@]} > 0 )); then
    for p in "${pids[@]}"; do wait "$p" || true; done
  fi
}

# ---------------------------------------------------------------------------
# 清单产物：inventory.json / INVENTORY.md / counts.env
# 给 workflow 发布 Release 用（Actions 页面之外，Releases 页面也能一眼看到"都有什么"）
# INVENTORY_DIR 为空则不产出 —— 本地跑默认不产出，免得污染工作区
# ---------------------------------------------------------------------------
json_esc() { printf '%s' "$1" | tr -d '\\"'; }

write_inventory() {
  local dir="${INVENTORY_DIR:-}"
  if [[ -z "$dir" ]]; then return 0; fi
  if [[ -n "$DRY_RUN" ]]; then return 0; fi

  local ts run_url idx st src dst digest note
  local ok=0 skip=0 fail=0 dry=0 total=0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run_url=""
  if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
    run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  fi

  while IFS="$SEP" read -r idx st src dst digest note; do
    total=$((total + 1))
    case "$st" in
      OK)   ok=$((ok + 1)) ;;
      SKIP) skip=$((skip + 1)) ;;
      DRY)  dry=$((dry + 1)) ;;
      *)    fail=$((fail + 1)) ;;
    esac
  done < <(sort -n "$RESULT_FILE")

  mkdir -p "$dir"

  # 给 workflow 直接 source 的计数
  {
    printf 'OK=%s\n' "$ok"
    printf 'SKIP=%s\n' "$skip"
    printf 'FAIL=%s\n' "$fail"
    printf 'DRY=%s\n' "$dry"
    printf 'TOTAL=%s\n' "$total"
  } > "$dir/counts.env"

  # 机器可读（第二步的工具/脚本可以直接读它来知道有哪些镜像）
  {
    printf '{\n'
    printf '  "generated_at": "%s",\n' "$ts"
    printf '  "target_registry": "%s",\n' "$(json_esc "$TARGET_REGISTRY")"
    printf '  "target_namespace": "%s",\n' "$(json_esc "$TARGET_NAMESPACE")"
    printf '  "mode": "%s",\n' "$MODE"
    if [[ -n "$run_url" ]]; then printf '  "run_url": "%s",\n' "$run_url"; fi
    printf '  "counts": { "ok": %s, "skip": %s, "fail": %s, "total": %s },\n' "$ok" "$skip" "$fail" "$total"
    printf '  "images": [\n'
    local first=1
    while IFS="$SEP" read -r idx st src dst digest note; do
      if (( first )); then first=0; else printf ',\n'; fi
      printf '    { "source": "%s", "target": "%s", "digest": "%s", "status": "%s", "note": "%s" }' \
        "$(json_esc "$src")" "$(json_esc "$dst")" "$(json_esc "$digest")" "$st" "$(json_esc "$note")"
    done < <(sort -n "$RESULT_FILE")
    printf '\n  ]\n}\n'
  } > "$dir/inventory.json"

  # 人看
  {
    printf '# 镜像清单\n\n'
    printf '> 每次搬运成功后自动更新，请勿手工编辑。\n\n'
    printf -- '- 最后更新：%s\n' "$ts"
    printf -- '- 目标 registry：`%s/%s`\n' "$TARGET_REGISTRY" "$TARGET_NAMESPACE"
    printf -- '- 搬运方式：`%s`\n' "$MODE"
    if [[ -n "$run_url" ]]; then printf -- '- 本次运行：%s\n' "$run_url"; fi
    printf -- '- 统计：搬到 **%s** 个 / 目标已有 **%s** 个 / 失败 **%s** 个（共 %s）\n\n' "$ok" "$skip" "$fail" "$total"
    printf '| 源镜像 | 目标镜像 | digest | 状态 |\n'
    printf '|---|---|---|---|\n'
    while IFS="$SEP" read -r idx st src dst digest note; do
      local mark="$st"
      case "$st" in
        OK)   mark='✅ 已搬' ;;
        SKIP) mark='⏭️ 已存在' ;;
        FAIL) mark='❌ 失败' ;;
      esac
      printf '| `%s` | `%s` | `%s` | %s |\n' "$src" "$dst" "${digest:--}" "$mark"
    done < <(sort -n "$RESULT_FILE")
    printf '\n取件（包若是 private 先登录）：\n\n'
    printf '```bash\n'
    printf 'docker login %s -u <你的用户名>\n' "$TARGET_REGISTRY"
    printf 'docker pull <上面的目标镜像>\n'
    printf '```\n'
  } > "$dir/INVENTORY.md"

  printf '  清单已产出：%s（inventory.json / INVENTORY.md / counts.env）\n' "$dir"
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
report() {
  local ok=0 skip=0 fail=0 dry=0 idx st src dst digest note

  printf '\n%s================ 搬运结果 ================%s\n' "$C_CYAN" "$C_OFF"
  printf '%-3s %-5s %-56s %s\n' "#" "状态" "源镜像" "目标镜像"
  while IFS="$SEP" read -r idx st src dst digest note; do
    printf '%-3s %-5s %-56s %s\n' "$idx" "$st" "$src" "$dst"
    if [[ -n "$digest" && "$digest" != "-" ]]; then printf '%*sdigest %s\n' 9 "" "$digest"; fi
    if [[ -n "$note" ]]; then printf '%*s%s\n' 9 "" "$note"; fi
    case "$st" in
      OK)   ok=$((ok + 1)) ;;
      SKIP) skip=$((skip + 1)) ;;
      DRY)  dry=$((dry + 1)) ;;
      *)    fail=$((fail + 1)) ;;
    esac
  done < <(sort -n "$RESULT_FILE")
  printf '%s==========================================%s\n' "$C_CYAN" "$C_OFF"
  printf '成功 %s / 跳过 %s / 演示 %s / 失败 %s（共 %s）\n' "$ok" "$skip" "$dry" "$fail" "$TOTAL"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## 镜像搬运结果"
      echo
      echo "目标 registry：\`$TARGET_REGISTRY/$TARGET_NAMESPACE\`　方式：\`$MODE\`"
      echo
      echo "| # | 状态 | 源镜像 | 目标镜像 | digest / 说明 |"
      echo "|---|---|---|---|---|"
      while IFS="$SEP" read -r idx st src dst digest note; do
        if [[ "$digest" == "-" ]]; then digest=""; fi
        echo "| $idx | $st | \`$src\` | \`$dst\` | ${digest}${note:+ $note} |"
      done < <(sort -n "$RESULT_FILE")
      echo
      echo "成功 $ok / 跳过 $skip / 演示 $dry / 失败 $fail（共 $TOTAL）"
      echo
      echo "> 取件：在自己机器上 \`docker pull <目标镜像>\`（该平台用 \`--platform\` 指定）"
      echo "> 目标包若是 private，取件方需要凭据；要让匿名可拉请在 registry 侧改成 public。"
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  write_inventory

  if (( fail > 0 )) && [[ -z "$ALLOW_FAIL" ]]; then
    printf '\n%s有 %s 个镜像失败，退出码 1（设 ALLOW_FAIL=1 可忽略失败）%s\n' "$C_RED" "$fail" "$C_OFF" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --force)   FORCE=1 ;;
      --insecure-src)  SRC_TLS_VERIFY=false ;;
      --insecure-dest) DEST_TLS_VERIFY=false ;;
      --only)    shift; ONLY="${1:-}" ;;
      --only=*)  ONLY="${1#*=}" ;;
      --mode)    shift; SYNC_MODE="${1:-}" ;;
      --mode=*)  SYNC_MODE="${1#*=}" ;;
      -h|--help) usage; exit 0 ;;
      *) die "不认识的参数：$1（用 --help 看用法）" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  [[ -n "$TARGET_NAMESPACE" ]] || die "TARGET_NAMESPACE 没设置（例如 TARGET_NAMESPACE=<你的GitHub用户名>）"
  resolve_mode
  load_items
  TOTAL=${#ITEMS[@]}

  RESULT_FILE="$(mktemp)"
  trap 'rm -f "$RESULT_FILE"' EXIT

  log "配置"
  printf '  目标 registry : %s/%s\n' "$TARGET_REGISTRY" "$TARGET_NAMESPACE"
  printf '  搬运方式      : %s%s\n' "$MODE" "$([[ -n "$DRY_RUN" ]] && echo '（dry-run）' || true)"
  printf '  清单文件      : %s（%s 个镜像）\n' "$IMAGES_FILE" "$TOTAL"
  printf '  镜像站替换表  : %s%s\n' "$MIRRORS_FILE" "$([[ -f "$MIRRORS_FILE" ]] && echo '' || echo '（不存在，忽略）')"
  printf '  并发          : %s\n' "$JOBS"
  if [[ -n "$FORCE" ]]; then printf '  FORCE         : 已存在也重推\n'; fi
  if [[ -n "$PLATFORMS" ]]; then printf '  默认平台限定  : %s\n' "$PLATFORMS"; fi
  if [[ -n "$REQUIRE_ARCH" ]]; then printf '  默认校验架构  : %s\n' "$REQUIRE_ARCH"; fi
  if [[ "$MODE" == "imagetools" && -n "$PLATFORMS" ]]; then
    warn "imagetools 会整份复制（含全部平台），platform= 不生效；只想留单一平台请用 SYNC_MODE=skopeo"
  fi

  run_all
  report
}

# 作为库被 source 时只加载函数，不执行
if [[ -n "${MIRROR_LIB_ONLY:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
