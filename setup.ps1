# ============================================================
# wechat-auto-login - ONE-CLICK DEPLOY INSTALLER
# Detects:
#   1. WeChat install location (process / common paths / registry)
#   2. Screen resolution + DPI scaling (button pos is RELATIVE,
#      so it adapts automatically across resolutions)
# Then writes the auto-login script and configures autostart.
# Pure ASCII (PowerShell 5.1 parses no-BOM UTF-8 as ANSI).
# Usage: powershell -ExecutionPolicy Bypass -File setup.ps1
# ============================================================
param(
    [string]$OutDir = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'

# ---------- 1) Detect WeChat install location ----------
function Find-WeChatExe {
    $p = Get-Process -Name "Weixin" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p -and $p.Path -and (Test-Path $p.Path)) { return $p.Path }

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
    Write-Host "[ERROR] WeChat Weixin.exe was not found automatically."
    Write-Host "        Install WeChat first, or open this file and set the path."
    exit 1
}
$wxDir = Split-Path $wxExe

# ---------- 2) Detect physical screen resolution / DPI ----------
# Use physical pixels (DPI-aware) so the shown resolution is the REAL
# monitor resolution, not the logical (scaled-down) value.
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
$resW = [DpiX]::GetSystemMetrics(0)   # SM_CXSCREEN physical px
$resH = [DpiX]::GetSystemMetrics(1)   # SM_CYSCREEN physical px
$dpi = [DpiX]::GetDpiForSystem()
$scale = [math]::Round($dpi / 96.0, 2)

Write-Host "Screen resolution : ${resW} x ${resH} (physical)"
Write-Host "DPI scaling       : $dpi  (${scale}x)"
Write-Host "WeChat location   : $wxExe"

# ---------- 3) Write the auto-login script ----------
# Button click is located by RELATIVE % of the render window,
# so it works on any resolution / DPI without manual adjustment.
$mainContent = @'
# ============================================================
# WeChat auto-login script (zero third-party dependency)
# Flow: start WeChat -> wait for login window -> activate ->
#       real mouse input click "Enter WeChat" -> main window.
# Button located by RELATIVE % of render window -> works on
# any screen resolution and DPI scaling.
# ============================================================
param(
    [string]$WeChatExe = "{WECHAT_EXE}",
    [string]$WeChatDir = "{WECHAT_DIR}",
    [int]$TimeoutSec  = 30,
    [double]$BtnX     = 0.498,
    [double]$BtnY     = 0.773
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
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
}
"@
[WxApi]::SetProcessDPIAware() | Out-Null

$LEFTDOWN = 0x0002
$LEFTUP   = 0x0004
$deadline = [DateTime]::Now.AddSeconds($TimeoutSec)

if (-not (Get-Process -Name "Weixin" -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $WeChatExe)) {
        Write-Host "WeChat not found: $WeChatExe (skip auto-login)"
        exit 0
    }
    Start-Process -FilePath $WeChatExe -WorkingDirectory $WeChatDir
    Start-Sleep -Milliseconds 800
}

Write-Host "Waiting for WeChat window..."
$script:target = [IntPtr]::Zero
$script:render = [IntPtr]::Zero
while ([DateTime]::Now -lt $deadline) {
    $script:target = [IntPtr]::Zero
    $script:render = [IntPtr]::Zero
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
        if ($script:fr -ne [IntPtr]::Zero) { $script:target = $h; $script:render = $script:fr; return $false }
        return $true
    }
    [WxApi]::EnumWindows($cb,[IntPtr]::Zero) | Out-Null
    if ($script:target -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 250
}

$win = $script:target
if ($win -eq [IntPtr]::Zero) {
    Write-Host "No WeChat window found in ${TimeoutSec}s (already logged in? skip)."
    exit 0
}

$ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(16)
[WxApi]::GetWindowRect($script:render, $ptr) | Out-Null
$L = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr,0)
$T = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr,4)
$R = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr,8)
$B = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr,12)
[System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)

$w = $R - $L
$h = $B - $T
if ($h -le $w) {
    Write-Host "Main window detected, no click needed."
    exit 0
}
Write-Host "Login window detected, clicking Enter-WeChat..."

[WxApi]::SetForegroundWindow($win) | Out-Null
Start-Sleep -Milliseconds 300

$x = $L + [int]($w * $BtnX)
$y = $T + [int]($h * $BtnY)
Write-Host "Button at ($x,$y)"

[WxApi]::SetCursorPos($x, $y) | Out-Null
Start-Sleep -Milliseconds 80
[WxApi]::mouse_event($LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 40
[WxApi]::mouse_event($LEFTUP, 0, 0, 0, [UIntPtr]::Zero)

Write-Host "Clicked. Done."
Start-Sleep -Milliseconds 1000
'@

$mainContent = $mainContent.Replace('{WECHAT_EXE}', $wxExe)
$mainContent = $mainContent.Replace('{WECHAT_DIR}', $wxDir)

$mainPath = Join-Path $OutDir "wechat_autologin.ps1"
[System.IO.File]::WriteAllText($mainPath, $mainContent, (New-Object System.Text.UTF8Encoding $false))
Write-Host "[OK] Wrote: $mainPath"

# ---------- 4) Configure autostart ----------
$startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell

$l1 = $ws.CreateShortcut((Join-Path $startup "WeChat.lnk"))
$l1.TargetPath  = $wxExe
$l1.Description = "Start WeChat"
$l1.Save()

$l2 = $ws.CreateShortcut((Join-Path $startup "WeChatAutoLogin.lnk"))
$l2.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$l2.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mainPath`""
$l2.Description = "WeChat auto-login"
$l2.Save()

Write-Host "[OK] Autostart configured:"
Write-Host "     WeChat.lnk          -> $wxExe"
Write-Host "     WeChatAutoLogin.lnk -> $mainPath"
Write-Host ""
Write-Host "Done. On next login WeChat starts and auto-logs-in."
Write-Host "Tip: enable 'Auto login on this device' in WeChat (phone) to skip confirmation."
