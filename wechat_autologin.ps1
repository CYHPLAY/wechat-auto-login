# ============================================================
# 微信 PC 自动登录脚本（零第三方依赖 / 纯 Windows API）
# 由 setup.ps1 自动生成。
# 作用：开机后由唯一的自启快捷方式调用，自动启动微信并点击绿色
#       “进入WeChat”按钮进入主界面。
#
# 设计要点（避免开机多开 / 提速）：
#   * 幂等启动：微信进程已存在（正在开机初始化）就只等待、绝不重复拉起；
#               只有进程不存在时才启动一次。
#   * 唤起节流：进程在但无可见窗口时，先宽限一段时间，之后每隔较长时间
#               才唤起一次，避免和微信自带开机启动叠加而多开。
#   * 无固定睡眠：开机即运行，登录窗 / 绿色按钮一就绪就动作，不干等。
#   * 检测之后再点击：GetPixel 读取按钮区域像素颜色，确认绿色按钮已渲染
#               就绪才点击（不截图、不存图、不做图像匹配），通常 1 次命中。
# ============================================================

[CmdletBinding()]
param(
    [string]$WeChatExe  = "D:\WeChat\Weixin\Weixin.exe",
    [string]$WeChatDir  = "D:\WeChat\Weixin",
    [int]$WindowTimeoutSec  = 30,
    [int]$ButtonTimeoutSec  = 60,
    [double]$BtnX       = 0.498,
    [double]$BtnY       = 0.773,
    [double]$GreenRatio = 0.30,
    [int]$MaxRetries    = 5,
    [int]$MinReadyMs    = 250,
    [int]$ReviveGraceSec   = 12,
    [int]$ReviveIntervalSec = 8,
    [bool]$RestoreMouse = $true,
    [switch]$DontLaunch
)

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WxApi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, IntPtr lpRect);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr ignore);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr hdc, int nXPos, int nYPos);
}
"@

[WxApi]::SetProcessDPIAware() | Out-Null

$MOUSEEVENTF_MOVE     = 0x0001
$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP   = 0x0004
$SW_RESTORE           = 9

function Log($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss.fff"), $msg) }

function Get-WeChatPids {
    @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match '^(Weixin|WeChat)$' } |
        Select-Object -ExpandProperty Id)
}

function Get-WxRect([IntPtr]$hwnd) {
    $ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal(16)
    try {
        [void][WxApi]::GetWindowRect($hwnd, $ptr)
        $l = [Runtime.InteropServices.Marshal]::ReadInt32($ptr, 0)
        $t = [Runtime.InteropServices.Marshal]::ReadInt32($ptr, 4)
        $r = [Runtime.InteropServices.Marshal]::ReadInt32($ptr, 8)
        $b = [Runtime.InteropServices.Marshal]::ReadInt32($ptr, 12)
        return [pscustomobject]@{ L=$l; T=$t; R=$r; B=$b; W=($r-$l); H=($b-$t) }
    }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
}

$script:curTarget = [IntPtr]::Zero
$script:curRender = [IntPtr]::Zero

function Update-WxWindow {
    $script:curTarget = [IntPtr]::Zero
    $script:curRender = [IntPtr]::Zero
    $pids = Get-WeChatPids
    if ($pids.Count -eq 0) { return }

    $enumTop = [WxApi+EnumWindowsProc]{
        param($top, $lp)
        if (-not [WxApi]::IsWindowVisible($top)) { return $true }
        $procId = 0
        [void][WxApi]::GetWindowThreadProcessId($top, [ref]$procId)
        if ($pids -notcontains [int]$procId) { return $true }

        $enumChild = [WxApi+EnumWindowsProc]{
            param($child, $lp2)
            $sb = New-Object System.Text.StringBuilder 256
            [void][WxApi]::GetClassName($child, $sb, 256)
            if ($sb.ToString() -eq 'MMUIRenderSubWindowHW') {
                $script:foundRender = $child
                return $false
            }
            return $true
        }
        $script:foundRender = [IntPtr]::Zero
        [void][WxApi]::EnumChildWindows($top, $enumChild, [IntPtr]::Zero)
        if ($script:foundRender -ne [IntPtr]::Zero) {
            $rc = Get-WxRect $script:foundRender
            if ($rc.H -gt $rc.W) {
                $script:curTarget = $top
                $script:curRender = $script:foundRender
                return $false
            }
        }
        return $true
    }
    [void][WxApi]::EnumWindows($enumTop, [IntPtr]::Zero)
}

