#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Menu','Install','Test','Uninstall','Status')]
    [string]$Action = 'Menu',
    [switch]$Silent,
    [string]$WeChatExe = '',
    [string]$SetupDir = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'wechat_common.ps1')

function Get-AppDir {
    if ($SetupDir) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SetupDir) }
    return (Join-Path $env:LOCALAPPDATA 'WeChatAutoLogin\app')
}
function Get-LogFile { Join-Path $env:LOCALAPPDATA 'WeChatAutoLogin\autologin.log' }
function Get-PowerShell { Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }

function Show-Status {
    $info = Get-WeChatEnvironment
    Write-Host ''
    Write-Host '-------- 当前状态 --------' -ForegroundColor Cyan
    Write-Host ('计划任务 WeChatAutoLogin : ' + $(if ($info.Installed) { '已安装 (' + [string]$info.PrimaryTask.State + ')' } else { '未安装' }))
    Write-Host ('微信程序               : ' + $(if ($info.WeChatExe) { $info.WeChatExe } else { '未找到，安装时会自动搜索' }))
    Write-Host ('部署目录               : ' + $info.DeployDir + $(if ($info.Deployed) { '  [存在]' } else { '  [不存在]' }))
    Write-Host ('运行中的微信进程数     : ' + $info.ProcessCount)
    Write-Host ('开机自启入口数量       : ' + $info.AutostartEntryCount)
    foreach ($s in $info.StartupShortcuts) {
        Write-Host ('  - 启动文件夹快捷方式 : ' + $s.Path + $(if ($s.IsAutoLogin) { '  [自动登录脚本]' } else { '  [微信本体]' })) -ForegroundColor Yellow
    }
    foreach ($r in $info.RunItems) {
        Write-Host ("  - 注册表 $($r.Hive) 启动项 : $($r.Name) = $($r.Value)") -ForegroundColor Yellow
    }
    foreach ($x in $info.ExtraTasks) {
        Write-Host ('  - 其它位置的同名计划任务 : ' + $x.TaskPath + $x.TaskName) -ForegroundColor Yellow
    }
    if ($info.HasDuplicates) {
        Write-Host '  [警告] 存在多个微信开机入口，可能导致开机多开；选“安装/修复”会自动只保留计划任务一个。' -ForegroundColor Yellow
    } elseif ($info.Installed) {
        Write-Host '  开机入口唯一，无重复项。' -ForegroundColor Green
    }
    Write-Host '--------------------------'
    Write-Host '开源: https://github.com/CYHPLAY/wechat-auto-login' -ForegroundColor DarkGray
    return $info
}

function Invoke-ManagerInstall {
    $app = Get-AppDir
    $setup = Join-Path $PSScriptRoot 'setup.ps1'
    Write-Host ''
    Write-Host '正在安装 / 修复（会自动识别微信、注册计划任务并清理重复开机项）...' -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $setup)) { throw '找不到 setup.ps1，它应与本程序在同一目录。' }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$setup,'-SetupDir',$app)
    if ($WeChatExe) { $argList += @('-WeChatExe',$WeChatExe) }
    $p = Start-Process -FilePath (Get-PowerShell) -ArgumentList $argList -WorkingDirectory $PSScriptRoot -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -eq 0) { Write-Host '安装 / 修复完成。' -ForegroundColor Green } else { Write-Warning "安装未成功，退出码 $($p.ExitCode)。" }
    return $p.ExitCode
}

