# ============================================================
# 微信自动登录 - 一键部署脚本（零第三方依赖 / 纯 PowerShell + Win32 API）
#
# 用法：右键“使用 PowerShell 运行”，或：
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1
#
# 自动完成：
#   1) 自动识别微信安装位置（进程 → 常见目录 → 其它盘 → 注册表）；
#   2) 自动识别屏幕物理分辨率 / DPI（脚本已 DPI 感知，按钮按比例定位）；
#   3) 生成 wechat_autologin.ps1（UTF-8 带 BOM，不乱码）；
#   4) 只创建“一个”开机自启入口——登录计划任务 WeChatAutoLogin（登录瞬间运行，无
#      延迟；微信由脚本幂等启动，进程已在就不重复拉起）；
#   5) 自动清理会导致开机多开的重复来源：
#        - 启动文件夹里旧的 WeChat.lnk / 微信.lnk 等直接启动微信的快捷方式；
#        - 注册表 HKCU\...\Run 里微信自带的开机自启（Weixin / WeChat）。
#      这样开机只有脚本一个入口，绝不会弹出多个微信。
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
    foreach($name in @('Weixin','WeChat')){
        $p = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if($p -and $p.Path -and (Test-Path $p.Path)){ return $p.Path }
    }
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
    foreach($drive in (Get-PSDrive -PSProvider FileSystem).Root){
        foreach($sub in @('WeChat\Weixin','WeChat','Program Files\Tencent\Weixin','Program Files (x86)\Tencent\Weixin')){
            $guess = Join-Path $drive ($sub + '\Weixin.exe')
            if(Test-Path $guess){ return $guess }
        }
    }
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

# ---------- 2. 识别物理分辨率 / DPI（仅展示） ----------
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

$embedded = @'
# ============================================================
# 微信 PC 自动登录脚本（零第三方依赖 / 纯 Windows API）
# 作用：开机登录后由计划任务 WeChatAutoLogin 调用，自动启动微信并
#       点击绿色“进入WeChat”按钮进入主界面。
#
# 不写死任何机器 / 用户信息：
#   * 微信路径自动识别（正在运行的进程 → 常见安装目录 → 各盘符 →
#     注册表卸载信息），也可用 -WeChatExe 手动指定；
#   * 脚本内不含用户名、计算机名或固定用户目录，拷到任意电脑可直接运行。
#
# 设计要点（避免开机多开 / 提速）：
#   * 幂等启动：微信进程已存在（正在开机初始化）就只等待、绝不重复拉起；
#               只有进程不存在时才启动一次。
#   * 唤起节流：进程在但无可见窗口时，先宽限一段时间，之后每隔较长时间
#               才唤起一次，避免和微信自带开机启动叠加而多开。
#   * 无固定睡眠：登录即运行，登录窗 / 绿色按钮一就绪就动作，不干等。
#   * 检测之后再点击：GetPixel 读取按钮区域像素颜色，确认绿色按钮已渲染
#               就绪才点击（不截图、不存图、不做图像匹配），通常 1 次命中。
# ============================================================

[CmdletBinding()]
param(
    [string]$WeChatExe  = "",
    [string]$WeChatDir  = "",
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

# 自动查找微信可执行文件：正在运行的进程 → 常见安装目录 → 各盘符 → 注册表
function Find-WeChatExe {
    foreach ($name in @('Weixin','WeChat')) {
        $p = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p -and $p.Path -and (Test-Path $p.Path)) { return $p.Path }
    }
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
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem).Root) {
        foreach ($sub in @('WeChat\Weixin','WeChat','Program Files\Tencent\Weixin','Program Files (x86)\Tencent\Weixin')) {
            $g = Join-Path $drive ($sub + '\Weixin.exe')
            if (Test-Path $g) { return $g }
        }
    }
    $script:foundExe = $null
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                      'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        try {
            Get-ItemProperty $key -ErrorAction SilentlyContinue | ForEach-Object {
                $loc = $_.InstallLocation
                if ($loc) {
                    foreach ($exe in @('Weixin.exe','WeChat.exe')) {
                        $g = Join-Path $loc $exe
                        if (Test-Path $g) { $script:foundExe = $g }
                    }
                }
            }
        } catch {}
        if ($script:foundExe) { return $script:foundExe }
    }
    return $null
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

# 启动微信（幂等：调用方保证只在需要时调用）。路径未指定 / 失效则自动查找。
function Start-WeChat {
    $exe = $WeChatExe
    if (-not $exe -or -not (Test-Path $exe)) { $exe = Find-WeChatExe }
    if ($exe -and (Test-Path $exe)) {
        $dir = $WeChatDir
        if (-not $dir) { $dir = Split-Path $exe -Parent }
        if (-not $WeChatExe) { Log "auto-detected WeChat: $exe" }
        Start-Process -FilePath $exe -WorkingDirectory $dir
    } else {
        Log "ERROR: 找不到微信程序，请用 -WeChatExe 指定 Weixin.exe 的完整路径。"
        exit 1
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
'@

# 主脚本已内置微信路径自动查找，直接 UTF-8 写出（不写死任何路径）
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($outScript, $embedded, $utf8Bom)
Write-Ok "已生成主脚本：$outScript"

# ---------- 4. 清理重复开机启动源，只保留一个入口（登录计划任务，无启动延迟） ----------
$taskName = 'WeChatAutoLogin'
$startup = [Environment]::GetFolderPath('Startup')

# 4.1 删除启动文件夹里的旧入口（脚本快捷方式 + 直接启动微信本体的快捷方式）
foreach($name in @('WeChatAutoLogin.lnk','WeChat.lnk','微信.lnk','Weixin.lnk','微信自动登录.lnk')){
    $old = Join-Path $startup $name
    if(Test-Path $old){ Remove-Item $old -Force; Write-Warn2 "删除启动文件夹旧入口：$name" }
}

# 4.2 移除注册表中微信自带的开机自启（HKCU\...\Run 的 Weixin / WeChat）
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
foreach($v in @('Weixin','WeChat')){
    if($null -ne (Get-ItemProperty -Path $runKey -Name $v -ErrorAction SilentlyContinue)){
        Remove-ItemProperty -Path $runKey -Name $v -ErrorAction SilentlyContinue
        Write-Warn2 "移除注册表开机自启项：$v"
    }
}

# 4.3 注册“用户登录时立即运行”的计划任务
#     计划任务由系统计划服务在登录瞬间直接拉起，不受启动文件夹 / Run 项
#     约 10 秒的“开机启动延迟”影响，因此比快捷方式更快。
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$taction = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$outScript`"" -WorkingDirectory $SetupDir
$ttrig   = New-ScheduledTaskTrigger -AtLogOn
$tset    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -RestartCount 0
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $taction -Trigger $ttrig -Settings $tset -Description 'WeChat auto login at logon (single entry, no startup delay)' -Force | Out-Null
Write-Ok "唯一开机自启入口：计划任务 '$taskName'（登录即运行，无启动延迟）"

Write-Host ""
Write-Ok "部署完成！开机只会启动一个微信并自动登录（脚本幂等启动，不再多开）。"
Write-Host "    立即测试：Start-ScheduledTask -TaskName '$taskName'（或直接运行主脚本）" -ForegroundColor Gray
Write-Host "    卸载自启：运行 uninstall.ps1" -ForegroundColor Gray
Write-Host "    说明：已改用登录计划任务（无开机启动延迟），并关闭微信自带/旧的重复启动，开机不会多开。" -ForegroundColor Gray
