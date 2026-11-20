# image-mirror —— 自建镜像搬运仓库

上游镜像**拉不动、太慢、被墙、要认证**的时候，别再跟那条链路死磕：
把镜像写进 `images.txt`，`git push`，GitHub Actions 替你把它搬到**你自己的 registry**，
然后你从自己这边取件。

```text
第一步（几乎不用你管）:
images.txt ──git push──> GitHub Actions ──skopeo/imagetools 直拷──> ghcr.io/<你>/xxx
                          (境外 runner 直连上游，不落磁盘)                │
                                                                          │
第二步（取件，二选一）:                                                     │
  A. 目标机器能连你的 registry ────── docker pull ───────────────────────┘
  B. 目标机器连不上，但你能 SSH 过去:
       本机 skopeo.exe ──中转──> [ssh -L 隧道] ──> 目标机器旁的 registry ──> docker pull(本机环回)
```

不绑定任何项目：任何"拉不到的镜像"都能往里加一行。

> **第一步和第二步是两件事。** 第一步在 GitHub 的境外 runner 上跑（只要求 runner 能出网），
> 第二步在你自己的机器上跑。别指望一条链路把两边都解决了 —— 详见 §12「两段式拓扑」。

---

## 1. 为什么这样能解决问题

| 典型症状 | 本仓库怎么解 |
|---|---|
| `docker pull` 卡在大层不动，重试从头再来 | 搬运发生在 GitHub runner 上（直连上游、带宽好）；本地只从自己的 registry 取 |
| `docker pull` 没有空闲超时，无限挂住 | `scripts/pull.sh` 有 `PULL_TIMEOUT` + 重试；另一种取件通道支持**断点续传** |
| 源 registry 需要认证 / 有速率限制 | 凭据放 GitHub Secrets，runner 侧带上 |
| 镜像多架构，本地拉成了 amd64 | 默认**完整保留多架构 index**，取件时按机器架构各取各的；也能逐行只搬单一平台 |
| 上游 tag 被墙但 GitHub 通 | 目标可换成任意 registry；取件还能走 registry 镜像前缀 |
| 想搬的镜像越来越多、手工 `docker save` 传文件太笨 | 往清单加行 + `git push`，别的都不用管 |

---

## 2. 30 秒上手

**① 建仓库并推上去**

```bash
cd image-mirror
git init && git add -A && git commit -m "init image mirror"
git remote add origin git@github.com:<你>/image-mirror.git
git push -u origin main
```

**② 改 `images.txt`，加你要的镜像**（每行一个）

```text
docker.io/library/nginx:1.27-alpine
quay.io/ascend/vllm-ascend:v0.32.0rc1-a3-openeuler   platform=linux/arm64 require_arch=arm64
```

**③ `git push`** —— Actions 自动开跑。完成后：

```
ghcr.io/<你的用户名>/docker-io-library-nginx:1.27-alpine
ghcr.io/<你的用户名>/quay-io-ascend-vllm-ascend:v0.32.0rc1-a3-openeuler
```

**④ 在目标机器上取件**

```bash
export TARGET_NAMESPACE=<你的用户名>
bash scripts/pull.sh                    # 取清单里的全部
```

> 目标包默认是 **private**。要让别的机器免登录拉，去
> `https://github.com/users/<你>/packages` 把包改成 public（或在取件机上 `docker login ghcr.io`）。

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

第二个非选项词会被当成**目标镜像名**（想改名、想推去别的 registry 时用）。

