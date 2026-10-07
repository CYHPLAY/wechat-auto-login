#requires -Version 5.1
[CmdletBinding()]
param([string]$WeChatExe = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'wechat_common.ps1')
$startupLock = $null
try {
    $startupLock = Enter-WeChatStartupLock
    $WeChatExe = Resolve-WeChatExe $WeChatExe
    Install-WeChatAutostart -ScriptDir $PSScriptRoot -WeChatExe $WeChatExe
    Write-Host '[OK] Scheduled task installed for the current user.' -ForegroundColor Green
    Write-Host "Test: Start-ScheduledTask -TaskName 'WeChatAutoLogin'"
} catch {
    Write-Error "Installation failed: $_" -ErrorAction Continue
    exit 1
}
finally { if ($startupLock) { $startupLock.ReleaseMutex(); $startupLock.Dispose() } }
