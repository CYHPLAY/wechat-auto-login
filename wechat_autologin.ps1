# ============================================================
# WeChat auto-login script (zero third-party dependency, PowerShell + user32)
# Flow: start WeChat -> wait for login window -> activate ->
#       real mouse input (SetCursorPos + mouse_event) click
#       the "Enter WeChat" button -> enter main window -> exit
# Design notes:
#   - Button located by RELATIVE position (% of render window),
#     so it works across different screen resolutions and DPI scaling.
#   - Pure ASCII comments (PowerShell 5.1 safe).
# Run : powershell -NoProfile -ExecutionPolicy Bypass -File wechat_autologin.ps1
#       optional: -WeChatExe "path" -BtnX 0.498 -BtnY 0.773
# ============================================================
param(
    [string]$WeChatExe = "D:\WeChat\Weixin\Weixin.exe",
    [string]$WeChatDir = "D:\WeChat\Weixin",
    [int]$TimeoutSec  = 30,
    [double]$BtnX     = 0.498,   # "Enter WeChat" button center X (fraction of render width)
    [double]$BtnY     = 0.773    # "Enter WeChat" button center Y (fraction of render height)
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

# 1) Start WeChat if not running
if (-not (Get-Process -Name "Weixin" -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $WeChatExe)) {
        Write-Host "WeChat not found: $WeChatExe (skip auto-login)"
        exit 0
    }
    Start-Process -FilePath $WeChatExe -WorkingDirectory $WeChatDir
    Start-Sleep -Milliseconds 800   # let WeChat start up
}

# 2) Wait for WeChat window (title WeChat, visible, has render child)
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

# 3) Read render window rect (login window H>W ; main window W>H)
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

# 4) Activate window
[WxApi]::SetForegroundWindow($win) | Out-Null
Start-Sleep -Milliseconds 300

# 5) Button screen pos = relative fraction of render window (resolution / DPI independent)
$x = $L + [int]($w * $BtnX)
$y = $T + [int]($h * $BtnY)
Write-Host "Button at ($x,$y)"

# 6) Real mouse input (the only reliable way for WeChat self-drawn UI)
[WxApi]::SetCursorPos($x, $y) | Out-Null
Start-Sleep -Milliseconds 80
[WxApi]::mouse_event($LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 40
[WxApi]::mouse_event($LEFTUP, 0, 0, 0, [UIntPtr]::Zero)

Write-Host "Clicked. Done."
Start-Sleep -Milliseconds 1000
# exit quietly
