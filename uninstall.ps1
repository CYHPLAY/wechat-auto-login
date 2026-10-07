# ============================================================
# 卸载开机自启（uninstall.ps1）
# ------------------------------------------------------------
# 功能：
#   1) 删除本项目创建的计划任务 WeChatAutoLogin（登录时触发的自启）；
#   2) 清理启动文件夹里残留的、与微信/本脚本相关的快捷方式。
# 按“任务名 / 目标程序 / 启动参数”匹配，只删微信与本脚本相关项，
# 不会误删其他软件（如 AyuGram）的开机启动项。
# 用法：
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
# 编码：本文件含中文注释，请用 UTF-8（带 BOM）保存。
# ============================================================
$ErrorActionPreference = 'Continue'

$taskName = 'WeChatAutoLogin'

# 1) 删除计划任务
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed scheduled task: $taskName"
} else {
    Write-Host "Scheduled task '$taskName' not found."
}

# 2) 清理启动文件夹里残留的相关快捷方式
$startup = [Environment]::GetFolderPath('Startup')
if (Test-Path $startup) {
    $ws = New-Object -ComObject WScript.Shell
    Get-ChildItem -Path $startup -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
        $sc = $ws.CreateShortcut($_.FullName)
        $target = [string]$sc.TargetPath
        $arg    = [string]$sc.Arguments

        # 命中：参数含 wechat_autologin（本脚本），或目标是微信主程序
        $isAutoLogin = ($arg    -match 'wechat_autologin')
        $isWeChat    = ($target -match '(?i)(weixin|wechat)\.exe$')

        if ($isAutoLogin -or $isWeChat) {
            Remove-Item $_.FullName -Force
            Write-Host ("Removed startup shortcut: " + $_.Name)
        }
    }
}

Write-Host "Done. WeChat auto-login autostart removed."
Write-Host "提示：如需微信自带开机启动，请在微信 设置→通用设置 里重新勾选“开机自动启动”。" -ForegroundColor Gray
