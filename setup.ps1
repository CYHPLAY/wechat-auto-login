# ============================================================
# 微信自动登录 - 一键部署脚本（零第三方依赖 / 纯 PowerShell + Win32 API）
#
# 用法：右键“使用 PowerShell 运行”，或在 PowerShell 中执行：
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1
#
# 它会自动完成：
#   1) 自动识别微信安装位置（先看正在运行的进程，再扫常见目录/注册表）；
#   2) 自动识别当前屏幕物理分辨率 / DPI（脚本已 DPI 感知，按钮按比例定位）；
#   3) 生成 wechat_autologin.ps1 到本脚本所在目录（UTF-8 带 BOM，不乱码）；
#   4) 在“启动”文件夹创建两个开机自启快捷方式：
#        - WeChat.lnk          开机启动微信
#        - WeChatAutoLogin.lnk  开机后隐藏运行自动登录脚本
#   换电脑 / 换分辨率 / 微信装在别的盘，都直接跑本脚本即可，无需手改。
# ============================================================

[CmdletBinding()]
param(
    [string]$SetupDir = $PSScriptRoot,   # 输出目录，默认本脚本所在文件夹
    [string]$WeChatExe = ""              # 可手动指定微信路径，留空则自动识别
)

$ErrorActionPreference = "Stop"

function Write-Step($m){ Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "[!] $m" -ForegroundColor Yellow }

# ---------- 1. 识别微信路径 ----------
function Find-WeChatExe {
    # 1) 正在运行的微信进程（新版 Weixin / 旧版 WeChat）
    foreach($name in @('Weixin','WeChat')){
        $p = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if($p -and $p.Path -and (Test-Path $p.Path)){ return $p.Path }
    }
    # 2) 常见安装目录
    $candidates = @(
        "$env:ProgramFiles\Tencent\Weixin\Weixin.exe",
        "${env:ProgramFiles(x86)}\Tencent\Weixin\Weixin.exe",
        "$env:LOCALAPPDATA\Tencent\Weixin\Weixin.exe",
        "D:\WeChat\Weixin\Weixin.exe",
        "D:\Program Files\Tencent\Weixin\Weixin.exe",
        "D:\Program Files (x86)\Tencent\Weixin\Weixin.exe",
        "C:\WeChat\Weixin\Weixin.exe",
        "$env:ProgramFiles\Tencent\WeChat\WeChat.exe",
        "${env:ProgramFiles(x86)}\Tencent\WeChat\WeChat.exe",
        "D:\WeChat\WeChat.exe",
        "D:\Program Files\Tencent\WeChat\WeChat.exe",
        "D:\Program Files (x86)\Tencent\WeChat\WeChat.exe"
    )
    foreach($c in $candidates){ if($c -and (Test-Path $c)){ return $c } }
    # 3) 其它盘/目录兜底搜索（限定两层常见目录，避免全盘扫描太慢）
    foreach($drive in (Get-PSDrive -PSProvider FileSystem).Root){
        foreach($sub in @('WeChat\Weixin','WeChat','Program Files\Tencent\Weixin','Program Files (x86)\Tencent\Weixin')){
            $guess = Join-Path $drive ($sub + '\Weixin.exe')
            if(Test-Path $guess){ return $guess }
        }
    }
    # 4) 注册表卸载信息
    foreach($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                      'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')){
        try{
            Get-ItemProperty $key -ErrorAction SilentlyContinue | ForEach-Object {
                $loc = $_.InstallLocation
                if($loc){
                    foreach($exe in @('Weixin.exe','WeChat.exe')){
                        $g = Join-Path $loc $exe
                        if(Test-Path $g){ $script:regHit = $g }
                    }
                }
            }
        }catch{}
        if($script:regHit){ return $script:regHit }
    }
    return $null
}

if(-not $WeChatExe){ $WeChatExe = Find-WeChatExe }
if(-not $WeChatExe -or -not (Test-Path $WeChatExe)){
    Write-Warn2 "未能自动识别微信路径。请用 -WeChatExe 指定，例如："
    Write-Host '   powershell -ExecutionPolicy Bypass -File .\setup.ps1 -WeChatExe "D:\WeChat\Weixin\Weixin.exe"'
    exit 1
}
$WeChatDir = Split-Path $WeChatExe -Parent
Write-Ok "微信路径：$WeChatExe"

