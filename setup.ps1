# ============================================================
# 一键部署安装器（setup.ps1）—— 改进版
# ------------------------------------------------------------
# 运行一次即可完成全部部署：
#   1. 自动识别微信安装位置（进程 / 常见目录）
#   2. 自动识别屏幕物理分辨率 + DPI（按钮用相对比例，自动适配）
#   3. 生成自动登录脚本（微信路径自动填入，UTF-8 带 BOM，中文注释不乱码）
#   4. 配置开机自启（启动微信 + 隐藏运行自动登录）
# 卸载：运行 uninstall.ps1
# 用法：powershell -ExecutionPolicy Bypass -File setup.ps1
# 编码：本文件含中文注释，请用 UTF-8（带 BOM）保存。
# ============================================================
param(
    [string]$OutDir = $PSScriptRoot   # 生成脚本的输出目录（默认本目录）
)
$ErrorActionPreference = 'Stop'

# ---------- 第 1 步：自动识别微信安装位置 ----------
function Find-WeChatExe {
    # 优先：从正在运行的微信进程取真实路径
    $p = Get-Process -Name "Weixin" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p -and $p.Path -and (Test-Path $p.Path)) { return $p.Path }

    # 其次：扫描常见安装目录
    $roots = @("$env:ProgramFiles", "${env:ProgramFiles(x86)}",
               "D:\", "C:\Program Files", "$env:LOCALAPPDATA\Programs")
    $names = @("WeChat\Weixin\Weixin.exe", "Tencent\WeChat\Weixin.exe",
               "Weixin\Weixin.exe", "Tencent\Weixin\Weixin.exe")
    foreach ($r in $roots) {
        foreach ($n in $names) {
            $c = Join-Path $r $n
            if (Test-Path $c) { return $c }
        }
    }
    return $null
}

$wxExe = Find-WeChatExe
if (-not $wxExe) {
    Write-Host "[ERROR] WeChat Weixin.exe not found automatically."
    Write-Host "        Please install WeChat first, or edit the path in this file."
    exit 1
}
$wxDir = Split-Path $wxExe

# ---------- 第 2 步：识别物理分辨率 / DPI ----------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DpiX {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern int GetDpiForSystem();
}
"@
[DpiX]::SetProcessDPIAware() | Out-Null
$resW  = [DpiX]::GetSystemMetrics(0)
$resH  = [DpiX]::GetSystemMetrics(1)
$dpi   = [DpiX]::GetDpiForSystem()
$scale = [math]::Round($dpi / 96.0, 2)
Write-Host "Screen resolution : ${resW} x ${resH} (physical)"
Write-Host "DPI scaling       : $dpi  (${scale}x)"
Write-Host "WeChat location   : $wxExe"

# ---------- 第 3 步：生成自动登录脚本（内嵌改进版，路径用占位符） ----------
$mainContent = @'
# ============================================================
# 微信自动登录脚本（由 setup.ps1 自动生成，UTF-8 带 BOM）
# 改进点：事件驱动更快、点击失败自动重试、登录后鼠标归位。
# ============================================================
param(
    [string]$WeChatExe  = "{WECHAT_EXE}",
    [string]$WeChatDir  = "{WECHAT_DIR}",
    [int]$TimeoutSec    = 30,
    [double]$BtnX       = 0.498,
    [double]$BtnY       = 0.773,
    [int]$MaxRetries    = 3,
    [bool]$RestoreMouse = $true
)
$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WxApi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, ChildProc cb, IntPtr l);
    public delegate bool ChildProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, IntPtr rect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT pt);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    public struct POINT { public int X; public int Y; }
}
"@
[WxApi]::SetProcessDPIAware() | Out-Null

$LEFTDOWN = 0x0002
$LEFTUP   = 0x0004

function Log([string]$msg){ Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $msg) }

function Update-WxWindow {
    $script:curTarget = [IntPtr]::Zero
    $script:curRender = [IntPtr]::Zero
    $cb = [WxApi+EnumProc]{
        param($h,$l)
        $t = New-Object System.Text.StringBuilder 256
        [WxApi]::GetWindowText($h,$t,256) | Out-Null
        if ($t.ToString() -ne 'WeChat') { return $true }
        if (-not [WxApi]::IsWindowVisible($h)) { return $true }
        $script:fr = [IntPtr]::Zero
        $ccb = [WxApi+ChildProc]{
            param($ch,$cl)
            $cn = New-Object System.Text.StringBuilder 256
            [WxApi]::GetClassName($ch,$cn,256) | Out-Null
            if ($cn.ToString() -eq 'MMUIRenderSubWindowHW') { $script:fr = $ch; return $false }
            return $true
        }
        [WxApi]::EnumChildWindows($h,$ccb,[IntPtr]::Zero) | Out-Null
        if ($script:fr -ne [IntPtr]::Zero) { $script:curTarget = $h; $script:curRender = $script:fr; return $false }
        return $true
    }
    [WxApi]::EnumWindows($cb,[IntPtr]::Zero) | Out-Null
}

