#requires -Version 5.1
[CmdletBinding()]
param([switch]$KeepBackup)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'wechat_common.ps1')
$startupLock = $null
try {
    $startupLock = Enter-WeChatStartupLock
    $task = Get-WeChatScheduledTask
    if ($task) {
        Assert-WeChatTaskOwner $task
        if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName 'WeChatAutoLogin' -TaskPath '\' -ErrorAction Stop }
        Unregister-ScheduledTask -TaskName 'WeChatAutoLogin' -TaskPath '\' -Confirm:$false -ErrorAction Stop
    }
    if (-not $KeepBackup) {
        $backupPath = Get-WeChatBackupPath
        if (Test-Path -LiteralPath $backupPath) {
            $backup = Import-Clixml -LiteralPath $backupPath
            Assert-WeChatBackup $backup
            if (Restore-WeChatStartup $backup -ExcludeAutoLogin) { Remove-Item -LiteralPath $backupPath -Force }
            else { throw "Some startup entries could not be restored. Backup retained: $backupPath" }
        }
    }
    Write-Host '[OK] Auto-login task removed. Original startup entries restored unless -KeepBackup was used.'
    Write-Host 'Project files and logs are retained.'
} catch {
    Write-Error "Uninstall failed: $_" -ErrorAction Continue
    exit 1
}
finally { if ($startupLock) { $startupLock.ReleaseMutex(); $startupLock.Dispose() } }
