# ============================================================
# wechat-auto-login - 一键安装开机自启
# 创建两个启动项：
#   1. 微信.lnk          -> 开机启动微信
#   2. 微信自动登录.lnk  -> 开机运行 wechat_autologin.ps1 自动点击进入
# 用法：
#   powershell -ExecutionPolicy Bypass -File install_autostart.ps1
#   powershell -ExecutionPolicy Bypass -File install_autostart.ps1 -WeChatExe "D:\你的路径\Weixin.exe"
# ============================================================
param(
    [string]$WeChatExe = "D:\WeChat\Weixin\Weixin.exe"
)

$ErrorActionPreference = 'Stop'

$scriptDir  = $PSScriptRoot
$mainScript = Join-Path $scriptDir "wechat_autologin.ps1"

if (-not (Test-Path $mainScript)) {
    Write-Host "[ERROR] 未找到 wechat_autologin.ps1（应位于本脚本同目录）"
    exit 1
}
if (-not (Test-Path $WeChatExe)) {
    Write-Host "[WARN] 未找到微信程序: $WeChatExe"
    Write-Host "       请用 -WeChatExe 参数指定微信 Weixin.exe 的真实路径"
    exit 1
}

$startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell

$lnkWx = $ws.CreateShortcut((Join-Path $startup "微信.lnk"))
$lnkWx.TargetPath = $WeChatExe
$lnkWx.Description = "启动微信"
$lnkWx.Save()

$lnkAuto = $ws.CreateShortcut((Join-Path $startup "微信自动登录.lnk"))
$lnkAuto.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnkAuto.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mainScript`""
$lnkAuto.Description = "微信自动登录（自动点击进入WeChat）"
$lnkAuto.Save()

Write-Host "[OK] 已创建开机自启："
Write-Host "     微信.lnk        -> $WeChatExe"
Write-Host "     微信自动登录.lnk -> $mainScript"
Write-Host "提示：请在微信登录时勾选'自动登录该设备'，实现免手机确认。"