function Test-LoggedIn {
    $pids = Get-WeChatPids
    if ($pids.Count -eq 0) { return $false }
    $enumTop = [WxApi+EnumWindowsProc]{
        param($top, $lp)
        if (-not [WxApi]::IsWindowVisible($top)) { return $true }
        $procId = 0
        [void][WxApi]::GetWindowThreadProcessId($top, [ref]$procId)
        if ($pids -notcontains [int]$procId) { return $true }
        $enumChild = [WxApi+EnumWindowsProc]{
            param($child, $lp2)
            $sb = New-Object System.Text.StringBuilder 256
            [void][WxApi]::GetClassName($child, $sb, 256)
            if ($sb.ToString() -eq 'MMUIRenderSubWindowHW') {
                $rc = Get-WxRect $child
                if ($rc.W -ge $rc.H) { $script:loggedIn = $true; return $false }
            }
            return $true
        }
        $script:loggedIn = $false
        [void][WxApi]::EnumChildWindows($top, $enumChild, [IntPtr]::Zero)
        if ($script:loggedIn) { $script:hit = $true; return $false }
        return $true
    }
    $script:hit = $false
    [void][WxApi]::EnumWindows($enumTop, [IntPtr]::Zero)
    return [bool]$script:hit
}

function Test-GreenPixel([int]$cr,[int]$cg,[int]$cb) {
    return ($cg -ge 110 -and ($cg - $cr) -ge 35 -and ($cg - $cb) -ge 35)
}

function Test-ButtonReady([ref]$Info) {
    if ($script:curRender -eq [IntPtr]::Zero) { if ($Info) { $Info.Value = $null }; return $false }
    $r = Get-WxRect $script:curRender
    if ($r.W -ge $r.H) { if ($Info) { $Info.Value = $null }; return $false }

    $cx = $r.L + [int]($r.W * $BtnX)
    $cy = $r.T + [int]($r.H * $BtnY)
    $rx = [int]($r.W * 0.13)
    $ry = [int]($r.H * 0.016)

    $hdc = [WxApi]::GetDC([IntPtr]::Zero)
    try {
        $green = 0; $total = 0; $centerColor = 0
        for ($ix = -4; $ix -le 4; $ix++) {
            for ($iy = -1; $iy -le 1; $iy++) {
                $x = $cx + [int]($rx * ($ix / 4.0))
                $y = $cy + [int]($ry * $iy)
                $c = [WxApi]::GetPixel($hdc, $x, $y)
                if ($ix -eq 0 -and $iy -eq 0) { $centerColor = $c }
                $cr = $c -band 0xFF
                $cg = ($c -shr 8) -band 0xFF
                $cb = ($c -shr 16) -band 0xFF
                $total++
                if (Test-GreenPixel $cr $cg $cb) { $green++ }
            }
        }
    }
    finally { [void][WxApi]::ReleaseDC([IntPtr]::Zero, $hdc) }

    $ratio = $green / [double]$total
    if ($Info) {
        $Info.Value = [pscustomobject]@{
            Ratio = $ratio; Cx = $cx; Cy = $cy
            CenterR = ($centerColor -band 0xFF)
            CenterG = (($centerColor -shr 8) -band 0xFF)
            CenterB = (($centerColor -shr 16) -band 0xFF)
        }
    }
    return ($ratio -ge $GreenRatio)
}

function Bring-ToFront([IntPtr]$hwnd) {
    if ($hwnd -eq [IntPtr]::Zero) { return }
    [void][WxApi]::ShowWindow($hwnd, $SW_RESTORE)
    if ([WxApi]::GetForegroundWindow() -eq $hwnd) { return }
    $fg = [WxApi]::GetForegroundWindow()
    $curThread = [WxApi]::GetCurrentThreadId()
    $fgThread  = [WxApi]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
    $targetThread = [WxApi]::GetWindowThreadProcessId($hwnd, [IntPtr]::Zero)
    [void][WxApi]::AttachThreadInput($curThread, $fgThread, $true)
    [void][WxApi]::AttachThreadInput($curThread, $targetThread, $true)
    [void][WxApi]::BringWindowToTop($hwnd)
    [void][WxApi]::SetForegroundWindow($hwnd)
    [void][WxApi]::AttachThreadInput($curThread, $targetThread, $false)
    [void][WxApi]::AttachThreadInput($curThread, $fgThread, $false)
}

function Start-WeChat {
    if (Test-Path $WeChatExe) {
        Start-Process -FilePath $WeChatExe -WorkingDirectory $WeChatDir
    } else {
        Write-Host ("[{0}] WARN: 未找到微信程序 {1}" -f (Get-Date -Format "HH:mm:ss.fff"), $WeChatExe)
    }
}

