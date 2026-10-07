# ============================================================
# 微信自动登录脚本（wechat_autologin.ps1）—— 改进版
# ------------------------------------------------------------
# 功能流程：
#   1. 启动微信（若未运行）
#   2. 快速轮询等待微信【登录窗口】出现（事件驱动，不做固定长等待）
#   3. 记住当前鼠标位置
#   4. 激活窗口，用【相对比例】定位"进入WeChat"并真实鼠标点击
#   5. 点击后轮询校验是否进入主界面（竖版登录窗 -> 横版主界面）
#      未进入则自动重新点击，最多 MaxRetries 次
#   6. 登录完成后把鼠标【移回原位】，减少对操作的打扰
# 特性：
#   - 更快：窗口一出现就点、确认进入主界面立即退出
#   - 按钮用窗口内相对比例定位，适配任意分辨率 / DPI
#   - 零第三方依赖：仅 PowerShell + Windows user32 API
# 运行：
#   powershell -NoProfile -ExecutionPolicy Bypass -File wechat_autologin.ps1
# 编码：本文件含中文注释，请用 UTF-8（带 BOM）保存（setup.ps1 会自动带 BOM 生成）
# ============================================================
param(
    [string]$WeChatExe   = "D:\WeChat\Weixin\Weixin.exe",  # 微信程序路径
    [string]$WeChatDir   = "D:\WeChat\Weixin",             # 微信工作目录
    [int]$TimeoutSec     = 30,    # 等待登录窗口超时（秒）
    [double]$BtnX        = 0.498, # "进入WeChat"按钮中心 X 比例
    [double]$BtnY        = 0.773, # "进入WeChat"按钮中心 Y 比例
    [int]$MaxRetries     = 3,     # 点击失败时的最大尝试次数
    [bool]$RestoreMouse  = $true  # 登录完成后是否把鼠标移回原位
)
$ErrorActionPreference = 'Stop'

# ---------- 导入 Windows user32 原生 API（零依赖） ----------
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
[WxApi]::SetProcessDPIAware() | Out-Null   # DPI 感知：按物理像素工作

$LEFTDOWN = 0x0002   # 鼠标左键按下
$LEFTUP   = 0x0004   # 鼠标左键抬起

# 带毫秒时间戳的日志
function Log([string]$msg){ Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $msg) }

# 枚举微信窗口，结果写入 $script:curTarget（主窗口）/ $script:curRender（渲染子窗口）
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

# 读取窗口矩形（指针方式，兼容 PS5.1），返回 坐标 + 宽高
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

# 是否已进入主界面：渲染窗不存在，或 宽>=高（横版=主界面；竖版=登录窗）
function Test-LoggedIn {
    Update-WxWindow
    if ($script:curRender -eq [IntPtr]::Zero) { return $true }
    $r = Get-WxRect $script:curRender
    return ($r.W -ge $r.H)
}

# ---------- 1) 启动微信（若未运行） ----------
if (-not (Get-Process -Name "Weixin" -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $WeChatExe)) { Log "WeChat not found: $WeChatExe (skip)"; exit 0 }
    Start-Process -FilePath $WeChatExe -WorkingDirectory $WeChatDir
    Log "WeChat starting..."
}

# ---------- 2) 快速轮询等待【登录窗口】出现 ----------
$deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
$loginFound = $false
while ([DateTime]::Now -lt $deadline) {
    Update-WxWindow
    if ($script:curTarget -ne [IntPtr]::Zero) {
        $r0 = Get-WxRect $script:curRender
        if ($r0.H -gt $r0.W) { $loginFound = $true; break }   # 竖版 = 登录窗
        if ($r0.W -ge $r0.H) { Log "Already in main window, nothing to click."; exit 0 }  # 横版 = 已登录
    }
    Start-Sleep -Milliseconds 150
}
if (-not $loginFound) { Log "No login window within ${TimeoutSec}s (already logged in?). skip."; exit 0 }

# ---------- 3) 记住当前鼠标位置（用于结束后归位） ----------
$saved = New-Object 'WxApi+POINT'
[WxApi]::GetCursorPos([ref]$saved) | Out-Null

# ---------- 4) 点击 -> 校验 -> 重试 ----------
$ok = $false
for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    if (Test-LoggedIn) { $ok = $true; break }
    if ($script:curRender -eq [IntPtr]::Zero) { $ok = $true; break }

    [WxApi]::SetForegroundWindow($script:curTarget) | Out-Null
    Start-Sleep -Milliseconds 150

    # 激活后重新读取位置/尺寸（窗口可能被移动）
    $r = Get-WxRect $script:curRender
    $x = $r.L + [int]($r.W * $BtnX)
    $y = $r.T + [int]($r.H * $BtnY)
    Log ("Click attempt {0}/{1} at ({2},{3}) size {4}x{5}" -f $attempt,$MaxRetries,$x,$y,$r.W,$r.H)

    # 真实鼠标输入（微信自绘界面不接受后台消息注入）
    [WxApi]::SetCursorPos($x,$y) | Out-Null
    Start-Sleep -Milliseconds 60
    [WxApi]::mouse_event($LEFTDOWN,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
    [WxApi]::mouse_event($LEFTUP,0,0,0,[UIntPtr]::Zero)

    # ---------- 5) 快速轮询确认是否进入主界面（一进入立即返回，最多 2.5s） ----------
    $clickDeadline = [DateTime]::Now.AddSeconds(2.5)
    while ([DateTime]::Now -lt $clickDeadline) {
        Start-Sleep -Milliseconds 120
        if (Test-LoggedIn) { $ok = $true; break }
    }
    if ($ok) { break }
    Log "Not in main window yet, retrying..."
}

# ---------- 6) 鼠标归位 ----------
if ($RestoreMouse) { [WxApi]::SetCursorPos($saved.X,$saved.Y) | Out-Null }

if ($ok) { Log "Logged in. Done."; exit 0 }
else { Log "WARN: login not confirmed after $MaxRetries attempts, please click manually."; exit 1 }
