#requires -Version 5.1
# WeChat PC auto-login for the MMUIRenderSubWindowHW renderer (typically Weixin 4.x).
# Interactive unlocked desktop and prior mobile authorization are required.
# Only one script instance per session; an existing WeChat process is never relaunched.
# Success means a stable, supported main-window shape, not verified server authentication.
# See README.md for compatibility, logs and recovery instructions.
[CmdletBinding()]
param(
    [string]$WeChatExe  = "",
    [string]$WeChatDir  = "",
    [ValidateRange(1,120)][int]$WindowTimeoutSec  = 30,
    [ValidateRange(1,120)][int]$ButtonTimeoutSec  = 60,
    [ValidateRange(0.01,0.99)][double]$BtnX       = 0.498,
    [ValidateRange(0.01,0.99)][double]$BtnY       = 0.773,
    [ValidateRange(0.01,1.0)][double]$GreenRatio = 0.30,
    [ValidateRange(1,10)][int]$MaxRetries    = 5,
    [ValidateRange(0,10000)][int]$MinReadyMs    = 250,
    [ValidateRange(0,120)][int]$ReviveGraceSec   = 12,
    [ValidateRange(1,120)][int]$ReviveIntervalSec = 8,
    [bool]$RestoreMouse = $true,
    [switch]$DontLaunch,
    [ValidateRange(1,120)][int]$LoginTimeoutSec = 30,
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'WeChatAutoLogin\autologin.log')
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'wechat_common.ps1')

$SW_RESTORE = 9

function Initialize-WxApi {
    if (-not ('WxApi' -as [type])) {
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WxApi {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; public POINT(int x, int y) { X=x; Y=y; } }
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder info, int length, out uint needed);
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
    }
    try {
        if (-not [WxApi]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [void][WxApi]::SetProcessDPIAware() }
    } catch { [void][WxApi]::SetProcessDPIAware() }
    Add-Type -AssemblyName System.Windows.Forms
}

