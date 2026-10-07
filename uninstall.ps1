# ============================================================
# 卸载开机自启（uninstall.ps1）
# ------------------------------------------------------------
# 功能：删除启动文件夹里由本项目创建的微信自启快捷方式。
#   - 不依赖快捷方式文件名（中文名/英文名都能清）
#   - 按"目标程序 / 启动参数"匹配，只删微信与本脚本相关项，
#     不会误删其他软件的开机启动项。
# 用法：
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
# 编码：本文件含中文注释，请用 UTF-8（带 BOM）保存。
# ============================================================
$ErrorActionPreference = 'Stop'

$startup = [Environment]::GetFolderPath('Startup')   # 当前用户启动文件夹
if (-not (Test-Path $startup)) { Write-Host "Startup folder not found."; exit 0 }

$ws = New-Object -ComObject WScript.Shell
$script:removed = 0

# 遍历启动文件夹内所有快捷方式，按目标匹配后删除
Get-ChildItem -Path $startup -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
    $sc = $ws.CreateShortcut($_.FullName)
    $target = [string]$sc.TargetPath
    $args   = [string]$sc.Arguments

    # 命中条件：参数里含 wechat_autologin（自动登录脚本），或目标是微信主程序
    $isAutoLogin = ($args  -match 'wechat_autologin')
    $isWeChat    = ($target -match '(?i)(weixin|wechat)\.exe$')

    if ($isAutoLogin -or $isWeChat) {
        Remove-Item $_.FullName -Force
        Write-Host ("Removed: " + $_.Name)
        $script:removed++
    }
}

if ($script:removed -eq 0) {
    Write-Host "No WeChat autostart entries found. Nothing to remove."
} else {
    Write-Host "Done. $script:removed autostart entry/entries removed."
}
