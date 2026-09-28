# ============================================================
# 一键部署安装器（setup.ps1）
# ------------------------------------------------------------
# 功能：
#   在一台新电脑上运行一次即可完成全部部署：
#     1. 自动识别微信安装位置（进程 / 常见目录）
#     2. 自动识别屏幕物理分辨率 + DPI 缩放（按钮用相对比例，
#        自动适配任意分辨率，无需手调）
#     3. 生成自动登录脚本（微信路径已自动填入）
#     4. 配置开机自启（启动微信 + 隐藏运行自动登录）
# 用法：
#   powershell -ExecutionPolicy Bypass -File setup.ps1
# 编码提示：
#   本文件含中文注释，请用【UTF-8 带 BOM】编码保存；
#   PowerShell 5.1 若乱码，请用记事本另存为 UTF-8（带 BOM）。
# ============================================================
param(
    [string]$OutDir = $PSScriptRoot   # 输出目录：生成的脚本写到这里（默认本目录）
)
$ErrorActionPreference = 'Stop'

# ---------- 第 1 步：自动识别微信安装位置 ----------
function Find-WeChatExe {
    # 优先：从正在运行的微信进程获取真实路径
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
            if (Test-Path $c) { return $c }   # 找到即返回
        }
    }
    return $null   # 都没找到
}

$wxExe = Find-WeChatExe
if (-not $wxExe) {
    Write-Host "[ERROR] 未自动找到微信 Weixin.exe。"
    Write-Host "       请先安装微信，或打开本文件手动修改路径。"
    exit 1
}
$wxDir = Split-Path $wxExe   # 微信所在目录

# ---------- 第 2 步：识别物理分辨率 / DPI ----------
# 用物理像素（DPI 感知）检测，显示的是显示器真实分辨率（而非缩放后的逻辑值）
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
$resW = [DpiX]::GetSystemMetrics(0)   # 屏幕物理宽度（像素）
$resH = [DpiX]::GetSystemMetrics(1)   # 屏幕物理高度（像素）
$dpi = [DpiX]::GetDpiForSystem()      # 系统 DPI（96 为 100%）
$scale = [math]::Round($dpi / 96.0, 2)   # 缩放倍数

Write-Host "Screen resolution : ${resW} x ${resH} (physical)"
Write-Host "DPI scaling       : $dpi  (${scale}x)"
Write-Host "WeChat location   : $wxExe"

# ---------- 第 3 步：生成自动登录脚本 ----------
# 按钮点击使用【相对比例】，因此任何分辨率 / DPI 都能准确命中，无需手调
$mainContent = @'
# ============================================================
# 微信自动登录脚本（由 setup.ps1 自动生成）
# 按钮使用窗口内相对比例定位，适配任意分辨率 / DPI。
# ============================================================
param(
    [string]$WeChatExe = "{WECHAT_EXE}",   # 微信路径（部署时自动填入）
    [string]$WeChatDir = "{WECHAT_DIR}",   # 微信目录（部署时自动填入）
    [int]$TimeoutSec  = 30,                 # 等待窗口超时（秒）
    [double]$BtnX     = 0.498,   # "进入WeChat"按钮 X 比例
    [double]$BtnY     = 0.773    # "进入WeChat"按钮 Y 比例
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

# 启动微信（若未运行）
if (-not (Get-Process -Name "Weixin" -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $WeChatExe)) {
        Write-Host "WeChat not found: $WeChatExe (skip auto-login)"
        exit 0
    }
    Start-Process -FilePath $WeChatExe -WorkingDirectory $WeChatDir
    Start-Sleep -Milliseconds 800
}

# 等待微信窗口（标题 WeChat + 可见 + 含渲染子窗口）
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

# 读取渲染窗口矩形（指针方式，PS5.1 下 [ref] 会静默失败）
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

# 相对比例定位按钮（分辨率 / DPI 无关）
$x = $L + [int]($w * $BtnX)
$y = $T + [int]($h * $BtnY)
Write-Host "Button at ($x,$y)"

# 真实鼠标输入点击
[WxApi]::SetCursorPos($x, $y) | Out-Null
Start-Sleep -Milliseconds 80
[WxApi]::mouse_event($LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 40
[WxApi]::mouse_event($LEFTUP, 0, 0, 0, [UIntPtr]::Zero)

Write-Host "Clicked. Done."
Start-Sleep -Milliseconds 1000
'@

# 把检测到的微信路径写入生成脚本
$mainContent = $mainContent.Replace('{WECHAT_EXE}', $wxExe)
$mainContent = $mainContent.Replace('{WECHAT_DIR}', $wxDir)

$mainPath = Join-Path $OutDir "wechat_autologin.ps1"
# 写入文件（UTF-8 无 BOM；如需中文脚本请另存为 UTF-8 with BOM）
[System.IO.File]::WriteAllText($mainPath, $mainContent, (New-Object System.Text.UTF8Encoding $false))
Write-Host "[OK] Wrote: $mainPath"

# ---------- 第 4 步：配置开机自启 ----------
$startup = [Environment]::GetFolderPath('Startup')   # 启动文件夹
$ws = New-Object -ComObject WScript.Shell

# 启动项 1：开机启动微信
$l1 = $ws.CreateShortcut((Join-Path $startup "WeChat.lnk"))
$l1.TargetPath  = $wxExe
$l1.Description = "启动微信"
$l1.Save()

# 启动项 2：开机隐藏运行自动登录脚本
$l2 = $ws.CreateShortcut((Join-Path $startup "WeChatAutoLogin.lnk"))
$l2.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$l2.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mainPath`""
$l2.Description = "微信自动登录"
$l2.Save()

Write-Host "[OK] Autostart configured:"
Write-Host "     WeChat.lnk          -> $wxExe"
Write-Host "     WeChatAutoLogin.lnk -> $mainPath"
Write-Host ""
Write-Host "Done. On next login WeChat starts and auto-logs-in."
Write-Host "Tip: enable 'Auto login on this device' in WeChat (phone) to skip confirmation."