function Log($msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $msg
    Write-Host $line
    try {
        $parent = Split-Path $LogPath -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) { Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.1') -Force }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { Write-Warning "Could not write log: $_" }
}

function Get-WxRect([IntPtr]$hwnd) {
    if (-not [WxApi]::IsWindow($hwnd)) { return $null }
    $ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal(16)
    try {
        if (-not [WxApi]::GetWindowRect($hwnd, $ptr)) { return $null }
        $l = [Runtime.InteropServices.Marshal]::ReadInt32($ptr, 0)
        $t = [Runtime.InteropServices.Marshal]::ReadInt32($ptr, 4)
        $r = [Runtime.InteropServices.Marshal]::ReadInt32($ptr, 8)
        $b = [Runtime.InteropServices.Marshal]::ReadInt32($ptr, 12)
        return [pscustomobject]@{ L=$l; T=$t; R=$r; B=$b; W=($r-$l); H=($b-$t) }
    }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
}

function Update-WxWindow {
    $script:curTarget = [IntPtr]::Zero
    $script:curRender = [IntPtr]::Zero
    $pids = Get-WeChatPids
    if (@($pids).Count -eq 0) { return }

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
            if ($rc -and $rc.W -ge 200 -and $rc.H -gt $rc.W) {
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
    if (@($pids).Count -eq 0) { return $false }
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
                if ($rc -and $rc.W -ge 500 -and $rc.H -ge 300 -and $rc.W -gt $rc.H) { $script:loggedIn = $true; return $false }
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
    if ([WxApi]::GetForegroundWindow() -ne $script:curTarget) { return $false }
    $r = Get-WxRect $script:curRender
    if (-not $r -or $r.W -ge $r.H) { if ($Info) { $Info.Value = $null }; return $false }
    if (-not (Test-InteractiveDesktop)) { return $false }

    $cx = $r.L + [int]($r.W * $BtnX)
    $cy = $r.T + [int]($r.H * $BtnY)
    $rx = [int]($r.W * 0.13)
    $ry = [int]($r.H * 0.016)

    $hdc = [WxApi]::GetDC([IntPtr]::Zero)
    if ($hdc -eq [IntPtr]::Zero) { return $false }
    try {
        $green = 0; $total = 0; $centerColor = 0
        for ($ix = -4; $ix -le 4; $ix++) {
            for ($iy = -1; $iy -le 1; $iy++) {
                $x = $cx + [int]($rx * ($ix / 4.0))
                $y = $cy + [int]($ry * $iy)
                if (-not (Test-PointOwnedByWeChat $x $y)) { return $false }
                $c = [WxApi]::GetPixel($hdc, $x, $y)
                if ($c -eq [uint32]::MaxValue) { return $false }
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

function Test-InteractiveDesktop {
    $desktop = [WxApi]::OpenInputDesktop(0, $false, 1)
    if ($desktop -eq [IntPtr]::Zero) { return $false }
    try {
        $name = New-Object Text.StringBuilder 256
        [uint32]$needed = 0
        return ([WxApi]::GetUserObjectInformation($desktop, 2, $name, 512, [ref]$needed) -and $name.ToString() -eq 'Default')
    } finally { [void][WxApi]::CloseDesktop($desktop) }
}

function Test-PointOwnedByWeChat([int]$X, [int]$Y) {
    $point = New-Object WxApi+POINT($X, $Y)
    $window = [WxApi]::WindowFromPoint($point)
    return ($window -ne [IntPtr]::Zero -and [WxApi]::GetAncestor($window, 2) -eq $script:curTarget)
}

function Test-LoginConfirmed {
    for ($sample = 0; $sample -lt 3; $sample++) {
        if (-not (Test-LoggedIn)) { return $false }
        Update-WxWindow
        if ($script:curRender -ne [IntPtr]::Zero) { return $false }
        if ($sample -lt 2) { Start-Sleep -Milliseconds 150 }
    }
    return $true
}

function Bring-ToFront([IntPtr]$hwnd) {
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    [void][WxApi]::ShowWindow($hwnd, $SW_RESTORE)
    if ([WxApi]::GetForegroundWindow() -eq $hwnd) { return $true }
    $fg = [WxApi]::GetForegroundWindow()
    $curThread = [WxApi]::GetCurrentThreadId()
    $fgThread  = [WxApi]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
    $targetThread = [WxApi]::GetWindowThreadProcessId($hwnd, [IntPtr]::Zero)
    $attachedFg = $false; $attachedTarget = $false
    try {
        if ($fgThread -ne 0 -and $fgThread -ne $curThread) { $attachedFg = [WxApi]::AttachThreadInput($curThread, $fgThread, $true) }
        if ($targetThread -ne 0 -and $targetThread -ne $curThread -and $targetThread -ne $fgThread) { $attachedTarget = [WxApi]::AttachThreadInput($curThread, $targetThread, $true) }
        [void][WxApi]::BringWindowToTop($hwnd)
        [void][WxApi]::SetForegroundWindow($hwnd)
    } finally {
        if ($attachedTarget) { [void][WxApi]::AttachThreadInput($curThread, $targetThread, $false) }
        if ($attachedFg) { [void][WxApi]::AttachThreadInput($curThread, $fgThread, $false) }
    }
    return ([WxApi]::GetForegroundWindow() -eq $hwnd)
}

function Start-WeChat {
    if (@(Get-WeChatPids).Count -gt 0) { Log 'WeChat is already running; not launching another process.'; return }
    $exe = Resolve-WeChatExe $WeChatExe
    $dir = $WeChatDir
    if (-not $dir) { $dir = Split-Path $exe -Parent }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw 'WeChatDir must be an existing directory.' }
    Log "Launching WeChat: $exe"
    Start-Process -FilePath $exe -WorkingDirectory $dir | Out-Null
}

function Get-WeChatPids { @(Get-WeChatProcesses | Select-Object -ExpandProperty Id) }

function Invoke-WeChatClick {
    if (-not (Bring-ToFront $script:curTarget)) { return $false }
    Start-Sleep -Milliseconds 120
    Update-WxWindow
    $info = $null
    if (-not (Test-ButtonReady ([ref]$info))) { return $false }
    $x = $info.Cx; $y = $info.Cy
    if ([WxApi]::GetForegroundWindow() -ne $script:curTarget -or
        -not (Test-InteractiveDesktop) -or -not (Test-PointOwnedByWeChat $x $y)) { return $false }
    $position = [System.Windows.Forms.Cursor]::Position
    $moved = $false; $buttonDown = $false
    try {
        if (-not [WxApi]::SetCursorPos($x,$y)) { throw 'Could not move cursor; refusing to click.' }
        $moved = $true
        $current = [System.Windows.Forms.Cursor]::Position
        if ($current.X -ne $x -or $current.Y -ne $y -or
            [WxApi]::GetForegroundWindow() -ne $script:curTarget -or
            -not (Test-InteractiveDesktop) -or -not (Test-PointOwnedByWeChat $x $y)) { return $false }
        $finalInfo = $null
        if (-not (Test-ButtonReady ([ref]$finalInfo)) -or $finalInfo.Cx -ne $x -or $finalInfo.Cy -ne $y) { return $false }
        Log "Clicking supported login button at ($x,$y)."
        $buttonDown = $true
        [WxApi]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero)
        Start-Sleep -Milliseconds 18
        [WxApi]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
        $buttonDown = $false
        return $true
    } finally {
        if ($buttonDown) { [WxApi]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero) }
        if ($moved -and $RestoreMouse) { [void][WxApi]::SetCursorPos($position.X,$position.Y) }
    }
}

function Invoke-WeChatAutoLogin {
    $scriptStart = Get-Date
    $totalDeadline = $scriptStart.AddSeconds(270)
    $launched = $false
    Log 'Auto-login started (interactive unlocked desktop required).'
    if (@(Get-WeChatPids).Count -gt 0) {
        Log 'WeChat already running; waiting without relaunching.'
    } elseif ($DontLaunch) {
        Log 'DontLaunch enabled; waiting for external launch.'
    } else {
        Start-WeChat
        $launched = $true
    }
    $winDeadline = (Get-Date).AddSeconds($WindowTimeoutSec)
    $lastRect = $null; $stableCount = 0; $firstSeen = $null
    $loginFound = $false
    $nextCheckAt = (Get-Date).AddSeconds($ReviveGraceSec)
    while ((Get-Date) -lt $winDeadline) {
        if (Test-LoginConfirmed) { Log 'Supported main window already visible. Done.'; return 0 }
        Update-WxWindow
        if ($script:curRender -ne [IntPtr]::Zero) {
            $rect = Get-WxRect $script:curRender
            if ($rect -and $lastRect -and $rect.L -eq $lastRect.L -and $rect.T -eq $lastRect.T -and
                $rect.W -eq $lastRect.W -and $rect.H -eq $lastRect.H) { $stableCount++ }
            else { $stableCount = 0; $firstSeen = Get-Date }
            $lastRect = $rect
            if ($rect -and $stableCount -ge 2 -and ((Get-Date)-$firstSeen).TotalMilliseconds -ge $MinReadyMs) { $loginFound = $true; break }
        } else {
            $lastRect=$null; $stableCount=0; $firstSeen=$null
            if ((Get-Date) -ge $nextCheckAt -and -not $DontLaunch) {
                if (@(Get-WeChatPids).Count -eq 0) {
                    if ($launched) { throw 'WeChat exited while waiting for its login window.' }
                    Start-WeChat
                    $launched = $true
                }
                $nextCheckAt = (Get-Date).AddSeconds($ReviveIntervalSec)
            }
        }
        Start-Sleep -Milliseconds 150
    }
    if (-not $loginFound) {
        if (Test-LoginConfirmed) { Log 'Supported main window visible. Done.'; return 0 }
        Log "WARN: No supported login window within $WindowTimeoutSec seconds. Check WeChat version and desktop/session state."
        return 1
    }
    Log 'Supported login window is stable; waiting for its green button.'
    for ($attempt=1; $attempt -le $MaxRetries -and (Get-Date) -lt $totalDeadline; $attempt++) {
        $ready = $false
        $buttonDeadline = (Get-Date).AddSeconds($ButtonTimeoutSec)
        while ((Get-Date) -lt $buttonDeadline -and (Get-Date) -lt $totalDeadline) {
            if (Test-LoginConfirmed) { Log 'Supported main window confirmed. Done.'; return 0 }
            if (@(Get-WeChatPids).Count -eq 0) { throw 'WeChat exited before login completed.' }
            Update-WxWindow
            if ($script:curRender -ne [IntPtr]::Zero -and (Test-InteractiveDesktop) -and (Bring-ToFront $script:curTarget)) {
                Start-Sleep -Milliseconds 120
                $info = $null
                if (Test-ButtonReady ([ref]$info)) { $ready=$true; break }
            }
            Start-Sleep -Milliseconds 150
        }
        if (-not $ready) { Log "WARN: Login button not ready/visible within $ButtonTimeoutSec seconds."; return 1 }
        Log "Login attempt $attempt/$MaxRetries (green ratio $($info.Ratio))."
        if (-not (Invoke-WeChatClick)) { Log 'Window/button changed or activation failed; click skipped.'; continue }
        $loginDeadline = (Get-Date).AddSeconds($LoginTimeoutSec)
        while ((Get-Date) -lt $loginDeadline -and (Get-Date) -lt $totalDeadline) {
            if (Test-LoginConfirmed) { Log 'Supported main window confirmed. Done.'; return 0 }
            if (@(Get-WeChatPids).Count -eq 0) { throw 'WeChat exited after the click.' }
            Start-Sleep -Milliseconds 150
        }
        Log 'Main window not confirmed yet; rechecking the login button.'
    }
    if (Test-LoginConfirmed) { Log 'Supported main window confirmed. Done.'; return 0 }
    Log 'WARN: Auto-login not completed. Please log in manually; see README.md for troubleshooting.'
    return 1
}

$mutex=$null; $ownsMutex=$false
try {
    $sid=(Get-WeChatIdentity).User.Value
    $mutex=New-Object Threading.Mutex($false, "Local\WeChatAutoLogin.$sid")
    try { $ownsMutex=$mutex.WaitOne(0,$false) } catch [Threading.AbandonedMutexException] { $ownsMutex=$true }
    if (-not $ownsMutex) { Write-Host 'Another auto-login instance is running; exiting.'; exit 0 }
    Initialize-WxApi
    $script:curTarget=[IntPtr]::Zero; $script:curRender=[IntPtr]::Zero
    exit (Invoke-WeChatAutoLogin)
} catch { Log "ERROR: $_"; exit 1 }
finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
