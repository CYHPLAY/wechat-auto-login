# ============================================================
# 一键安装开机自启（install_autostart.ps1）
# ------------------------------------------------------------
# 在 Windows 启动文件夹创建两个快捷方式：
#   1. WeChat.lnk          -> 开机自动启动微信
#   2. WeChatAutoLogin.lnk -> 开机隐藏运行自动登录脚本
# 用法：
#   powershell -ExecutionPolicy Bypass -File install_autostart.ps1
#   自定义微信路径：
#   powershell -ExecutionPolicy Bypass -File install_autostart.ps1 -WeChatExe "你的\Weixin.exe"
# 编码：本文件含中文注释，请用 UTF-8（带 BOM）保存。
# ============================================================
param(
    [string]$WeChatExe = "D:\WeChat\Weixin\Weixin.exe"   # 微信程序路径（按实际安装位置修改）
)
$ErrorActionPreference = 'Stop'

$scriptDir  = $PSScriptRoot                                          # 本脚本所在目录
$mainScript = Join-Path $scriptDir "wechat_autologin.ps1"            # 主脚本（同目录）

if (-not (Test-Path $mainScript)) {
    Write-Host "[ERROR] wechat_autologin.ps1 not found next to this script."
    exit 1
}
if (-not (Test-Path $WeChatExe)) {
    Write-Host "[WARN] WeChat not found: $WeChatExe"
    Write-Host "       Pass the real path with -WeChatExe, or run setup.ps1 to auto-detect."
    exit 1
}

$startup = [Environment]::GetFolderPath('Startup')   # 当前用户启动文件夹
$ws = New-Object -ComObject WScript.Shell

# 1) 微信开机自启
$lnkWx = $ws.CreateShortcut((Join-Path $startup "WeChat.lnk"))
$lnkWx.TargetPath  = $WeChatExe
$lnkWx.Description = "Start WeChat"
$lnkWx.Save()

# 2) 自动登录脚本开机自启（隐藏窗口运行）
$lnkAuto = $ws.CreateShortcut((Join-Path $startup "WeChatAutoLogin.lnk"))
$lnkAuto.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnkAuto.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mainScript`""
$lnkAuto.Description = "WeChat auto login"
$lnkAuto.Save()

Write-Host "[OK] Autostart created:"
Write-Host "     WeChat.lnk          -> $WeChatExe"
Write-Host "     WeChatAutoLogin.lnk -> $mainScript"
Write-Host "Tip: enable 'Auto login on this device' in WeChat (phone) to skip confirmation."