$scriptStart = Get-Date

if ((Get-WeChatPids).Count -gt 0) {
    Log "WeChat already running; wait for its login window (will NOT launch again)."
} elseif ($DontLaunch) {
    Log "No WeChat process; -DontLaunch set, waiting for an external launch..."
} else {
    Log "No WeChat process; launching WeChat once..."
    Start-WeChat
}

$winDeadline = (Get-Date).AddSeconds($WindowTimeoutSec)
$lastRect = $null; $stableCount = 0; $firstSeen = $null
$loginFound = $false
$nextReviveAt = (Get-Date).AddSeconds($ReviveGraceSec)

while ((Get-Date) -lt $winDeadline) {
    Update-WxWindow
    if ($script:curRender -ne [IntPtr]::Zero) {
        if (-not $firstSeen) { $firstSeen = Get-Date }
        $r = Get-WxRect $script:curRender
        if ($lastRect -and $r.L -eq $lastRect.L -and $r.T -eq $lastRect.T -and $r.W -eq $lastRect.W -and $r.H -eq $lastRect.H) {
            $stableCount++
        } else { $stableCount = 0 }
        $lastRect = $r
        if ($stableCount -ge 2 -and ((Get-Date) - $firstSeen).TotalMilliseconds -ge $MinReadyMs) {
            $loginFound = $true; break
        }
    } else {
        if (Test-LoggedIn) { Log "already logged in. Done."; exit 0 }
        if ((Get-Date) -ge $nextReviveAt) {
            if (-not $DontLaunch) {
                if ((Get-WeChatPids).Count -eq 0) { Log "process missing, launching once..." }
                else { Log "no visible window, reviving once (throttled)..." }
                Start-WeChat
            }
            $nextReviveAt = (Get-Date).AddSeconds($ReviveIntervalSec)
        }
    }
    Start-Sleep -Milliseconds 150
}

if (-not $loginFound) {
    if (Test-LoggedIn) { Log "already logged in. Done."; exit 0 }
    Log "WARN: $WindowTimeoutSec 秒内未找到微信登录窗。"; exit 1
}
Log ("login window ready after {0} ms" -f [int]($firstSeen - $scriptStart).TotalMilliseconds)

Add-Type -AssemblyName System.Windows.Forms
$startPos = [System.Windows.Forms.Cursor]::Position

$ok = $false
for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    $diag = $null; $ready = $false
    $btnDeadline = (Get-Date).AddSeconds($ButtonTimeoutSec)
    while ((Get-Date) -lt $btnDeadline) {
        Update-WxWindow
        if ($script:curRender -eq [IntPtr]::Zero) { $ok = $true; break }
        $rr = Get-WxRect $script:curRender
        if ($rr.W -ge $rr.H) { $ok = $true; break }
        $d = $null
        if (Test-ButtonReady ([ref]$d)) { $ready = $true; $diag = $d; break }
        Start-Sleep -Milliseconds 120
    }
    if ($ok) { break }
    if (-not $ready) { Log "WARN: $ButtonTimeoutSec 秒内未检测到绿色登录按钮（按钮未就绪）。"; break }
    Log ("green login button READY (green ratio {0:P0}, center RGB {1},{2},{3})" -f $diag.Ratio, $diag.CenterR, $diag.CenterG, $diag.CenterB)

    Bring-ToFront $script:curTarget
    Start-Sleep -Milliseconds 120
    $r = Get-WxRect $script:curRender
    $x = $r.L + [int]($r.W * $BtnX)
    $y = $r.T + [int]($r.H * $BtnY)
    Log ("Click attempt {0}/{1} at ({2},{3}) size {4}x{5}" -f $attempt,$MaxRetries,$x,$y,$r.W,$r.H)

    [WxApi]::SetCursorPos($x,$y) | Out-Null
    [WxApi]::mouse_event($MOUSEEVENTF_MOVE,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [WxApi]::mouse_event($MOUSEEVENTF_LEFTDOWN,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 18
    [WxApi]::mouse_event($MOUSEEVENTF_LEFTUP,0,0,0,[UIntPtr]::Zero)

    $inDeadline = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $inDeadline) {
        Start-Sleep -Milliseconds 100
        if (Test-LoggedIn) { $ok = $true; break }
    }
    if ($ok) { break }
    Log "clicked but main UI not shown yet, re-detecting..."
}

if ($RestoreMouse) { [WxApi]::SetCursorPos($startPos.X, $startPos.Y) | Out-Null }

if ($ok) { Log "Logged in. Done."; exit 0 }
else { Log "WARN: 自动登录未完成，请手动点击登录。"; exit 1 }