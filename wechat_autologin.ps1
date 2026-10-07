# ============================================================
# 微信自动登录脚本（改进版，UTF-8 带 BOM）
# ------------------------------------------------------------
# 特性：
#   1. 不依赖窗口标题语言——按“微信进程 + 自绘渲染子窗
#      (MMUIRenderSubWindowHW)”定位，中文“微信”/英文“WeChat”通吃。
#   2. 微信关闭窗口后进程会驻留托盘、没有可见窗口；脚本检测到这种
#      情况会再次运行 exe 把窗口唤出（单实例，不会多开）。
#   3. 事件驱动：登录窗一出现就点，检测到进入主界面立即退出，不傻等。
#   4. 点击后校验是否真的进入主界面，没进就重试（默认 3 次）。
#   5. 登录完成后把鼠标移回点击前的位置（-RestoreMouse 可关）。
# 零第三方依赖，仅用 Windows 自带 user32 API。
# ============================================================
param(
    [string]$WeChatExe  = "D:\WeChat\Weixin\Weixin.exe",  # 微信主程序路径（setup.ps1 会自动填）
    [string]$WeChatDir  = "D:\WeChat\Weixin",             # 微信工作目录
    [int]$TimeoutSec    = 30,        # 等待登录窗出现的最长秒数
    [double]$BtnX       = 0.498,     # 登录按钮在渲染窗内的横向比例
    [double]$BtnY       = 0.773,     # 登录按钮在渲染窗内的纵向比例
    [int]$MaxRetries    = 3,         # 点击失败后的最大重试次数
    [bool]$RestoreMouse = $true      # 登录后把鼠标归位
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
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public struct POINT { public int X; public int Y; }
}
"@
[WxApi]::SetProcessDPIAware() | Out-Null

$LEFTDOWN = 0x0002
$LEFTUP   = 0x0004

function Log([string]$msg){ Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $msg) }

# 取所有微信相关进程的 PID（新版进程名为 Weixin，兼容旧版 WeChat）
function Get-WxPids {
    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($n in @('Weixin','WeChat')) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $ids.Contains($_.Id)) { $ids.Add($_.Id) }
        }
    }
    return ,$ids
}

# 枚举顶层窗口，找到“属于微信进程、可见、且含自绘渲染子窗”的那个。
# 不依赖窗口标题，避免中文“微信”/英文“WeChat”差异导致找不到。
function Update-WxWindow {
    $script:curTarget = [IntPtr]::Zero
    $script:curRender = [IntPtr]::Zero
    $script:wxPids = Get-WxPids
    $cb = [WxApi+EnumProc]{
        param($h,$l)
        if (-not [WxApi]::IsWindowVisible($h)) { return $true }
        $procId = 0
        [WxApi]::GetWindowThreadProcessId($h,[ref]$procId) | Out-Null
        if ($script:wxPids -notcontains [int]$procId) { return $true }
        $script:fr = [IntPtr]::Zero
        $ccb = [WxApi+ChildProc]{
            param($ch,$cl)
            $cn = New-Object System.Text.StringBuilder 256
            [WxApi]::GetClassName($ch,$cn,256) | Out-Null
            if ($cn.ToString() -eq 'MMUIRenderSubWindowHW') { $script:fr = $ch; return $false }
            return $true
        }
        [WxApi]::EnumChildWindows($h,$ccb,[IntPtr]::Zero) | Out-Null
        if ($script:fr -ne [IntPtr]::Zero) {
            $script:curTarget = $h
            $script:curRender = $script:fr
            return $false
        }
        return $true
    }
    [WxApi]::EnumWindows($cb,[IntPtr]::Zero) | Out-Null
}

# 用非托管内存读 RECT（PS 5.1 下用 [ref] 接结构体可能静默返回全 0）
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

# 是否已进入主界面：没有渲染窗（视为已就绪）或渲染窗为横版（宽>=高）
function Test-LoggedIn {
    Update-WxWindow
    if ($script:curRender -eq [IntPtr]::Zero) { return $true }
    $r = Get-WxRect $script:curRender
    return ($r.W -ge $r.H)
}

# 启动 / 唤起微信。单实例程序：已驻留托盘时再次运行 exe 只会唤出窗口，不会多开。
function Invoke-WxStart {
    if (-not (Test-Path $WeChatExe)) { Log "WeChat exe not found: $WeChatExe (skip)"; exit 0 }
    Start-Process -FilePath $WeChatExe -WorkingDirectory $WeChatDir
}

Update-WxWindow
if ($script:curRender -eq [IntPtr]::Zero) {
    Log "launch / activate WeChat..."
    Invoke-WxStart
} else {
    Log "WeChat window already visible."
}

# 等待登录窗（竖版）出现；窗口迟迟不出现就周期性重新唤起（冷启动慢 / 驻留托盘）
$deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
$lastRelaunch = [DateTime]::Now
$loginFound = $false
while ([DateTime]::Now -lt $deadline) {
    Update-WxWindow
    if ($script:curRender -ne [IntPtr]::Zero) {
        $r0 = Get-WxRect $script:curRender
        if ($r0.H -gt $r0.W) { $loginFound = $true; break }   # 竖版 = 登录窗
        if ($r0.W -ge $r0.H) { Log "Already in main window, nothing to click."; exit 0 }  # 横版 = 主界面
    } else {
        if (([DateTime]::Now - $lastRelaunch).TotalSeconds -ge 5) {
            Log "no visible window yet, re-activating WeChat..."
            Invoke-WxStart
            $lastRelaunch = [DateTime]::Now
        }
    }
    Start-Sleep -Milliseconds 150
}
if (-not $loginFound) { Log "No login window within ${TimeoutSec}s (already logged in?). skip."; exit 0 }

# 保存当前鼠标位置，登录后归位
$saved = New-Object 'WxApi+POINT'
[WxApi]::GetCursorPos([ref]$saved) | Out-Null

$ok = $false
for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    if (Test-LoggedIn) { $ok = $true; break }
    if ($script:curRender -eq [IntPtr]::Zero) { $ok = $true; break }

    [WxApi]::SetForegroundWindow($script:curTarget) | Out-Null
    Start-Sleep -Milliseconds 150

    # 每次点击前重新读取窗口矩形，保证窗口移动/缩放后坐标准确
    $r = Get-WxRect $script:curRender
    $x = $r.L + [int]($r.W * $BtnX)
    $y = $r.T + [int]($r.H * $BtnY)
    Log ("Click attempt {0}/{1} at ({2},{3}) size {4}x{5}" -f $attempt,$MaxRetries,$x,$y,$r.W,$r.H)

    [WxApi]::SetCursorPos($x,$y) | Out-Null
    Start-Sleep -Milliseconds 60
    [WxApi]::mouse_event($LEFTDOWN,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
    [WxApi]::mouse_event($LEFTUP,0,0,0,[UIntPtr]::Zero)

    # 点击后最多等 2.5 秒，确认竖版登录窗是否已变成横版主界面
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