function Invoke-ManagerTest {
    $task = Get-WeChatScheduledTask
    if (-not $task) { Write-Warning '尚未安装，请先执行“安装 / 修复”。'; return 2 }
    $log = Get-LogFile
    # Only judge by lines written after this trigger, never by historical log content.
    $beforeLines = 0
    if (Test-Path -LiteralPath $log) { $beforeLines = @(Get-Content -LiteralPath $log).Count }
    Write-Host ''
    Write-Host '立即触发一次自动登录（等同开机）。接下来可能移动鼠标点击微信，请勿操作鼠标键盘...' -ForegroundColor Cyan
    Start-ScheduledTask -TaskName 'WeChatAutoLogin' -TaskPath '\'
    $finished = $false; $ok = $false; $newLines = @()
    # Wait up to 120s for the script's own Done./WARN/ERROR conclusion (a cold boot normally finishes within ~15s).
    for ($i = 0; $i -lt 240; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path -LiteralPath $log)) { continue }
        $all = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
        if ($all.Count -lt $beforeLines) { $beforeLines = 0 }  # log was rotated/recreated
        if ($all.Count -gt $beforeLines) { $newLines = @($all | Select-Object -Skip $beforeLines) }
        if ($newLines -match 'Done\.') { $finished = $true; $ok = $true; break }
        if ($newLines -match 'WARN|ERROR') { $finished = $true; $ok = $false; break }
    }
    foreach ($line in $newLines) { Write-Host "  $line" -ForegroundColor DarkGray }
    if ($ok) { Write-Host '测试成功：已进入微信主界面。' -ForegroundColor Green; return 0 }
    if ($finished) { Write-Warning '测试已结束，但未确认进入主界面，请看上方日志。'; return 1 }
    Write-Warning '等待超时，请查看微信窗口或日志。'; return 1
}

function Invoke-ManagerUninstall {
    $app = Get-AppDir
    $uninstaller = Join-Path $app 'uninstall.ps1'
    Write-Host ''
    if (Test-Path -LiteralPath $uninstaller) {
        Write-Host '正在卸载（移除计划任务并恢复安装前的开机项）...' -ForegroundColor Cyan
        $p = Start-Process -FilePath (Get-PowerShell) -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$uninstaller) -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -eq 0) { Write-Host '卸载完成。脚本文件保留在部署目录，可手动删除。' -ForegroundColor Green } else { Write-Warning "卸载未成功，退出码 $($p.ExitCode)。" }
        return $p.ExitCode
    }
    $task = Get-WeChatScheduledTask
    if ($task) {
        Assert-WeChatTaskOwner $task
        Unregister-ScheduledTask -TaskName 'WeChatAutoLogin' -TaskPath '\' -Confirm:$false
        Write-Host '部署目录已不存在，已直接移除残留的计划任务。' -ForegroundColor Green
        return 0
    }
    Write-Host '没有找到已安装的计划任务，无需卸载。' -ForegroundColor Yellow
    return 0
}

function Pause-Back { if (-not $Silent) { Write-Host ''; Read-Host '按回车返回菜单' | Out-Null } }

# Single-action (non-interactive) mode.
if ($Action -ne 'Menu') {
    $code = 0
    switch ($Action) {
        'Status'    { [void](Show-Status) }
        'Install'   { $code = Invoke-ManagerInstall }
        'Test'      { $code = Invoke-ManagerTest }
        'Uninstall' { $code = Invoke-ManagerUninstall }
    }
    if (-not $Silent) { Write-Host ''; Read-Host '按回车退出' | Out-Null }
    exit ([int]$code)
}

# Interactive menu.
while ($true) {
    Clear-Host
    Write-Host '==================================' -ForegroundColor Cyan
    Write-Host '   微信开机自动登录' -ForegroundColor Cyan
    Write-Host '   开机自动打开微信并进入主界面' -ForegroundColor Gray
    Write-Host '   github.com/CYHPLAY/wechat-auto-login' -ForegroundColor DarkGray
    Write-Host '==================================' -ForegroundColor Cyan
    [void](Show-Status)
    Write-Host ''
    Write-Host '  [1] 安装 / 修复（自动清理重复开机项）'
    Write-Host '  [2] 立即测试一次自动登录'
    Write-Host '  [3] 卸载'
    Write-Host '  [0] 退出'
    $choice = Read-Host '请输入选项'
    switch ($choice) {
        '1' { Invoke-ManagerInstall | Out-Null; Pause-Back }
        '2' { Invoke-ManagerTest | Out-Null; Pause-Back }
        '3' {
            $sure = Read-Host '确定卸载吗？输入 y 确认'
            if ($sure -eq 'y' -or $sure -eq 'Y') { Invoke-ManagerUninstall | Out-Null }
            Pause-Back
        }
        '0' { break }
        default { Write-Host '无效选项。'; Start-Sleep -Seconds 1 }
    }
    if ($choice -eq '0') { break }
}
