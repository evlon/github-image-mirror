# image-mirror —— 用 GitHub Actions 给拉不到的镜像做一份自己的副本

上游镜像**拉不动、太慢、被墙、要认证**的时候，别再跟那条链路死磕：
把镜像写进 `images.txt`，`git push`，GitHub Actions 把它搬进**你自己的 registry**。

```text
images.txt ──git push──> GitHub Actions（境外 runner，直连上游）
                              │  skopeo copy / buildx imagetools（registry→registry 直拷，不落磁盘）
                              ▼
                        ghcr.io/<你>/xxx        ← 你随时可以从这里取
```

本仓库**只负责这一段**：上游 → 你的 registry。
"怎么把这个镜像弄到某台具体的机器上"（比如 910C）是另一件事，不在本仓库里（见 §12）。

不绑定任何项目：任何"拉不到的镜像"都能往里加一行。

---

## 1. 它解决什么

| 典型症状 | 这里怎么解 |
|---|---|
| `docker pull` 卡在大层不动，重试从头再来 | 搬运在 GitHub 的 runner 上完成（直连上游、带宽好），你只管从自己的 registry 取 |
| `docker pull` 没有空闲超时，无限挂住 | 搬运过程不需要你盯着；runner 有超时重试，失败会在 Actions 里红出来并给出摘要 |
| 源 registry 需要认证 / 有速率限制 | 凭据放 GitHub Secrets，由 runner 带上 |
| 镜像多架构，本地拉成了 amd64 | 默认**完整保留多架构 index**；也能在清单里逐行只搬单一平台 |
| 上游 tag 变动、要重新搬 | `FORCE=1` 或在 Actions 页面手点；定时任务每周兜底重扫 |
| 想搬的镜像越来越多、手工 `docker save` 传文件太笨 | 往清单加一行 + `git push`，别的不用管 |

---

## 2. 快速开始

**① 建仓库并推上去**

```bash
cd image-mirror
git remote add origin git@github.com:<你>/image-mirror.git
git push -u origin main
```

**② 改 `images.txt`，加你要的镜像**（每行一个）

```text
docker.io/library/nginx:1.27-alpine
quay.io/ascend/vllm-ascend:v0.32.0rc1-a3-openeuler   platform=linux/arm64 require_arch=arm64
```

**③ `git push`** —— Actions 自动开跑（也可以去 Actions 页面点 `sync-images` 手跑）。
跑完后你会得到：

```text
ghcr.io/<你的用户名>/docker-io-library-nginx:1.27-alpine
ghcr.io/<你的用户名>/quay-io-ascend-vllm-ascend:v0.32.0rc1-a3-openeuler
```

**④ 用结果**（就是普通的 docker pull，没有额外工具）

```bash
docker pull ghcr.io/<你的用户名>/docker-io-library-nginx:1.27-alpine
docker pull --platform linux/arm64 ghcr.io/<你的用户名>/quay-io-ascend-vllm-ascend:v0.32.0rc1-a3-openeuler
```

> GHCR 的包**默认是 private**。要让别的机器免登录拉，去
> `https://github.com/users/<你>/packages` 把包改成 public；或者在那台机器上 `docker login ghcr.io`。

---

## 3. 清单格式

```text
<源镜像> [目标镜像] [选项...]
```

| 选项 | 作用 |
|---|---|
| `platform=linux/arm64` | 只搬这个平台（多平台用逗号）。不写 = 完整保留多架构 index |
| `require_arch=arm64` | 搬完校验目标里确实有这个平台，没有就算失败（`linux/arm64` 写法也认） |
| `mirror=<host>` | 这一行单独指定源镜像站，覆盖 `mirrors.env` |

第二个非选项词会被当成**目标镜像名**（想改名、想推到别的 registry 时用）。

```text
# 只搬 arm64 并校验
quay.io/ascend/vllm-ascend:v0.32.0rc1-a3-openeuler   platform=linux/arm64 require_arch=arm64

# 改目标名
docker.io/library/redis:7.4-alpine   ghcr.io/me/redis:7.4-alpine

# 这一行单独换源
docker.io/library/postgres:17   mirror=docker.m.daocloud.io
```

**目标名自动推导规则**（不写第二列时）：

```text
<目标registry>/<目标命名空间>/<源全名去掉 tag，`/` 和 `.` 换成 `-`，转小写>:<tag>
```

| 源 | 目标（命名空间 = `me`） |
|---|---|
| `docker.io/library/nginx:1.27-alpine` | `ghcr.io/me/docker-io-library-nginx:1.27-alpine` |
| `quay.io/ascend/vllm-ascend:v0.1` | `ghcr.io/me/quay-io-ascend-vllm-ascend:v0.1` |
| `ghcr.io/other/app:1.2` | `ghcr.io/me/ghcr-io-other-app:1.2` |
| `nginx`（不写 tag） | `ghcr.io/me/docker-io-library-nginx:latest` |