```text
# 只搬 arm64 并校验
quay.io/ascend/vllm-ascend:v0.32.0rc1-a3-openeuler   platform=linux/arm64 require_arch=arm64

# 改目标名
docker.io/library/redis:7.4-alpine   ghcr.io/me/redis:7.4-alpine

# 单独换源
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

> 只按 tag 搬，不支持 digest（`@sha256:...`）。

---

## 4. 触发方式

| 方式 | 说明 |
|---|---|
| `git push` | 改了 `images.txt` / `mirrors.env` / 同步脚本，自动开跑 |
| Actions 页面手点 | 可临时搬不在清单里的镜像（`images` 输入框）、只搬指定平台、强制重推、只预览 |
| 定时（每周一） | 兜底重扫一遍，防漏 |

推别的东西（改 README 等）不会触发，节省 Actions 额度。

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
| `ALLOW_FAIL` | 空 | 非空 = 有失败也返回 0（定时任务友好） |

三种搬运方式（**都不落本地磁盘**）：

| 方式 | 依赖 | 特点 |
|---|---|---|
| `skopeo` | `skopeo` | registry→registry 直拷，自带 blob 级重试，**不需要 docker daemon**；支持平台过滤 |
| `imagetools` | `docker buildx` | 纯客户端直拷，runner 上最快；**不支持平台过滤**（整份 index 复制） |
| `pull` | `docker` + daemon | 最笨最兼容；会落本地磁盘；只支持单平台 |

`auto` 按 `skopeo → imagetools → pull` 挑第一个可用的。

---

## 6. 在 Windows 上搬运（`skopeo.exe`，零磁盘占用）

不需要 Git Bash，也不需要 docker：

```powershell
# 先预览会搬什么（不发任何网络请求）
.\scripts\mirror.ps1 -TargetNamespace <你的用户名> -DryRun

# 真搬：用 PAT 给凭据，连 docker login 都不用
$env:GHCR_USER  = '<你的用户名>'
$env:GHCR_TOKEN = 'ghp_xxx'          # classic PAT，勾 write:packages
.\scripts\mirror.ps1 -TargetNamespace <你的用户名>

# 只搬单一平台 + 校验
.\scripts\mirror.ps1 -TargetNamespace <你的用户名> -Platforms linux/arm64
```

- `-Skopeo D:\bin\skopeo.exe` 指定 skopeo 路径（或设 `SKOPEO_BIN`）
- `-Force` / `-Only` / `-DryRun` / `-AllowFail`，清单选项（`platform=` 等）同样支持
- 结束后会在当前目录生成 `pull-list.txt`，里面是可直接拷到目标机器执行的 `docker pull` 命令

Linux / macOS / 任意服务器上则用 `bash scripts/mirror.sh`，参数同理。

---

## 7. 取件

### 7.1 常规：从自己的 registry 拉

```bash
export TARGET_NAMESPACE=<你的用户名>
bash scripts/pull.sh                              # 清单全部
bash scripts/pull.sh --platform linux/arm64 --require-arch arm64
bash scripts/pull.sh --tag-back docker.io/library/nginx:1.27-alpine
```

| 选项 | 作用 |
|---|---|
| `--platform P` | 指定平台（不写 = 本机架构） |
| `--require-arch A` | 取回后校验架构，不符就报失败（**防止把 amd64 镜像传到 arm64 机器上**） |
| `--tag-back` | 取回后 `docker tag` 回源镜像名（compose / 启动脚本里写死上游名字时用） |
| `--dry-run` | 只打印命令 |

其他相关环境变量：`MIRROR_PREFIX`（目标 registry 的镜像站前缀，如 `ghcr.nju.edu.cn`）、
`PULL_TIMEOUT`（默认 1800 秒，防"无限挂住"）、`PULL_RETRIES`（默认 3，已下完的层不会重下）。

### 7.2 弱网专用：Release 分片 + 断点续传

单个大 blob 的长连接会被掐断，而 `docker pull` / `skopeo --retry-times` 都是**整 blob 级重试**，
不做 HTTP Range 续传。这种情况下改用 Release 资产：

1. 手动跑一次 `export-image-to-release` 工作流（Actions 页面），填要导出的镜像
   → 它把镜像 `docker save | zstd | split` 成分片传进 Release（单资产 < 2 GiB）
2. 在目标机器上：

```bash
bash scripts/fetch-release.sh <owner/repo> <release-tag> --require-arch arm64
# 走镜像前缀：
bash scripts/fetch-release.sh <owner/repo> <release-tag> \
  --base-url https://<你的镜像>/https://github.com/<owner/repo>/releases/download/<release-tag>
