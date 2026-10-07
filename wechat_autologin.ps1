# ============================================================
# 微信 PC 自动登录脚本（零第三方依赖 / 纯 Windows API）
# 作用：开机自启微信后，自动点击绿色“进入WeChat”按钮进入主界面。
#
# 核心流程：
#   1) 启动（或唤起）微信；
#   2) 按“微信进程 + 渲染子窗(MMUIRenderSubWindowHW)”定位竖版登录窗
#      —— 不依赖窗口标题语言（中文“微信”/英文“WeChat”都能识别）；
#   3) 【检测之后再点击】只读按钮区域的像素颜色（GetPixel 单点取色，
#      不截图、不保存图片、不做图像匹配），确认绿色按钮已真正渲染就绪；
#   4) 按钮变绿后，把鼠标移到按钮上点一下；检测阶段不移动鼠标、不空点；
#   5) 检测到渲染窗变成横版主界面即成功，并把鼠标移回原位。
#
# 说明：微信界面为自绘 UI，系统里没有标准按钮句柄、也查不到按钮的
#       “可点”状态；绿色按钮出现是它完成本地/网络初始化、可以点击的
#       最直接信号，所以用“取色检测到绿”作为点击前提。
# 兼容：不同分辨率 / DPI / 微信安装位置，按钮位置按窗口比例计算。
# ============================================================

[CmdletBinding()]
param(
    [string]$WeChatExe  = "D:\WeChat\Weixin\Weixin.exe",   # 微信程序路径
    [string]$WeChatDir  = "D:\WeChat\Weixin",              # 微信工作目录
    [int]$TimeoutSec    = 30,                              # 等待登录窗/按钮的总超时（秒）
    [double]$BtnX       = 0.498,                           # 按钮中心在渲染窗宽度上的比例
    [double]$BtnY       = 0.773,                           # 按钮中心在渲染窗高度上的比例
    [double]$GreenRatio = 0.30,                            # 采样点中绿色像素达到该比例即判定按钮就绪
    [int]$MaxRetries    = 5,                               # 检测到绿并点击后，若没进入的最多补点次数
    [int]$MinReadyMs    = 250,                             # 登录窗矩形稳定后至少等多久再开始取色（毫秒）
    [bool]$RestoreMouse = $true                            # 登录完成后是否把鼠标移回原位
)

$ErrorActionPreference = "Stop"

# ---------- Win32 API ----------
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
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);   // 传 IntPtr.Zero 取整个屏幕 DC
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr hdc, int nXPos, int nYPos);
}
"@

[WxApi]::SetProcessDPIAware() | Out-Null

# 鼠标事件常量
$MOUSEEVENTF_MOVE     = 0x0001
$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP   = 0x0004
$SW_RESTORE           = 9

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss.fff"), $msg
    Write-Host $line
}

# 取微信相关进程 PID（新版进程名为 Weixin，兼容旧版 WeChat）
function Get-WeChatPids {
    @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match '^(Weixin|WeChat)$' } |
        Select-Object -ExpandProperty Id)
}

# 用 AllocHGlobal 方式取窗口矩形（PS 5.1 下用 [ref] 接 RECT 会静默返回全 0）
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

# 全局：当前竖版登录窗及其渲染子窗（每次扫描刷新）
$script:curTarget = [IntPtr]::Zero
$script:curRender = [IntPtr]::Zero

# 枚举属于微信进程、可见、且含 MMUIRenderSubWindowHW 渲染子窗的顶层窗；
# 只取竖版（高>宽），即登录窗；横版主界面在 Test-LoggedIn 单独判断。
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

        $render = [IntPtr]::Zero
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

