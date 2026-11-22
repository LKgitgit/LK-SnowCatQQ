#requires -Version 5.1
<#
    SnowCat QQ 9.9.37 启动器（V8 源码改写通道）

    原理：
      1) QQ.exe 静态导入 WINMM.dll，且它不在 KnownDLLs 里 → 在 QQ 目录放同名代理即可侧加载
      2) 代理里 MinHook 掉 QQNT.dll 导出的 v8::ScriptCompiler::Compile*，
         在"解密后的 JS 正要被编译"这一刻拿到明文源码
      3) 命中 app_launcher/index.js 时，把 Source::source_string_ 换成"引导脚本 + 原文"
      4) 引导脚本动态 import napcat.mjs，napcat 在 QQ 主进程内正常启动

    另修一个环境问题：
      resources\app 里的 dbghelp.dll / dbgeng.dll 是坏的，
      导致 LightQuic.dll、broadcast_ipc.dll 加载失败(193)，
      进而 wrapper.node 无法 dlopen。把它们禁用后改走系统版本。

    用法：
      .\snowcat-run.ps1                # 启动
      .\snowcat-run.ps1 -Stop          # 停止
      .\snowcat-run.ps1 -Status        # 只看状态
#>
param(
    [string]$QqUin = "$env:QQ_ACCOUNT",
    [string]$Shell = ".\SnowCat.Portable\SnowCat.9.9.37-54395.Shell",
    [switch]$Stop,
    [switch]$Status
)

# ── 编码设置（必须在 param 之后，否则会破坏 param 块解析）──
chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = 'Stop'
# 自动探测构建产物目录：优先使用脚本同级目录，其次向上查找
$scriptDir = $PSScriptRoot
$possibleBuildDirs = @(
    (Join-Path $scriptDir 'tools\build'),
    (Join-Path $scriptDir '..\tools\build'),
    (Join-Path $scriptDir '..\..\release-tools\build')
)
$Build = $possibleBuildDirs | Where-Object { Test-Path (Join-Path $_ 'winmm-v8.dll') } | Select-Object -First 1
if (-not $Build) {
    throw "无法自动定位构建产物目录（winmm-v8.dll 所在目录）。请检查文件是否齐全，或手动指定 `$Build`。"
}