> 只按 tag 搬，不支持 digest（`@sha256:...`，清单里写了会直接报错中止）。

---

## 4. 触发方式

| 方式 | 说明 |
|---|---|
| `git push` | 改了 `images.txt` / `mirrors.env` / 同步脚本，自动开跑 |
| Actions 页面手点 | 可临时搬不在清单里的镜像（`images` 输入框）、只搬指定平台、强制重推、只预览 |
| 定时（每周一） | 兜底重扫一遍，防漏 |

改 README 之类不触发，省 Actions 额度。

### 4.1 跑完以后：自动更新一份「镜像清单」Release

每次搬运结束（**哪怕部分镜像失败也会更新**，如实反映现状）都会刷新 Releases 页面上一个固定标签的 Release：

```
https://github.com/<你>/<仓库>/releases/tag/images      # 标题：镜像清单（自动维护）
```

里面就是"现在都有什么"：

| 内容 | 说明 |
|---|---|
| Release 正文 | 一张表：源镜像 → 目标镜像 + digest + 状态（✅ 已搬 / ⏭️ 已存在 / ❌ 失败），外加统计和本次运行链接 |
| 附件 `INVENTORY.md` | 同一张表，方便下载/贴给别人 |
| 附件 `inventory.json` | 机器可读（含 `target_registry` / `images[]` / `counts`），**将来第二步的取件工具可以直接读它来决定拉什么** |

几个行为约定：

- 标签固定为 `images`（**滚动更新**，同一个 URL 永远是最新清单，不会把 Releases 页面刷满）
- 本次既没有新搬成功的、也没有已存在的（`OK=SKIP=0`）→ 不更新
- `dry-run` 不更新
- 想要每次搬运都留一份历史快照，就把 `sync.yml` 里那个 `TAG='images'` 改成带时间的标签，例如 `TAG="images-$(date -u +%Y%m%d-%H%M%S)"`

---

## 5. 可调参数

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `TARGET_REGISTRY` | `ghcr.io` | 目标 registry，可换 `docker.io` 等 |
| `TARGET_NAMESPACE` | 仓库属主 | 目标命名空间 |
| `SYNC_MODE` | `auto` | `auto` / `skopeo` / `imagetools` / `pull` |
| `PLATFORMS` | 空 | 全局平台限定（清单逐行 `platform=` 优先） |
| `REQUIRE_ARCH` | 空 | 全局架构校验（清单逐行 `require_arch=` 优先） |
| `FORCE` | 空 | 非空 = 已存在的 tag 也重推 |
| `JOBS` | `4` | 并发批大小 |
| `IMAGES_FILE` / `MIRRORS_FILE` | `images.txt` / `mirrors.env` | 清单与替换表 |
| `SRC_CREDS` / `DEST_CREDS` | 空 | `user:password`，私有源 / 私有目标用 |
| `SKOPEO_BIN` / `SKOPEO_AUTHFILE` / `SKOPEO_TMPDIR` / `SKOPEO_RETRY_TIMES` | `skopeo` / 空 / 空 / `3` | skopeo 细项 |
| `SRC_TLS_VERIFY` / `DEST_TLS_VERIFY` | `true` | 目标是非 https 时置 `false`（命令行 `--insecure-dest`） |
| `ALLOW_FAIL` | 空 | 非空 = 有失败也返回 0（定时任务友好） |

换目标 registry（比如推到 Docker Hub）：

> 仓库 Settings → Secrets and variables → Actions → **Variables** 里设
> `TARGET_REGISTRY` / `TARGET_NAMESPACE`，并在 `sync.yml` 里补一条对应 registry 的登录步骤。

---

## 6. 三种搬运方式（都不落本地磁盘）

| 方式 | 依赖 | 特点 |
|---|---|---|
| `skopeo` | `skopeo` | registry→registry 直拷，自带 blob 级重试，**不需要 docker daemon**；支持平台过滤 |
| `imagetools` | `docker buildx` | 纯客户端直拷，runner 上最快；**不支持平台过滤**（整份 index 复制） |
| `pull` | `docker` + daemon | 最笨最兼容；会落本地磁盘；只支持单平台 |

`auto`（默认）按 `skopeo → imagetools → pull` 挑第一个可用的。

---

## 7. 本地也能跑同一件事

Actions 不趁手时（要调试、要搬私有源、或 runner 连不上某个源），本地跑同一份逻辑。

**Windows**（只要一个 `skopeo.exe`，不需要 docker、不需要 Git Bash、零磁盘占用）：