# ---------- 2. 识别物理分辨率 / DPI（仅展示，脚本运行时会自行 DPI 感知） ----------
try{
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type @"
using System;using System.Runtime.InteropServices;
public class Dpi{
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("gdi32.dll")] public static extern IntPtr CreateDC(string d,string dev,string o,IntPtr i);
 [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc,int i);
 [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
}
"@
    [Dpi]::SetProcessDPIAware() | Out-Null
    $dc=[Dpi]::CreateDC("DISPLAY",$null,$null,[IntPtr]::Zero)
    $px=[Dpi]::GetDeviceCaps($dc,118); $py=[Dpi]::GetDeviceCaps($dc,117)
    [Dpi]::DeleteDC($dc) | Out-Null
    $scale = [math]::Round($px/[System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Width*100)
    Write-Ok "物理分辨率：${px} x ${py}（约 $scale% 缩放，按钮按比例定位，无需手动适配）"
}catch{
    Write-Warn2 "未能读取分辨率信息（不影响使用，脚本会按窗口比例定位按钮）"
}

# ---------- 3. 生成主脚本 ----------
if(-not $SetupDir -or -not (Test-Path $SetupDir)){ $SetupDir = $PSScriptRoot }
$outScript = Join-Path $SetupDir "wechat_autologin.ps1"

# 内嵌主脚本（单引号 here-string，原样写入；末尾再替换路径占位符）
$embedded = @'
# ============================================================
# 微信 PC 自动登录脚本（零第三方依赖 / 纯 Windows API）
# 由 setup.ps1 自动生成。
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
    [string]$WeChatExe  = "{WECHAT_EXE}",
    [string]$WeChatDir  = "{WECHAT_DIR}",
    [int]$TimeoutSec    = 30,
    [double]$BtnX       = 0.498,
    [double]$BtnY       = 0.773,
    [double]$GreenRatio = 0.30,
    [int]$MaxRetries    = 5,
    [int]$MinReadyMs    = 250,
    [bool]$RestoreMouse = $true
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
Log "launch / activate WeChat..."
Start-WeChat

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$lastRect = $null; $stableCount = 0; $firstSeen = $null
$loginFound = $false; $appearAt = Get-Date

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
            $loginFound = $true; break
        }
    } else {
        if (((Get-Date) - $appearAt).TotalSeconds -ge 5) {
            Log "no visible window, re-activating..."
            Start-WeChat; $appearAt = Get-Date
        }
    }
    Start-Sleep -Milliseconds 60
}

if (-not $loginFound) {
    if (Test-LoggedIn) { Log "already logged in. Done."; exit 0 }
    Log "WARN: $TimeoutSec 秒内未找到微信登录窗。"; exit 1
}

Log ("login window ready after {0} ms" -f [int]($firstSeen - $scriptStart).TotalMilliseconds)

Add-Type -AssemblyName System.Windows.Forms
$startPos = [System.Windows.Forms.Cursor]::Position

$ok = $false
for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    $diag = $null; $ready = $false
    $btnDeadline = (Get-Date).AddSeconds($TimeoutSec)
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
    if (-not $ready) { Log "WARN: $TimeoutSec 秒内未检测到绿色登录按钮（按钮未就绪）。"; break }
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
'@

# 替换路径占位符，并以 UTF-8 带 BOM 写出（保证 PS5.1 中文不乱码）
$embedded = $embedded.Replace("{WECHAT_EXE}", $WeChatExe).Replace("{WECHAT_DIR}", $WeChatDir)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($outScript, $embedded, $utf8Bom)
Write-Ok "已生成主脚本：$outScript"

# ---------- 4. 创建开机自启快捷方式 ----------
$startup = [Environment]::GetFolderPath('Startup')
$wsh = New-Object -ComObject WScript.Shell

# 4.1 微信本体开机启动
$lnkWeChat = Join-Path $startup "WeChat.lnk"
$s1 = $wsh.CreateShortcut($lnkWeChat)
$s1.TargetPath = $WeChatExe
$s1.WorkingDirectory = $WeChatDir
$s1.WindowStyle = 1
$s1.Save()
Write-Ok "开机启动微信：$lnkWeChat"

# 4.2 自动登录脚本开机隐藏运行（延迟 8 秒，等微信和网络起来）
$lnkAuto = Join-Path $startup "WeChatAutoLogin.lnk"
$s2 = $wsh.CreateShortcut($lnkAuto)
$s2.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$s2.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"Start-Sleep -Seconds 8; & '$outScript'`""
$s2.WorkingDirectory = $SetupDir
$s2.WindowStyle = 7
$s2.Save()
Write-Ok "开机自动登录：$lnkAuto"

Write-Host ""
Write-Ok "部署完成！下次开机会自动启动微信并登录。"
Write-Host "    立即测试：powershell -ExecutionPolicy Bypass -File `"$outScript`"" -ForegroundColor Gray
Write-Host "    卸载自启：运行 uninstall.ps1" -ForegroundColor Gray