function Get-WxRect([IntPtr]$hwnd){
    $p = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(16)
    [WxApi]::GetWindowRect($hwnd,$p) | Out-Null
    $L = [System.Runtime.InteropServices.Marshal]::ReadInt32($p,0)
    $T = [System.Runtime.InteropServices.Marshal]::ReadInt32($p,4)
    $R = [System.Runtime.InteropServices.Marshal]::ReadInt32($p,8)
    $B = [System.Runtime.InteropServices.Marshal]::ReadInt32($p,12)
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($p)
    return @{ L=$L; T=$T; R=$R; B=$B; W=($R-$L); H=($B-$T) }
}

function Test-LoggedIn {
    Update-WxWindow
    if ($script:curRender -eq [IntPtr]::Zero) { return $true }
    $r = Get-WxRect $script:curRender
    return ($r.W -ge $r.H)
}

if (-not (Get-Process -Name "Weixin" -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $WeChatExe)) { Log "WeChat not found: $WeChatExe (skip)"; exit 0 }
    Start-Process -FilePath $WeChatExe -WorkingDirectory $WeChatDir
    Log "WeChat starting..."
}

$deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
$loginFound = $false
while ([DateTime]::Now -lt $deadline) {
    Update-WxWindow
    if ($script:curTarget -ne [IntPtr]::Zero) {
        $r0 = Get-WxRect $script:curRender
        if ($r0.H -gt $r0.W) { $loginFound = $true; break }
        if ($r0.W -ge $r0.H) { Log "Already in main window, nothing to click."; exit 0 }
    }
    Start-Sleep -Milliseconds 150
}
if (-not $loginFound) { Log "No login window within ${TimeoutSec}s (already logged in?). skip."; exit 0 }

$saved = New-Object 'WxApi+POINT'
[WxApi]::GetCursorPos([ref]$saved) | Out-Null

$ok = $false
for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    if (Test-LoggedIn) { $ok = $true; break }
    if ($script:curRender -eq [IntPtr]::Zero) { $ok = $true; break }

    [WxApi]::SetForegroundWindow($script:curTarget) | Out-Null
    Start-Sleep -Milliseconds 150

    $r = Get-WxRect $script:curRender
    $x = $r.L + [int]($r.W * $BtnX)
    $y = $r.T + [int]($r.H * $BtnY)
    Log ("Click attempt {0}/{1} at ({2},{3}) size {4}x{5}" -f $attempt,$MaxRetries,$x,$y,$r.W,$r.H)

    [WxApi]::SetCursorPos($x,$y) | Out-Null
    Start-Sleep -Milliseconds 60
    [WxApi]::mouse_event($LEFTDOWN,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
    [WxApi]::mouse_event($LEFTUP,0,0,0,[UIntPtr]::Zero)

    $clickDeadline = [DateTime]::Now.AddSeconds(2.5)
    while ([DateTime]::Now -lt $clickDeadline) {
        Start-Sleep -Milliseconds 120
        if (Test-LoggedIn) { $ok = $true; break }
    }
    if ($ok) { break }
    Log "Not in main window yet, retrying..."
}

if ($RestoreMouse) { [WxApi]::SetCursorPos($saved.X,$saved.Y) | Out-Null }

if ($ok) { Log "Logged in. Done."; exit 0 }
else { Log "WARN: login not confirmed after $MaxRetries attempts, please click manually."; exit 1 }
'@

# 把检测到的微信路径填入生成脚本
$mainContent = $mainContent.Replace('{WECHAT_EXE}', $wxExe)
$mainContent = $mainContent.Replace('{WECHAT_DIR}', $wxDir)

$mainPath = Join-Path $OutDir "wechat_autologin.ps1"
# 用 UTF-8【带 BOM】写入，保证 Windows PowerShell 5.1 下中文注释不乱码
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($mainPath, $mainContent, $utf8Bom)
Write-Host "[OK] Wrote (UTF-8 BOM): $mainPath"

# ---------- 第 4 步：配置开机自启 ----------
$startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell

# 启动项 1：开机启动微信
$l1 = $ws.CreateShortcut((Join-Path $startup "WeChat.lnk"))
$l1.TargetPath  = $wxExe
$l1.Description = "Start WeChat"
$l1.Save()

# 启动项 2：开机隐藏运行自动登录脚本
$l2 = $ws.CreateShortcut((Join-Path $startup "WeChatAutoLogin.lnk"))
$l2.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$l2.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mainPath`""
$l2.Description = "WeChat auto login"
$l2.Save()

Write-Host "[OK] Autostart configured:"
Write-Host "     WeChat.lnk          -> $wxExe"
Write-Host "     WeChatAutoLogin.lnk -> $mainPath"
Write-Host ""
Write-Host "Done. Run uninstall.ps1 to remove autostart."
Write-Host "Tip: enable 'Auto login on this device' in WeChat (phone) to skip confirmation."