# 是否已经进入横版主界面（存在属于微信进程的横版渲染窗，宽>=高）
function Test-LoggedIn {
    $pids = Get-WeChatPids
    if ($pids.Count -eq 0) { return $false }
    $hit = $false
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

# 判断一个 RGB 是否为“微信绿”（绿色分量明显高于红/蓝，容忍版本色差）
function Test-GreenPixel([int]$cr,[int]$cg,[int]$cb) {
    return ($cg -ge 110 -and ($cg - $cr) -ge 35 -and ($cg - $cb) -ge 35)
}

# 【就绪检测】在按钮区域取一小簇像素（9x3），统计绿色占比。
# 只 GetPixel 读颜色，不移动鼠标、不截图、不保存图片。
# 用 [ref]$Info 回传诊断信息（绿色比例、中心点坐标/颜色）。
function Test-ButtonReady([ref]$Info) {
    if ($script:curRender -eq [IntPtr]::Zero) {
        if ($Info) { $Info.Value = $null }
        return $false
    }
    $r = Get-WxRect $script:curRender
    if ($r.W -ge $r.H) {          # 已横版=主界面，无需再点
        if ($Info) { $Info.Value = $null }
        return $false
    }

    $cx = $r.L + [int]($r.W * $BtnX)
    $cy = $r.T + [int]($r.H * $BtnY)
    $rx = [int]($r.W * 0.13)      # 采样半宽（落在按钮内部，避开按钮外区域）
    $ry = [int]($r.H * 0.016)     # 采样半高（避开按钮外区域）

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

# 强制把窗口拉到前台（自绘界面的真实点击需要窗口在前台）
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

# 唤起微信（无可见登录窗时调用；微信是单实例，重复启动只会唤起原实例不会多开）
function Start-WeChat {
    if (Test-Path $WeChatExe) {
        Start-Process -FilePath $WeChatExe -WorkingDirectory $WeChatDir
    }
    else {
        Log "WARN: 未找到微信程序 $WeChatExe"
    }
}

# ====================== 主流程 ======================
$scriptStart = Get-Date
Log "launch / activate WeChat..."
Start-WeChat

# 1) 等待竖版登录窗出现，并要求矩形连续 3 次稳定 + 至少就绪 MinReadyMs
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$lastRect = $null
$stableCount = 0
$firstSeen = $null
$loginFound = $false
$appearAt = Get-Date

while ((Get-Date) -lt $deadline) {
    Update-WxWindow
    if ($script:curRender -ne [IntPtr]::Zero) {
        if (-not $firstSeen) { $firstSeen = Get-Date }
        $r = Get-WxRect $script:curRender
        if ($lastRect -and $r.L -eq $lastRect.L -and $r.T -eq $lastRect.T -and $r.W -eq $lastRect.W -and $r.H -eq $lastRect.H) {
            $stableCount++
        } else { $stableCount = 0 }
        $lastRect = $r
        if ($stableCount -ge 2 -and ((Get-Date) - $firstSeen).TotalMilliseconds -ge $MinReadyMs) {
            $loginFound = $true
            break
        }
    } else {
        # 进程在但没有可见窗口（关窗后驻留托盘）：周期性重新唤起
        if (((Get-Date) - $appearAt).TotalSeconds -ge 5) {
            Log "no visible window, re-activating..."
            Start-WeChat
            $appearAt = Get-Date
        }
    }
    Start-Sleep -Milliseconds 60
}

if (-not $loginFound) {
    if (Test-LoggedIn) {
        Log "already logged in. Done."
        exit 0
    }
    Log "WARN: $TimeoutSec 秒内未找到微信登录窗。"
    exit 1
}

Log ("login window ready after {0} ms" -f [int]($firstSeen - $scriptStart).TotalMilliseconds)

# 记录当前鼠标位置，结束后归位
Add-Type -AssemblyName System.Windows.Forms
$startPos = [System.Windows.Forms.Cursor]::Position

$ok = $false
for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    # 2) 【检测】轮询取色，等绿色按钮真正渲染就绪（这段时间鼠标完全不动、不点击）
    $diag = $null; $ready = $false
    $btnDeadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $btnDeadline) {
        Update-WxWindow
        if ($script:curRender -eq [IntPtr]::Zero) { $ok = $true; break }   # 登录窗消失=已进入
        $rr = Get-WxRect $script:curRender
        if ($rr.W -ge $rr.H) { $ok = $true; break }                        # 已横版=主界面
        $d = $null
        if (Test-ButtonReady ([ref]$d)) { $ready = $true; $diag = $d; break }
        Start-Sleep -Milliseconds 120
    }
    if ($ok) { break }
    if (-not $ready) {
        Log "WARN: $TimeoutSec 秒内未检测到绿色登录按钮（按钮未就绪）。"
        break
    }
    Log ("green login button READY (green ratio {0:P0}, center RGB {1},{2},{3})" -f `
        $diag.Ratio, $diag.CenterR, $diag.CenterG, $diag.CenterB)

    # 3) 【点击】按钮已就绪，置前后点一下
    Bring-ToFront $script:curTarget
    Start-Sleep -Milliseconds 120
    $r = Get-WxRect $script:curRender
    $x = $r.L + [int]($r.W * $BtnX)
    $y = $r.T + [int]($r.H * $BtnY)
    Log ("Click attempt {0}/{1} at ({2},{3}) size {4}x{5}" -f $attempt,$MaxRetries,$x,$y,$r.W,$r.H)

    [WxApi]::SetCursorPos($x,$y) | Out-Null
    [WxApi]::mouse_event($MOUSEEVENTF_MOVE,0,0,0,[UIntPtr]::Zero)   # 产生一次 hover
    Start-Sleep -Milliseconds 60
    [WxApi]::mouse_event($MOUSEEVENTF_LEFTDOWN,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 18
    [WxApi]::mouse_event($MOUSEEVENTF_LEFTUP,0,0,0,[UIntPtr]::Zero)

    # 4) 等待进入横版主界面（最多 4 秒）；进入即成功，否则回到上面重新检测再点
    $inDeadline = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $inDeadline) {
        Start-Sleep -Milliseconds 100
        if (Test-LoggedIn) { $ok = $true; break }
    }
    if ($ok) { break }
    Log "clicked but main UI not shown yet, re-detecting..."
}

# 鼠标归位
if ($RestoreMouse) {
    [WxApi]::SetCursorPos($startPos.X, $startPos.Y) | Out-Null
}

if ($ok) {
    Log "Logged in. Done."
    exit 0
} else {
    Log "WARN: 自动登录未完成，请手动点击登录。"
    exit 1
}