```powershell
# 先预览会搬什么（不发网络请求）
.\scripts\mirror.ps1 -TargetNamespace <你的用户名> -DryRun

# 真搬：用 PAT 给凭据，连 docker login 都不用
$env:GHCR_USER  = '<你的用户名>'
$env:GHCR_TOKEN = 'ghp_xxx'          # classic PAT，勾 write:packages
.\scripts\mirror.ps1 -TargetNamespace <你的用户名>

# 只搬单一平台 / 指定 skopeo 路径 / 只搬某几个 / 强制重推
.\scripts\mirror.ps1 -TargetNamespace <你> -Platforms linux/arm64
.\scripts\mirror.ps1 -TargetNamespace <你> -Skopeo D:\bin\skopeo.exe
.\scripts\mirror.ps1 -TargetNamespace <你> -Only docker.io/library/nginx:1.27-alpine -Force
```

结束后当前目录会生成 `pull-list.txt`，里面是可直接拷去用的 `docker pull` 命令。

**Linux / macOS**：`bash scripts/mirror.sh`，参数同理（`TARGET_NAMESPACE=... bash scripts/mirror.sh`）。

---

## 8. 认证

| 场景 | 做法 |
|---|---|
| 源需要登录（私有仓库） | 仓库 Secrets 配 `SRC_CREDS` = `user:password` |
| 目标不是 GHCR | Variables 配 `TARGET_REGISTRY` / `TARGET_NAMESPACE`，加对应登录步骤；`DEST_CREDS` = `user:token` |
| Docker Hub 匿名限流 | Secrets 配 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` |
| 本地 Windows 推 GHCR | `GHCR_USER` + `GHCR_TOKEN`（classic PAT，勾 `write:packages`） |

---

## 9. 踩过的坑（都在这份代码里处理掉了）

- **CRLF**：Windows 上 clone 若变成 CRLF，runner 上会报 `$'\r': command not found`。
  `.gitattributes` 已强制 LF，别删。
- **UTF-8 BOM**：Notepad 存出来的清单带 BOM，会让第一行的镜像名变乱码 —— 两个脚本都会先剥掉 BOM。
- **`set -e` + `[[ ]] && cmd` 写在函数最后一行**：条件为假时函数返回 1，整个脚本**静默退出、零输出**。
  代码里一律写成 `if`。（这个 bug 是实测抓出来的，不是理论风险。）
- **`IFS=$'\t'` 分隔空字段会被折叠**：tab 属于 IFS 空白字符，连续两个算一个，
  内部多字段传递改用 `\x1f`。
- **`skopeo` 参数分两层**：`--tmpdir` / `--override-arch` / `--override-os` 是**全局**（放子命令前），
  `--authfile` / `--src-creds` / `--dest-creds` / `--retry-times` / `--all` 是**子命令级**（放 `copy` 后）。
  放错位置会报 `unknown flag`。（1.8 与 1.24 的划分一致）
- **`imagetools` 不能过滤平台**：要单平台就用 `SYNC_MODE=skopeo`。
- **GHCR 包默认 private**：跨机器取会 401。改 public，或在取件机 `docker login ghcr.io`。
- **runner 磁盘**：默认 ubuntu runner 约 14 GB 空闲，9 GiB 的镜像别指望用 `pull` 模式搬。

---

## 10. 目录结构

```text
.
├── images.txt                  # 镜像清单（改它 + git push）
├── mirrors.env                 # 源镜像站替换表（host=前缀）
├── .gitattributes              # 强制 LF，别删
├── .github/workflows/
│   └── sync.yml                # 唯一的工作流：push 触发搬运
└── scripts/
    ├── mirror.sh               # 搬运核心（Actions 与本地共用）
    ├── mirror.ps1              # Windows 本地版（skopeo.exe，零磁盘）
    └── test-arch-gate.sh       # 零网络回归测试：架构门 + 清单产出
```

`mirror.sh` 的命名推导规则与 `mirror.ps1` 的 `Get-TargetRef` **必须保持一致** —— 改一处要同步改另一处。

回归测试随时可跑，不联网、几毫秒（用假 skopeo 喂真实形态的 manifest JSON）：

```bash
bash scripts/test-arch-gate.sh
```

---

## 11. 本仓库不负责的部分

**"怎么把镜像从你的 registry 弄到某台具体机器上"**（例如送到 910C 所在服务器）不在本仓库里。
需要时再单独做，做法取决于目标机器的网络条件（能不能直连 registry、能不能开 SSH 隧道、有没有 registry 落点）。
如果那套工具后面要写进代码库，再单独放进来即可 —— 现在保持仓库只做一件事。
