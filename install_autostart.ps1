# ============================================================
# wechat-auto-login - one-click autostart installer
# Creates two startup shortcuts:
#   1. WeChat.lnk          -> start WeChat on login
#   2. WeChatAutoLogin.lnk -> run wechat_autologin.ps1 hidden to click "Enter WeChat"
# NOTE: This file is pure ASCII (PowerShell 5.1 parses no-BOM UTF-8 as ANSI,
#       so any non-ASCII breaks it).
# Usage:
#   powershell -ExecutionPolicy Bypass -File install_autostart.ps1
#   powershell -ExecutionPolicy Bypass -File install_autostart.ps1 -WeChatExe "your\Weixin.exe"
# ============================================================
param(
    [string]$WeChatExe = "D:\WeChat\Weixin\Weixin.exe"
)
$ErrorActionPreference = 'Stop'

$scriptDir  = $PSScriptRoot
$mainScript = Join-Path $scriptDir "wechat_autologin.ps1"

if (-not (Test-Path $mainScript)) {
    Write-Host "[ERROR] wechat_autologin.ps1 not found beside this script."
    exit 1
}
if (-not (Test-Path $WeChatExe)) {
    Write-Host "[WARN] WeChat exe not found: $WeChatExe"
    Write-Host "       Use -WeChatExe to point to the real Weixin.exe path."
    exit 1
}

$startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell

# 1) WeChat autostart
$lnkWx = $ws.CreateShortcut((Join-Path $startup "WeChat.lnk"))
$lnkWx.TargetPath  = $WeChatExe
$lnkWx.Description = "Start WeChat"
$lnkWx.Save()

# 2) auto-login script autostart (hidden window)
$lnkAuto = $ws.CreateShortcut((Join-Path $startup "WeChatAutoLogin.lnk"))
$lnkAuto.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnkAuto.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mainScript`""
$lnkAuto.Description = "WeChat auto-login (click Enter WeChat)"
$lnkAuto.Save()

Write-Host "[OK] Autostart installed:"
Write-Host "     WeChat.lnk          -> $WeChatExe"
Write-Host "     WeChatAutoLogin.lnk -> $mainScript"
Write-Host "Tip: enable 'Auto login on this device' in WeChat to skip phone confirmation."
