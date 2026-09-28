# ============================================================
# 微信自动登录脚本（wechat_autologin.ps1）
# ------------------------------------------------------------
# 功能：
#   开机/手动运行后，自动完成以下流程：
#     1. 启动微信（若未运行）
#     2. 轮询等待微信登录窗口出现
#     3. 激活登录窗口
#     4. 用【相对比例】定位"进入WeChat"按钮
#     5. 真实鼠标输入点击（SetCursorPos + mouse_event）
#     6. 进入主界面后静默退出
# 特性：
#   - 按钮使用窗口内相对比例定位（默认 49.8%、77.3%），
#     因此在不同分辨率、不同 DPI 缩放的屏幕上都能准确点击。
#   - 零第三方依赖：仅用 Windows 自带 PowerShell + user32 API。
# 运行方式：
#   powershell -NoProfile -ExecutionPolicy Bypass -File wechat_autologin.ps1
#   可选参数：-WeChatExe "微信路径" -BtnX 0.498 -BtnY 0.773
# 编码提示：
#   本文件含中文注释，请用【UTF-8 带 BOM】编码保存；
#   若 PowerShell 5.1 显示乱码或报错，用记事本"另存为"
#   选择编码：UTF-8（带 BOM）后重新运行。
# ============================================================
param(
    [string]$WeChatExe = "D:\WeChat\Weixin\Weixin.exe",  # 微信程序路径（按实际安装位置修改）
    [string]$WeChatDir = "D:\WeChat\Weixin",             # 微信工作目录
    [int]$TimeoutSec  = 30,                                # 等待登录窗口的超时时间（秒）
    [double]$BtnX     = 0.498,  # "进入WeChat"按钮中心 X：窗口宽度比例（分辨率无关）
    [double]$BtnY     = 0.773   # "进入WeChat"按钮中心 Y：窗口高度比例（分辨率无关）
)
$ErrorActionPreference = 'Stop'   # 出错立即停止，便于排查

# ---------- 导入 Windows user32 原生 API（零依赖） ----------
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WxApi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();   // 让进程按物理像素工作（DPI 感知）
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);  // 将窗口置为前台
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);  // 枚举所有顶层窗口
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, ChildProc cb, IntPtr l);  // 枚举子窗口
    public delegate bool ChildProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);  // 读窗口标题
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);   // 读窗口类名
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, IntPtr rect);  // 读窗口矩形（位置+尺寸）
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);  // 窗口是否可见
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);  // 移动鼠标指针到屏幕坐标
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);  // 发送鼠标事件
}
"@
[WxApi]::SetProcessDPIAware() | Out-Null   # 开启 DPI 感知：后续取到的都是物理像素，保证高 DPI 屏幕下坐标准确

$LEFTDOWN = 0x0002   # 鼠标左键【按下】事件标志
$LEFTUP   = 0x0004   # 鼠标左键【抬起】事件标志
$deadline = [DateTime]::Now.AddSeconds($TimeoutSec)   # 超时截止时间

# ---------- 第 1 步：若微信未运行，则启动微信 ----------
if (-not (Get-Process -Name "Weixin" -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $WeChatExe)) {
        # 微信路径不存在：跳过自动登录（避免报错）
        Write-Host "WeChat not found: $WeChatExe (skip auto-login)"
        exit 0
    }
    Start-Process -FilePath $WeChatExe -WorkingDirectory $WeChatDir   # 启动微信
    Start-Sleep -Milliseconds 800   # 等微信进程初始化
}