function Write-Step($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err2($m) { Write-Host "[x] $m" -ForegroundColor Red }

function Get-AppDir([string]$shell) {
    $vers = Join-Path $shell 'versions'
    if (-not (Test-Path $vers)) { throw "找不到 versions 目录: $vers" }
    $cands = Get-ChildItem $vers -Directory | Where-Object {
        Test-Path (Join-Path $_.FullName 'resources\app\package.json')
    } | Sort-Object Name -Descending
    if (-not $cands) { throw "versions 下没有可用的 resources\app" }
    return (Join-Path $cands[0].FullName 'resources\app')
}

function Get-ServiceState {
    $code = $null
    try {
        $code = (Invoke-WebRequest -Uri 'http://127.0.0.1:6099/webui/' -TimeoutSec 3 -UseBasicParsing -Proxy $null).StatusCode
    } catch {}
    $qq = @(Get-Process QQ -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        QQ      = $qq.Count
        Webui   = if ($code) { $code } else { 'closed' }
        Online  = ($code -eq 200)
    }
}

function Stop-Qq {
    param(
        [string]$TargetShell,
        [switch]$Quiet
    )

    if (-not $TargetShell) {
        if (-not $Quiet) { Write-Warn2 '未指定 Shell，跳过进程清理' }
        return 0
    }

    # 统一解析为绝对路径（兼容相对路径传参）
    $targetShellAbs = if (Test-Path $TargetShell) {
        (Resolve-Path $TargetShell).Path.TrimEnd('\')
    } else {
        $TargetShell.TrimEnd('\')
    }
    $shellExe    = Join-Path $targetShellAbs 'QQ.exe'
    $shellPrefix = $targetShellAbs + '\'

    # 只枚举名字以 QQ 开头的进程（QQ.exe / QQProtect.exe / QQExternal.exe 等）
    $allProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^QQ' })

    $killed = 0
    foreach ($p in $allProcs) {
        $procPath = $p.ExecutablePath
        $isOur = $false

        if ($procPath) {
            # 主进程：路径完全等于 Shell\QQ.exe
            # 子进程：路径以 Shell\ 开头（versions\9.9.37-54395\QQ.exe 等）
            if ($procPath -ieq $shellExe -or
                $procPath.StartsWith($shellPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isOur = $true
            }
        }

        if ($isOur) {
            if (-not $Quiet) {
                Write-Host ("  [kill] PID {0,-6} {1}  {2}" -f $p.ProcessId, $p.Name, $procPath) -ForegroundColor DarkGray
            }
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            $killed++
        }
    }

    if ($killed -gt 0) {
        Start-Sleep -Seconds 2   # 等文件句柄释放，避免 winmm.dll 被占用
        if (-not $Quiet) { Write-Ok "已清理 $killed 个 SnowCat 进程" }
    } elseif (-not $Quiet) {
        Write-Step '没有需要清理的 SnowCat 进程'
    }

    return $killed
}

if ($Stop) {
    Write-Step '停止 SnowCat（不影响其他 QQ）'
    Stop-Qq -TargetShell $Shell
    return
}

if ($Status) {
    $s = Get-ServiceState
    Write-Host ("QQ 进程: {0}    6099: {1}" -f $s.QQ, $s.Webui)
    if ($s.Online) { Write-Ok 'SnowCat WebUI 在线' } else { Write-Warn2 'WebUI 未监听' }
    return
}

# ── 1. 环境自检 ──────────────────────────────────────────────
if (-not (Test-Path (Join-Path $Shell 'QQ.exe'))) { throw "找不到 QQ.exe: $Shell" }
$app = Get-AppDir $Shell
Write-Step "app 目录: $app"

# ── 2. 修坏掉的调试 DLL（否则 wrapper.node 无法加载）─────────
foreach ($bad in 'dbghelp.dll', 'dbgeng.dll') {
    $p = Join-Path $app $bad
    if (Test-Path $p) {
        $size = (Get-Item $p).Length
        Move-Item $p "$p.disabled" -Force
        Write-Ok ("禁用 {0}（{1} 字节，无法加载）" -f $bad, $size)
    }
}

# ── 3. 部署侧加载代理 ────────────────────────────────────────
Write-Step '释放 winmm.dll 句柄'
Stop-Qq -TargetShell $Shell -Quiet
$srcDll = Join-Path $Build 'winmm-v8.dll'
if (-not (Test-Path $srcDll)) { throw "缺少构建产物: $srcDll" }
Copy-Item $srcDll (Join-Path $Shell 'winmm.dll') -Force
Write-Ok ("winmm.dll 已部署（{0} KB）" -f [math]::Round((Get-Item $srcDll).Length/1KB))

# ── 4. 部署引导脚本 ──────────────────────────────────────────
$srcBoot = Join-Path $Build 'snowcat-boot.js'
$dstBoot = Join-Path $Shell 'snowcat-boot.js'
if (Test-Path $srcBoot) {
    Copy-Item $srcBoot $dstBoot -Force
} elseif (-not (Test-Path $dstBoot)) {
    throw "缺少引导脚本: $dstBoot"
}
Write-Ok 'snowcat-boot.js 就位'

# ── 5. 部署 WebUI 静态资源（缺了页面就是一片空白）───────────
$staticDir = Join-Path $Shell 'static'
if (-not (Test-Path (Join-Path $staticDir 'index.html'))) {
    $srcStatic = Join-Path $Build 'static-dist'
    if (Test-Path (Join-Path $srcStatic 'index.html')) {
        if (Test-Path $staticDir) { Remove-Item $staticDir -Recurse -Force }
        Copy-Item $srcStatic $staticDir -Recurse -Force
        Write-Ok 'static/ 已部署（WebUI 前端）'
    } else {
        Write-Warn2 "缺少 WebUI 静态资源（$staticDir），页面会打不开"
    }
} else {
    Write-Ok 'static/ 已存在'
}

# ── 6. 启动 ──────────────────────────────────────────────────
Write-Step '清理旧的 SnowCat 进程（不影响其他 QQ）'
Stop-Qq -TargetShell $Shell

foreach ($n in 'https_proxy','HTTPS_PROXY','http_proxy','HTTP_PROXY') {
    Remove-Item "Env:$n" -ErrorAction SilentlyContinue
}
Remove-Item (Join-Path $Shell 'nc-boot.log') -ErrorAction SilentlyContinue
Stop-Qq
foreach ($n in 'https_proxy','HTTPS_PROXY','http_proxy','HTTP_PROXY') {
    Remove-Item "Env:$n" -ErrorAction SilentlyContinue
}
Remove-Item (Join-Path $Shell 'nc-boot.log') -ErrorAction SilentlyContinue

Write-Step "启动 QQ（账号 $QqUin）"
$qqArgs = @(
    "--enable-logging",
    "--disable-gpu",
    "--disable-software-rasterizer",
    "--no-sandbox",
    "--disable-gpu-sandbox"
)
if ($QqUin) { $qqArgs += @("-q", $QqUin) }
Start-Process -FilePath (Join-Path $Shell 'QQ.exe') -ArgumentList $qqArgs -WorkingDirectory $Shell

# ── 7. 等待并报告 ────────────────────────────────────────────
$deadline = (Get-Date).AddSeconds(45)
$ok = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 800
    try {
        $c = (Invoke-WebRequest -Uri 'http://127.0.0.1:6099/webui/' -TimeoutSec 2 -UseBasicParsing -Proxy $null).StatusCode
        if ($c -eq 200) { $ok = $true; break }
    } catch {}
}

$bootLog = Join-Path $Shell 'nc-boot.log'
if (Test-Path $bootLog) {
    Write-Host ''
    Write-Step '注入日志：'
    Get-Content $bootLog | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}

Write-Host ''
if ($ok) {
    Write-Ok 'SnowCat WebUI 已就绪 → http://127.0.0.1:6099/webui/'
} else {
    Write-Err2 'WebUI 未在 45 秒内就绪'
    Write-Warn2 '排查顺序：1) 看上面注入日志  2) QQ 是否被安全软件拦截  3) 是否 dbghelp.dll 又出现了'
}