#Requires -Version 5.1
<#
.SYNOPSIS
    用 skopeo.exe 把 images.txt 里的镜像搬运到自己的 registry（默认 GHCR）。
    用途：上游镜像拉不动 / 太慢 / 被墙 / 要认证时，用能连上的机器代拉。
    registry → registry 直拷，**本地磁盘占用为 0**：不 docker pull、不 docker save、
    不落 tar，也不需要 docker daemon 在跑。

.EXAMPLE
    # 1) 先看会同步什么（不实际推送）
    .\scripts\mirror.ps1 -DryRun

    # 2) 推。最省事的方式：用 GitHub PAT 直接给凭据，连 docker login 都不用
    $env:GHCR_USER  = '你的GitHub用户名'
    $env:GHCR_TOKEN = 'ghp_xxxxxxxx'      # classic PAT，勾 write:packages
    .\scripts\mirror.ps1

    # 3) 只推一个、并强制覆盖已存在的 tag
    .\scripts\mirror.ps1 -Only quay.io/ascend/vllm-ascend:v0.32.0rc1-a3-openeuler -Force

    # 4) 只保留 arm64 一份（给 arm64 服务器用，能省一半流量）
    .\scripts\mirror.ps1 -Platforms linux/arm64

    # 5) 第二步·中转：把你镜像仓库里的东西推到 910c 侧的 registry
    #    （先在另一个窗口开隧道：ssh -N -L 5000:127.0.0.1:5000 user@910c）
    .\scripts\mirror.ps1 -Relay -FromNamespace <你的用户名> `
        -TargetRegistry localhost:5000 -TargetNamespace mirror -InsecureDest

.NOTES
    清单行格式：<源镜像> [目标镜像] [选项...]，选项支持 platform= / require_arch= / mirror=，
    与 scripts/mirror.sh 完全一致。
    命名规则必须与 mirror.sh 的 derive_target 保持一致 —— 两边改一处要同步改另一处。
    在 GitHub Actions 里跑的是 mirror.sh（Linux runner），本脚本是给你本地 Windows 用的。
#>
[CmdletBinding()]
param(
    # 清单与替换表
    [string]   $ImagesFile      = 'images.txt',
    [string]   $MirrorsFile     = 'mirrors.env',

    # 目标仓库
    [string]   $TargetRegistry  = 'ghcr.io',
    [string]   $TargetNamespace = $env:TARGET_NAMESPACE,

    # skopeo.exe 路径（默认从 PATH 找；也可用环境变量 SKOPEO_BIN）
    [string]   $Skopeo          = $(if ($env:SKOPEO_BIN) { $env:SKOPEO_BIN } else { 'skopeo' }),
    [string]   $AuthFile,
    [string]   $SourceCreds     = $env:SRC_CREDS,
    [string]   $DestCreds,
    [int]      $RetryTimes      = 3,

    # 中转模式（第二步：把你镜像仓库里的东西推到别处，可经 SSH 隧道）
    [switch]   $Relay,
    [string]   $FromRegistry  = 'ghcr.io',
    [string]   $FromNamespace,
    [switch]   $InsecureSrc,
    [switch]   $InsecureDest,

    # 行为开关
    [string[]] $Only,
    [string]   $Platforms,
    [string]   $RequireArch,
    [switch]   $Force,
    [switch]   $DryRun,
    [switch]   $AllowFail
)

$ErrorActionPreference = 'Stop'

# 目标名推导用哪一套 registry/namespace（中转模式下换成"你的镜像仓库"那一套）
$script:DeriveRegistry  = $TargetRegistry
$script:DeriveNamespace = $TargetNamespace

$script:Ok = 0; $script:Skip = 0; $script:Fail = 0; $script:Dry = 0
$script:Results = New-Object System.Collections.ArrayList

function Write-Head([string]$msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Warn2([string]$msg) { Write-Host "[warn] $msg" -ForegroundColor Yellow }
function Die([string]$msg) { Write-Host ""; Write-Host "[中止] $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# 引用解析：与 mirror.sh 的 normalize_src / split_ref / derive_target 等价
# ---------------------------------------------------------------------------
function Get-NormalizedSrc([string]$ref) {
    if ($ref -notmatch '/') { return "docker.io/library/$ref" }
    $first = ($ref -split '/')[0]
    if ($first -match '\.' -or $first -match ':' -or $first -eq 'localhost') { return $ref }
    return "docker.io/$ref"
}

function Split-Ref([string]$ref) {
    if ($ref -match '@') {
        $i = $ref.IndexOf('@')
        return @{ Name = $ref.Substring(0, $i); Tag = $ref.Substring($i + 1); IsDigest = $true }
    }
    # 冒号只有在最后一段路径里才是 tag：localhost:5000/foo 的冒号是端口
    $slash = $ref.LastIndexOf('/')
    $colon = $ref.LastIndexOf(':')
    if ($colon -gt $slash) {
        return @{ Name = $ref.Substring(0, $colon); Tag = $ref.Substring($colon + 1); IsDigest = $false }
    }
    return @{ Name = $ref; Tag = 'latest'; IsDigest = $false }
}

function Get-TargetRef([string]$src) {
    $p = Split-Ref $src
    if ($p.IsDigest) { Die "本脚本按 tag 搬运，不支持 digest：$src" }
    $flat = $p.Name -replace '[/.]', '-'
    $flat = $flat.ToLowerInvariant()
    $flat = [regex]::Replace($flat, '[^a-z0-9_-]', '-').TrimEnd('-')
    return "$script:DeriveRegistry/$script:DeriveNamespace/${flat}:$($p.Tag)"
}

# 把一个引用从旧 registry/namespace 挪到新的（中转模式用）
#   ghcr.io/me/flat:tag + (localhost:5000, mirror) → localhost:5000/mirror/flat:tag
function Retarget-Ref([string]$ref, [string]$reg, [string]$ns) {
    $slash = $ref.IndexOf('/')
    if ($slash -lt 0) { return $ref }
    $path = $ref.Substring($slash + 1)
    $s2 = $path.IndexOf('/')
    $rest = if ($s2 -ge 0) { $path.Substring($s2 + 1) } else { $path }
    return "$reg/$ns/$rest"
}

function Get-MirrorForHost([string]$host_) {
    if (-not (Test-Path -LiteralPath $MirrorsFile)) { return '' }
    foreach ($line in Get-Content -LiteralPath $MirrorsFile) {
        $l = ($line -replace '#.*$', '').Trim().TrimStart([char]0xFEFF)
        if (-not $l) { continue }
        $kv = $l -split '=', 2
        if ($kv.Count -eq 2 -and $kv[0].Trim() -eq $host_) { return $kv[1].Trim() }
    }
    return ''
}

function Get-PullRef([string]$src) {
    if ($src -notmatch '/') { return $src }
    $host_ = ($src -split '/')[0]
    $rest = $src.Substring($host_.Length + 1)
    $prefix = Get-MirrorForHost $host_
    if ($prefix) { return "$prefix/$rest" }
    return $src
}

# ---------------------------------------------------------------------------
# skopeo 调用封装
#
# 参数分两层（实测 skopeo 1.24 与 1.8 划分一致）：
#   全局（必须在子命令之前）：--tmpdir / --override-arch / --override-os
#   子命令级（跟在 copy|inspect 之后）：--authfile / --src-creds / --dest-creds / --retry-times / --all
# ---------------------------------------------------------------------------
$script:A = @()                       # 子命令级
$script:I = @()                       # inspect 专用（目标非 https 时的 --tls-verify=false）
$script:Plat = $Platforms             # 运行期：当前镜像的平台，逐行 platform= 会覆盖它

if ($InsecureDest) { $script:I += @('--tls-verify=false') }

if ($AuthFile) {
    if (-not (Test-Path -LiteralPath $AuthFile)) { Die "AuthFile 不存在：$AuthFile" }
    $script:A += @('--authfile', $AuthFile)
} elseif (-not $DestCreds -and -not $SourceCreds -and -not $env:GHCR_USER) {
    # 没给显式凭据时，才退回 docker config（注意 Docker Desktop 的 credsStore 可能不可用）
    $cfg = Join-Path $env:USERPROFILE '.docker\config.json'
    if (Test-Path -LiteralPath $cfg) { $script:A += @('--authfile', $cfg) }
}

function Get-SkopeoGlobal {
    $g = @()
    if ($env:SKOPEO_TMPDIR) { $g += @('--tmpdir', $env:SKOPEO_TMPDIR) }
    if ($script:Plat) {
        $p = $script:Plat.Split(',')[0]
        $g += @('--override-os', $p.Split('/')[0], '--override-arch', $p.Split('/')[1])
    }
    return $g
}

function Invoke-SkopeoInspect {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $all = @(Get-SkopeoGlobal)
    $all += 'inspect'
    if ($script:A.Count -gt 0) { $all += $script:A }
    if ($script:I.Count -gt 0) { $all += $script:I }
    $all += $Args
    & $Skopeo @all
    return $LASTEXITCODE
}

function Invoke-SkopeoCopy {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $all = @(Get-SkopeoGlobal)
    $all += 'copy'
    if ($script:A.Count -gt 0) { $all += $script:A }
    $all += $Args
    & $Skopeo @all
    return $LASTEXITCODE
}

function Test-TargetExists([string]$ref) {
    $null = Invoke-SkopeoInspect --raw "docker://$ref" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-TargetDigest([string]$ref) {
    $d = (Invoke-SkopeoInspect --format '{{.Digest}}' "docker://$ref" 2>$null | Select-Object -First 1)
    if ($d) { return $d.Trim() }
    return ''
}

function Test-TargetHasArch([string]$ref, [string]$want) {
    $wantOs = ''; $wantArch = $want
    if ($want -match '/') { $wantOs = $want.Split('/')[0]; $wantArch = $want.Split('/')[1] }

    $raw = (Invoke-SkopeoInspect --raw "docker://$ref" 2>$null) -join ''
    if ($raw -and $raw -notmatch '"manifests"') {
        # 单架构镜像：raw 里没有平台列表，只能看 config
        $a = (Invoke-SkopeoInspect --format '{{.Architecture}}' "docker://$ref" 2>$null | Select-Object -First 1)
        $o = (Invoke-SkopeoInspect --format '{{.Os}}' "docker://$ref" 2>$null | Select-Object -First 1)
        if (-not $a) { return $false }
        return ($a.Trim() -eq $wantArch -and (-not $wantOs -or -not $o -or $o.Trim() -eq $wantOs))
    }
    return ($raw -match ('"architecture"\s*:\s*"' + [regex]::Escape($wantArch) + '"'))
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
if (-not $TargetNamespace) { Die "没给 TargetNamespace（-TargetNamespace 或环境变量 TARGET_NAMESPACE）" }
if ($Relay) {
    if (-not $FromNamespace) { Die "-Relay 需要 -FromNamespace（你镜像仓库的命名空间，如你的 GitHub 用户名）" }
    $script:DeriveRegistry  = $FromRegistry
    $script:DeriveNamespace = $FromNamespace
}
if (-not (Test-Path -LiteralPath $ImagesFile)) { Die "找不到清单文件：$ImagesFile" }
if (-not $DestCreds -and $env:GHCR_USER -and $env:GHCR_TOKEN) { $DestCreds = "$($env:GHCR_USER):$($env:GHCR_TOKEN)" }
if ($Relay -and -not $SourceCreds -and $env:GHCR_USER -and $env:GHCR_TOKEN) {
    # 中转模式下 GHCR 是"源"，凭据该给 --src-creds，不能还留在 dest 上
    $SourceCreds = "$($env:GHCR_USER):$($env:GHCR_TOKEN)"
    $DestCreds   = ''
}

$skopeoCmd = Get-Command $Skopeo -ErrorAction SilentlyContinue
if (-not $skopeoCmd) { Die "找不到 skopeo：$Skopeo（用 -Skopeo 指定 skopeo.exe 的完整路径）" }

$items = New-Object System.Collections.ArrayList
foreach ($line in Get-Content -LiteralPath $ImagesFile) {
    $l = ($line -replace '#.*$', '').Trim().TrimStart([char]0xFEFF)   # 顺手去掉 BOM
    if (-not $l) { continue }
    $f = @($l -split '\s+')
    $src = Get-NormalizedSrc $f[0]
    $dst = ''; $plat = ''; $arch = ''; $mir = ''
    for ($i = 1; $i -lt $f.Count; $i++) {
        $tok = $f[$i]
        if     ($tok -like 'platform=*')     { $plat = $tok.Substring(9) }
        elseif ($tok -like 'require_arch=*') { $arch = $tok.Substring(13) }
        elseif ($tok -like 'mirror=*')       { $mir  = $tok.Substring(7) }
        elseif ($tok -like '*=*')            { Die "清单里不认识的选项：$tok（支持 platform= / require_arch= / mirror=）" }
        elseif ($dst)                        { Die "清单里的 $src 有多个目标名：$dst 和 $tok" }
        else                                 { $dst = $tok }
    }
    if (-not $dst) { $dst = Get-TargetRef $src }
    [void]$items.Add([pscustomobject]@{ Src = $src; Dst = $dst; Plat = $plat; Arch = $arch; Mir = $mir })
}

if ($Only) {
    # 注意：用 `pwsh -File` 调用时 `-Only a,b` 会作为单个字符串传进来，
    # 所以这里再按逗号拆一次，保证 `-Only a,b` 和 `-Only a b` 都能用。
    $wanted = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } |
                ForEach-Object { Get-NormalizedSrc $_ })
    $items = @($items | Where-Object { $wanted -contains $_.Src })
    if ($items.Count -eq 0) { Die "-Only 没匹配到任何镜像" }
}
if ($items.Count -eq 0) { Die "$ImagesFile 里没有任何镜像" }

Write-Head '配置'
if ($Relay) {
    Write-Host "  模式          : 中转（relay）—— 从你的镜像仓库推到目标 registry"
    Write-Host "  中转来源      : $script:DeriveRegistry/$script:DeriveNamespace"
}
Write-Host "  目标 registry : $TargetRegistry/$TargetNamespace"
Write-Host "  同步工具      : $Skopeo（registry→registry 直拷，本地不占磁盘）"
Write-Host "  清单文件      : $ImagesFile（$($items.Count) 个镜像）"
Write-Host "  镜像站替换表  : $MirrorsFile"
if ($Relay) {
    if ($SourceCreds) { Write-Host "  拉取凭据      : 已提供（$($SourceCreds.Split(':')[0]):***）" }
    else { Write-Warn2 '中转模式没给凭据：你镜像仓库里的包若是 private，skopeo 会 401（设 GHCR_USER/GHCR_TOKEN，或用 -SourceCreds）' }
} elseif ($DestCreds) {
    Write-Host "  推送凭据      : 已提供（$($DestCreds.Split(':')[0]):***）"
} else {
    Write-Warn2 '没有提供推送凭据 —— 除非目标包是 public 且你已有 docker login，否则推送会 401'
}
if ($Platforms) { Write-Host "  限定平台      : $Platforms" }
if ($RequireArch) { Write-Host "  校验架构      : $RequireArch" }
if ($DryRun) { Write-Host "  模式          : dry-run（不实际推送）" -ForegroundColor Yellow }

$idx = 0
foreach ($it in $items) {
    $idx++
    $src = $it.Src; $dst = $it.Dst
    $effPlat = if ($it.Plat) { $it.Plat } else { $Platforms }
    $effArch = if ($it.Arch) { $it.Arch } else { $RequireArch }
    $script:Plat = $effPlat
    if ($Relay) {
        # 中转模式：源 = 你镜像仓库里的那个名字（$dst），目标 = 新的 registry/namespace
        $pullSrc = $dst
        $dst = Retarget-Ref $dst $TargetRegistry $TargetNamespace
    } else {
        $pullSrc = if ($it.Mir) { "$($it.Mir.TrimEnd('/'))/" + $src.Substring($src.IndexOf('/') + 1) } else { Get-PullRef $src }
    }
    $digest = ''; $note = ''

    Write-Head "[$idx/$($items.Count)] $src"
    Write-Host "    目标：$dst"
    if ($Relay) { Write-Host "    从镜像仓库中转：$pullSrc" }
    elseif ($pullSrc -ne $src) { Write-Host "    取源走镜像站：$pullSrc" }
    if ($effPlat) { Write-Host "    平台限定：$effPlat" }

    if ($DryRun) {
        $script:Dry++
        [void]$script:Results.Add([pscustomobject]@{ N = $idx; St = 'DRY'; Src = $src; Dst = $dst; Note = '只演示，未执行' })
        continue
    }

    if (-not $Force -and (Test-TargetExists $dst)) {
        Write-Host "    tag 已存在，跳过（-Force 可强制重推）"
        $script:Skip++
        [void]$script:Results.Add([pscustomobject]@{ N = $idx; St = 'SKIP'; Src = $src; Dst = $dst; Note = 'tag 已存在' })
        continue
    }

    # 注意：--override-arch/--override-os 是全局参数，由 Get-SkopeoGlobal 统一加在子命令之前
    $copyArgs = @('--retry-times', "$RetryTimes")
    if ($SourceCreds) { $copyArgs += @('--src-creds', $SourceCreds) }
    if ($DestCreds)   { $copyArgs += @('--dest-creds', $DestCreds) }
    if ($InsecureSrc)  { $copyArgs += @('--src-tls-verify=false') }
    if ($InsecureDest) { $copyArgs += @('--dest-tls-verify=false') }
    if (-not $effPlat) { $copyArgs += @('--all') }

    $rc = Invoke-SkopeoCopy @copyArgs "docker://$pullSrc" "docker://$dst"
    if ($rc -ne 0) {
        Write-Warn2 "搬运失败（skopeo 退出码 $rc）"
        $script:Fail++
        [void]$script:Results.Add([pscustomobject]@{ N = $idx; St = 'FAIL'; Src = $src; Dst = $dst; Note = "退出码 $rc" })
        continue
    }

    if ($effArch) {
        if (Test-TargetHasArch $dst $effArch) { $note = "含 $effArch" }
        else {
            Write-Warn2 "$dst 推上去了，但里面没有 $effArch"
            $script:Fail++
            [void]$script:Results.Add([pscustomobject]@{ N = $idx; St = 'FAIL'; Src = $src; Dst = $dst; Note = "没有 $effArch" })
            continue
        }
    }

    $digest = Get-TargetDigest $dst
    Write-Host "    完成，digest=$($digest)"
    $script:Ok++
    [void]$script:Results.Add([pscustomobject]@{ N = $idx; St = 'OK'; Src = $src; Dst = $dst; Note = "$digest $note".Trim() })
}

Write-Head '同步结果'
foreach ($r in $script:Results) {
    $color = switch ($r.St) { 'OK' { 'Green' } 'SKIP' { 'DarkGray' } 'DRY' { 'Cyan' } default { 'Red' } }
    Write-Host ("{0,-3} {1,-5} {2}" -f $r.N, $r.St, $r.Src) -ForegroundColor $color
    Write-Host ("{0,-9} {1}" -f '', $r.Dst) -ForegroundColor $color
    if ($r.Note) { Write-Host ("{0,-9} {1}" -f '', $r.Note) -ForegroundColor $color }
}
Write-Host ""
Write-Host "成功 $script:Ok / 跳过 $script:Skip / 演示 $script:Dry / 失败 $script:Fail（共 $($items.Count)）"

# 存一份取件命令，方便拷到目标机器上执行
$listFile = 'pull-list.txt'
$platArg = if ($Platforms) { "--platform $Platforms " } else { '' }
$script:Results | Where-Object { $_.St -in @('OK', 'SKIP') } |
    ForEach-Object { "docker pull $platArg$($_.Dst)" } |
    Set-Content -LiteralPath $listFile -Encoding UTF8
Write-Host "取件命令已写入 $listFile（平台参数取自 -Platforms，留空 = 按取件机架构拉）"

if ($script:Fail -gt 0 -and -not $AllowFail) {
    Write-Host "有 $script:Fail 个镜像失败，退出码 1（加 -AllowFail 可忽略）" -ForegroundColor Red
    exit 1
}