```

`curl -C -` 断点续传 + 逐片 sha256 校验，断了接着下，不用从头再来。

> ⚠️ 这条通道需要把镜像 pull 到 runner 本地再导出，磁盘需求约为镜像的 2 倍。
> 工作流里带了清盘步骤；镜像特别大时建议先只导一个。

---

## 8. 私有镜像与认证

| 场景 | 做法 |
|---|---|
| 源需要登录（私有仓库） | 仓库 Secrets 配 `SRC_CREDS` = `user:password` |
| 目标不是 GHCR | Variables 配 `TARGET_REGISTRY` / `TARGET_NAMESPACE`，并加对应登录步骤；`DEST_CREDS` = `user:token` |
| Docker Hub 匿名限流 | Secrets 配 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` |
| 本地 Windows 推 GHCR | `GHCR_USER` + `GHCR_TOKEN`（classic PAT，勾 `write:packages`） |

---

## 9. 踩过的坑（写在这里省得再踩）

- **CRLF**：Windows 上 clone 若变成 CRLF，runner 上会报 `$'\r': command not found`。
  仓库里已有 `.gitattributes` 强制 LF，别删。
- **GHCR 包默认 private**：跨机器取件会 401。改 public，或在取件机 `docker login ghcr.io`。
- **`skopeo` 参数分两层**：`--tmpdir` / `--override-arch` / `--override-os` 是**全局**（放子命令前），
  `--authfile` / `--src-creds` / `--dest-creds` / `--retry-times` / `--all` 是**子命令级**（放 `copy` 后）。
  放错位置会报 `unknown flag`。（1.8 与 1.24 的划分一致）
- **`imagetools` 不能过滤平台**：要单平台就用 `SYNC_MODE=skopeo`。
- **runner 磁盘**：默认 ubuntu runner 约 14 GB 空闲，9 GiB 的镜像别指望用 `pull` 模式搬。
- **`platform=` 与 `--all` 互斥**：写平台限定就只搬那一个平台（流量减半，但另一架构的机器就取不到了）。

---

## 10. 用例：910C（aarch64）部署取件

这台机器到 `quay.io` / DaoCloud 的链路会在 4.2 GB 的大层上僵死，改走本仓库：

```text
# 1) 清单里加（或确认已有）这一行
quay.io/ascend/vllm-ascend:v0.32.0rc1-a3-openeuler

# 2) push 之后，在 910c 上取件（arm64 校验 + 打回官方名，启动脚本不用改）
export TARGET_NAMESPACE=<你的用户名>
bash scripts/pull.sh --platform linux/arm64 --require-arch arm64 --tag-back \
     quay.io/ascend/vllm-ascend:v0.32.0rc1-a3-openeuler

# 3) 还是取不动就走 Release 断点续传通道
bash scripts/fetch-release.sh <owner/repo> <release-tag> --require-arch arm64
```

`--tag-back` 会把它重新 tag 成 `quay.io/ascend/vllm-ascend:...`，
所以 `910c-serve.sh` / `910c-preflight.sh` 一行都不用改。

---

## 11. 目录结构

```text
.
├── images.txt                            # 镜像清单（改它 + git push）
├── mirrors.env                           # 源镜像站替换表（host=前缀）
├── .gitattributes                        # 强制 LF，别删
├── .github/workflows/
│   ├── sync.yml                          # push 触发搬运
│   └── export-release.yml                # 可选：导出为 Release 分片（断点续传取件）
└── scripts/
    ├── mirror.sh                         # 搬运核心（Actions / Linux 本地共用）
    ├── mirror.ps1                        # Windows 本地版（skopeo.exe，零磁盘）；-Relay 做第二步中转
    ├── tunnel.ps1                        # Windows 开 SSH 端口转发（第二步用）
    ├── pull.sh                           # 从自己的 registry 取件
    └── fetch-release.sh                  # Release 分片断点续传取件
```

`mirror.sh` 的命名推导规则与 `mirror.ps1` 的 `Get-TargetRef` **必须保持一致** —— 改一处要同步改另一处。

---

## 12. 两段式拓扑：第二步到底怎么落地

### 12.1 先把两段分清

| | 在哪跑 | 需要什么网络 | 落不落本地磁盘 |
|---|---|---|---|
| **第一步**：上游 → 你的 registry | GitHub 的境外 runner | runner 能出网即可（源和目标都在境外） | 不落（registry→registry 直拷） |
| **第二步**：你的 registry → 目标侧 | **你自己的机器** | 本机能连你的 registry；能 SSH 到目标机 | 不落（同一套 skopeo 直拷） |

第二步有两个**方向**，别搞混：

