<#
.SYNOPSIS
    开一条 SSH 本地端口转发（-L），把"远端机器上的 registry"映射到本机端口。
    这样本机的 skopeo.exe 往 localhost:<端口> 推，就等于推到了远端。

    用途：第二步中转 —— 你的镜像仓库(GHCR) ──本机 skopeo──> SSH 隧道 ──> 910c 侧 registry

.EXAMPLE
    # 910c 上已经跑了一个监听 127.0.0.1:5000 的 registry
    .\scripts\tunnel.ps1 -SshHost root@36.141.20.212 -Port 1122

    # 远端 registry 在别的端口/别的主机（从 910c 能访问到）
    .\scripts\tunnel.ps1 -SshHost root@36.141.20.212 -Port 1122 -RemoteHost 10.0.0.9 -RemotePort 5000 -LocalPort 5000

    # 隧道开好之后，另开一个窗口做中转：
    .\scripts\mirror.ps1 -Relay -FromNamespace <你的用户名> `
        -TargetRegistry localhost:5000 -TargetNamespace mirror -InsecureDest

.NOTES
    这个窗口要保持开着；关掉隧道就断了。用 -Background 让它在独立窗口里跑。
    远端 registry 若是 http，本机侧要加 -InsecureDest，910c 侧 docker 还要配
    insecure-registries（见 README「两段式拓扑」）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SshHost,
    [int]    $Port       = 22,
    [string] $RemoteHost = '127.0.0.1',
    [int]    $RemotePort = 5000,
    [int]    $LocalPort  = 5000,
    [switch] $Background
)

$ErrorActionPreference = 'Stop'

$ssh = Get-Command ssh -ErrorAction SilentlyContinue
if (-not $ssh) { Write-Host '[中止] 本机没有 ssh 客户端（Windows 可选功能里装 OpenSSH Client）' -ForegroundColor Red; exit 1 }

$fwd = "${LocalPort}:${RemoteHost}:${RemotePort}"
$args = @(
    '-N',
    '-L', $fwd,
    '-p', "$Port",
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ServerAliveInterval=30',
    '-o', 'ServerAliveCountMax=3',
    $SshHost
)

Write-Host ""
Write-Host "==> SSH 端口转发" -ForegroundColor Cyan
Write-Host "  $SshHost (端口 $Port)"
Write-Host "  localhost:$LocalPort  -->  $RemoteHost`:$RemotePort"
Write-Host ""
Write-Host "  隧道起来后，在另一个窗口执行中转：" -ForegroundColor Yellow
Write-Host "    .\scripts\mirror.ps1 -Relay -FromNamespace <你的用户名> ``"
Write-Host "        -TargetRegistry localhost:$LocalPort -TargetNamespace mirror -InsecureDest"
Write-Host ""
Write-Host "  按 Ctrl+C 断开隧道。" -ForegroundColor DarkGray
Write-Host ""

if ($Background) {
    Start-Process -FilePath $ssh.Source -ArgumentList $args
    Write-Host "  已在独立窗口后台启动隧道。" -ForegroundColor Green
} else {
    & $ssh.Source @args
}
