#requires -Version 5.1
[CmdletBinding()]
param([string]$SetupDir = $PSScriptRoot, [string]$WeChatExe = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'wechat_common.ps1')
$savedFiles = @()
$createdDirectory = $false
$startupLock = $null
try {
    $startupLock = Enter-WeChatStartupLock
    $WeChatExe = Resolve-WeChatExe $WeChatExe
    if (-not $SetupDir) { throw 'SetupDir must not be empty.' }
    $SetupDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SetupDir)
    if (-not (Test-Path -LiteralPath $SetupDir)) {
        [void](New-Item -ItemType Directory -Path $SetupDir)
        $createdDirectory = $true
    }
    if (-not (Test-Path -LiteralPath $SetupDir -PathType Container)) { throw 'SetupDir must be a directory.' }
    foreach ($name in @('wechat_autologin.ps1','wechat_common.ps1','install_autostart.ps1','uninstall.ps1','setup.ps1','README.md')) {
        $source = Join-Path $PSScriptRoot $name
        $target = Join-Path $SetupDir $name
        if ([IO.Path]::GetFullPath($source) -eq [IO.Path]::GetFullPath($target)) { continue }
        $bytes = $null
        if (Test-Path -LiteralPath $target) { $bytes = [IO.File]::ReadAllBytes($target) }
        $savedFiles += [pscustomobject]@{ Path=$target; Bytes=$bytes }
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
    Install-WeChatAutostart -ScriptDir $SetupDir -WeChatExe $WeChatExe
    Write-Host "[OK] Installed to: $SetupDir" -ForegroundColor Green
    Write-Host "WeChat: $WeChatExe"
    Write-Host "Test: Start-ScheduledTask -TaskName 'WeChatAutoLogin'"
} catch {
    foreach ($file in $savedFiles) {
        try {
            if ($null -eq $file.Bytes) { if (Test-Path -LiteralPath $file.Path) { Remove-Item -LiteralPath $file.Path -Force } }
            else { [IO.File]::WriteAllBytes($file.Path, $file.Bytes) }
        } catch { Write-Warning "Could not restore $($file.Path): $_" }
    }
    if ($createdDirectory -and @(Get-ChildItem -LiteralPath $SetupDir -Force).Count -eq 0) { Remove-Item -LiteralPath $SetupDir -Force }
    Write-Error "Installation failed: $_" -ErrorAction Continue
    exit 1
}
finally { if ($startupLock) { $startupLock.ReleaseMutex(); $startupLock.Dispose() } }