- **拉（pull）**：目标机器自己从你的 registry 拉 → `scripts/pull.sh`（拓扑 A）
- **推（relay）**：你的机器把镜像**推**进目标机旁边的一个 registry → `mirror.ps1 -Relay`（拓扑 B）

目标机器能连上你的 registry（或其镜像站）→ 用 A，最省事。
目标机器连不上（910c 就是这种：连 quay.io 会僵死，也够不到 GHCR）→ 用 B。

### 12.2 拓扑 A：目标机器直接拉

见 §7.1，一条命令：

```bash
export TARGET_NAMESPACE=<你的用户名>
bash scripts/pull.sh --platform linux/arm64 --require-arch arm64 --tag-back
```

### 12.3 拓扑 B：本机中转 + SSH 隧道（你的场景）

**前提：910c 侧要有一个 registry。** 没有就先在那台机器上起一个：

```bash
# 在 910c 上执行
docker run -d --name mirror-registry --restart=always \
  -p 127.0.0.1:5000:5000 \
  -v /data/registry:/var/lib/registry \
  registry:2
```

> 只监听 `127.0.0.1` 就够 —— 中转从 SSH 隧道进来，不必对外暴露。
> 如果连 `registry:2` 这个镜像本身都拉不到，把它也加进 `images.txt` 走第一步。

**① 本机开隧道**（新窗口，保持开着）

```powershell
.\scripts\tunnel.ps1 -SshHost root@36.141.20.212 -Port 1122
#   localhost:5000  -->  910c 的 127.0.0.1:5000
```

**② 本机中转**（再开一个窗口）

```powershell
$env:GHCR_USER='<你的用户名>'; $env:GHCR_TOKEN='ghp_xxx'   # 你的包若是 private，拉的时候要用
.\scripts\mirror.ps1 -Relay -FromNamespace <你的用户名> `
    -TargetRegistry localhost:5000 -TargetNamespace mirror -InsecureDest
```

- 纯 `skopeo copy`，**本机不落磁盘**
- 目标已存在的 blob 会自动跳过，所以断了重跑是**增量**的（重试粒度 = 单个 blob，而不是整个镜像）
- 中转时 GHCR 是"源"，凭据会自动走 `--src-creds`（你不用手动区分方向）

**③ 在 910c 上取回，并打回官方名**

先让那台机器的 docker 认这个 http registry（一次性）：

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{ "insecure-registries": ["127.0.0.1:5000"] }
EOF
sudo systemctl restart docker
```

然后（`pull.sh` 顺带做 arm64 校验 + 打回原名，启动脚本一行都不用改）：

```bash
TARGET_REGISTRY=127.0.0.1:5000 TARGET_NAMESPACE=mirror \
  bash scripts/pull.sh --platform linux/arm64 --require-arch arm64 --tag-back \
       quay.io/ascend/vllm-ascend:v0.32.0rc1-a3-openeuler
```

### 12.4 为什么不走"不用 registry，直接 `docker save | ssh | docker load`"

因为那条路要求**本机有 docker**（你 Windows 上没有），而且 `docker save` 流式过隧道**没有任何重试**：
一旦断掉就得整包重来 —— 正是你这个 9 GiB 镜像最怕的场景。
真要走无 registry 的通道，用 `fetch-release.sh`（分片 + `curl -C -` 断点续传）更稳。

### 12.5 第二步真正会绊到你的四个点

1. **docker 拉 http registry**：必须配 `insecure-registries`，否则报
   `http: server gave HTTP response to HTTPS client`。
2. **skopeo 推 http registry**：必须 `--dest-tls-verify=false`（本仓库是 `-InsecureDest` /
   `DEST_TLS_VERIFY=false`）。
3. **隧道不带认证**：`ssh -L` 只是把端口接了进来，谁连上你本机的 5000 都能用。
   别在公共网络里长期开着，用完 Ctrl+C。
4. **凭据方向**：中转时 GHCR 是**源**、本地 registry 是**目标**。
   `mirror.sh` 用 `SRC_CREDS` / `DEST_CREDS` 区分；`mirror.ps1` 在 `-Relay` 下会自动把
   `GHCR_USER/GHCR_TOKEN` 归到 `--src-creds`，别手动塞到 `-DestCreds`。