# ---------- 第 2 步：轮询等待微信窗口出现 ----------
# 判断依据：窗口标题为 WeChat、可见、且包含渲染子窗口 MMUIRenderSubWindowHW（微信自绘 UI）
Write-Host "Waiting for WeChat window..."
$script:target = [IntPtr]::Zero   # 微信主窗口句柄
$script:render = [IntPtr]::Zero   # 渲染子窗口句柄（用于定位按钮）
while ([DateTime]::Now -lt $deadline) {
    $script:target = [IntPtr]::Zero
    $script:render = [IntPtr]::Zero
    $cb = [WxApi+EnumProc]{
        param($h,$l)
        $t = New-Object System.Text.StringBuilder 256
        [WxApi]::GetWindowText($h,$t,256) | Out-Null
        if ($t.ToString() -ne 'WeChat') { return $true }   # 标题不是 WeChat，跳过
        if (-not [WxApi]::IsWindowVisible($h)) { return $true }   # 窗口不可见，跳过
        $script:fr = [IntPtr]::Zero
        $ccb = [WxApi+ChildProc]{
            param($ch,$cl)
            $cn = New-Object System.Text.StringBuilder 256
            [WxApi]::GetClassName($ch,$cn,256) | Out-Null
            if ($cn.ToString() -eq 'MMUIRenderSubWindowHW') { $script:fr = $ch; return $false }   # 找到渲染子窗口
            return $true
        }
        [WxApi]::EnumChildWindows($h,$ccb,[IntPtr]::Zero) | Out-Null
        if ($script:fr -ne [IntPtr]::Zero) { $script:target = $h; $script:render = $script:fr; return $false }   # 命中微信窗口
        return $true
    }
    [WxApi]::EnumWindows($cb,[IntPtr]::Zero) | Out-Null
    if ($script:target -ne [IntPtr]::Zero) { break }   # 已找到，跳出循环
    Start-Sleep -Milliseconds 250   # 每 250ms 查一次
}

$win = $script:target
if ($win -eq [IntPtr]::Zero) {
    # 超时未找到窗口：说明可能已登录成功，直接退出
    Write-Host "No WeChat window found in ${TimeoutSec}s (already logged in? skip)."
    exit 0
}

# ---------- 第 3 步：读取渲染窗口矩形 ----------
# 用指针方式读取 GetWindowRect 返回的 4 个 int（PS5.1 下 [ref] 方式会静默失败，必须用指针）
$ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(16)
[WxApi]::GetWindowRect($script:render, $ptr) | Out-Null
$L = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr,0)   # 左
$T = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr,4)   # 上
$R = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr,8)   # 右
$B = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr,12)  # 下
[System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)   # 释放内存

$w = $R - $L   # 窗口宽度（物理像素）
$h = $B - $T   # 窗口高度（物理像素）
if ($h -le $w) {
    # 宽 >= 高：是主界面窗口（横版），无需点击，直接退出
    Write-Host "Main window detected, no click needed."
    exit 0
}
Write-Host "Login window detected, clicking Enter-WeChat..."

# ---------- 第 4 步：激活窗口（置为前台） ----------
[WxApi]::SetForegroundWindow($win) | Out-Null
Start-Sleep -Milliseconds 300   # 等待窗口激活完成

# ---------- 第 5 步：用相对比例计算按钮屏幕坐标 ----------
# 关键：按钮位置 = 窗口左上角 + 窗口尺寸 × 比例，与分辨率/DPI 无关
$x = $L + [int]($w * $BtnX)
$y = $T + [int]($h * $BtnY)
Write-Host "Button at ($x,$y)"

# ---------- 第 6 步：真实鼠标输入点击 ----------
# 微信自绘界面不接受后台消息注入，必须用真实鼠标事件
[WxApi]::SetCursorPos($x, $y) | Out-Null   # 移动鼠标到按钮
Start-Sleep -Milliseconds 80
[WxApi]::mouse_event($LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)   # 按下左键
Start-Sleep -Milliseconds 40
[WxApi]::mouse_event($LEFTUP, 0, 0, 0, [UIntPtr]::Zero)     # 抬起左键

Write-Host "Clicked. Done."   # 点击完成
Start-Sleep -Milliseconds 1000   # 稍等后静默退出
