# ============================================================
# 一键安装开机自启（install_autostart.ps1）
# ------------------------------------------------------------
# 采用“任务计划程序 - 用户登录时触发”，而不是启动文件夹快捷方式：
#   * 计划任务由系统计划服务在登录瞬间直接拉起，【不受 Windows 对启动
#     文件夹 / Run 项约 10 秒的“开机启动延迟”影响】，登录即跑、最快；
#   * 只创建这一个入口，微信本体由脚本幂等启动（进程已在就不重复启动）。
#
# 同时自动清理会导致多开 / 变慢的旧来源：
#   * 启动文件夹里的 WeChatAutoLogin.lnk、WeChat.lnk、微信.lnk 等；
#   * 注册表 HKCU\...\Run 里微信自带的开机自启（Weixin / WeChat）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File install_autostart.ps1
# 编码：本文件含中文注释，请用 UTF-8（带 BOM）保存。
# ============================================================

$ErrorActionPreference = 'Stop'

$taskName   = 'WeChatAutoLogin'
$scriptDir  = $PSScriptRoot                                           # 本脚本所在目录
$mainScript = Join-Path $scriptDir "wechat_autologin.ps1"              # 主脚本（同目录）

if (-not (Test-Path $mainScript)) {
    Write-Host "[ERROR] 未找到同目录下的 wechat_autologin.ps1。" -ForegroundColor Red
    exit 1
}

# 1) 清理“启动文件夹”里的旧入口（脚本快捷方式 + 直接启动微信本体的快捷方式）
$startup = [Environment]::GetFolderPath('Startup')
$legacyNames = @('WeChatAutoLogin.lnk', 'WeChat.lnk', '微信.lnk', 'Weixin.lnk', '微信自动登录.lnk')
foreach ($name in $legacyNames) {
    $p = Join-Path $startup $name
    if (Test-Path $p) {
        Remove-Item $p -Force
        Write-Host "[CLEAN] 删除启动文件夹旧入口: $name" -ForegroundColor Yellow
    }
}

# 2) 移除注册表中微信自带的开机自启（HKCU\...\Run 的 Weixin / WeChat）
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
foreach ($v in @('Weixin', 'WeChat')) {
    if ($null -ne (Get-ItemProperty -Path $runKey -Name $v -ErrorAction SilentlyContinue)) {
        Remove-ItemProperty -Path $runKey -Name $v -ErrorAction SilentlyContinue
        Write-Host "[CLEAN] 移除注册表开机自启项: $v" -ForegroundColor Yellow
    }
}

# 3) 注册（或覆盖）“用户登录时立即运行”的计划任务 —— 无启动延迟
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$action = New-ScheduledTaskAction -Execute $psExe `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mainScript`"" `
    -WorkingDirectory $scriptDir

# AtLogOn：用户登录瞬间触发；默认不带延迟（区别于启动文件夹的 ~10 秒延迟）
$trigger = New-ScheduledTaskTrigger -AtLogOn

# Interactive：在当前用户桌面会话运行，才能操作微信窗口/鼠标；Limited 普通权限即可，不弹 UAC

# 笔记本用电池也运行、不因切电池停止；多实例忽略（防止重复跑）；最长运行 5 分钟
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -RestartCount 0

# 若已存在同名任务则先删除，再注册（保证幂等、配置最新）
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Description 'WeChat auto login at logon (single entry, no startup delay)' -Force | Out-Null

Write-Host ""
Write-Host "[OK] 已设置唯一开机自启入口（计划任务，登录即运行、无启动延迟）:" -ForegroundColor Green
Write-Host "     任务名: $taskName"
Write-Host "     动作  : $mainScript"
Write-Host "     开机由该任务自动启动微信并登录，不会多开。"
Write-Host "提示：请在手机端登录确认页勾选“自动登录该设备”。" -ForegroundColor Gray
Write-Host "立即手动触发一次测试：Start-ScheduledTask -TaskName '$taskName'" -ForegroundColor Gray
