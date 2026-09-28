# ============================================================
# 一键安装开机自启（install_autostart.ps1）
# ------------------------------------------------------------
# 功能：
#   在 Windows 启动文件夹创建两个快捷方式：
#     1. WeChat.lnk          -> 开机自动启动微信
#     2. WeChatAutoLogin.lnk -> 开机隐藏运行自动登录脚本
# 用法：
#   powershell -ExecutionPolicy Bypass -File install_autostart.ps1
#   自定义微信路径：
#   powershell -ExecutionPolicy Bypass -File install_autostart.ps1 -WeChatExe "你的\Weixin.exe"
# 编码提示：
#   本文件含中文注释，请用【UTF-8 带 BOM】编码保存；
#   PowerShell 5.1 若乱码，请用记事本另存为 UTF-8（带 BOM）。
# ============================================================
param(
    [string]$WeChatExe = "D:\WeChat\Weixin\Weixin.exe"   # 微信程序路径（按实际安装位置修改）
)
$ErrorActionPreference = 'Stop'   # 出错立即停止

$scriptDir  = $PSScriptRoot   # 本脚本所在目录
$mainScript = Join-Path $scriptDir "wechat_autologin.ps1"   # 主脚本路径（同目录）

# 检查主脚本是否存在
if (-not (Test-Path $mainScript)) {
    Write-Host "[ERROR] 未找到 wechat_autologin.ps1（应位于本脚本同目录）"
    exit 1
}
# 检查微信程序是否存在
if (-not (Test-Path $WeChatExe)) {
    Write-Host "[WARN] 未找到微信程序: $WeChatExe"
    Write-Host "       请用 -WeChatExe 参数指定微信 Weixin.exe 的真实路径"
    exit 1
}

$startup = [Environment]::GetFolderPath('Startup')   # 获取当前用户启动文件夹
$ws = New-Object -ComObject WScript.Shell   # 用于创建快捷方式

# ---------- 1) 微信开机自启 ----------
$lnkWx = $ws.CreateShortcut((Join-Path $startup "WeChat.lnk"))
$lnkWx.TargetPath  = $WeChatExe   # 指向微信程序
$lnkWx.Description = "启动微信"
$lnkWx.Save()

# ---------- 2) 自动登录脚本开机自启（隐藏窗口运行） ----------
$lnkAuto = $ws.CreateShortcut((Join-Path $startup "WeChatAutoLogin.lnk"))
$lnkAuto.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"   # 调用系统 PowerShell
$lnkAuto.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mainScript`""   # 隐藏窗口运行主脚本
$lnkAuto.Description = "微信自动登录（自动点击进入WeChat）"
$lnkAuto.Save()

Write-Host "[OK] 已创建开机自启："
Write-Host "     WeChat.lnk          -> $WeChatExe"
Write-Host "     WeChatAutoLogin.lnk -> $mainScript"
Write-Host "提示：请在微信登录时勾选'自动登录该设备'，实现免手机确认。"
