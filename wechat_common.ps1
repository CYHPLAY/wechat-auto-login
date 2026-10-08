#requires -Version 5.1
# Shared helpers. Dot-sourcing does not launch WeChat or change startup settings.
function Get-WeChatIdentity { [Security.Principal.WindowsIdentity]::GetCurrent() }

function Get-WeChatProcesses {
    $session = (Get-Process -Id $PID).SessionId
    @(Get-Process -Name Weixin,WeChat -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
}

function Find-WeChatExe {
    foreach ($process in @(Get-WeChatProcesses)) {
        try { if ($process.Path -and (Test-Path -LiteralPath $process.Path -PathType Leaf)) { return $process.Path } } catch {}
    }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $root) { continue }
        foreach ($sub in @('Tencent\Weixin\Weixin.exe','Tencent\WeChat\WeChat.exe')) {
            $candidate = Join-Path $root $sub
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    foreach ($key in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($entry in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
            if ($entry.DisplayName -notmatch '(?i)(wechat|weixin|微信)' -or -not $entry.InstallLocation) { continue }
            # InstallLocation may be quoted in the registry (e.g. '"D:\WeChat\Weixin"'); strip quotes before joining.
            $installLocation = [string]$entry.InstallLocation.Trim().Trim('"').Trim("'")
            foreach ($name in @('Weixin.exe','WeChat.exe')) {
                try {
                    $candidate = Join-Path $installLocation $name
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
                } catch {}
            }
        }
    }
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem)) {
        foreach ($sub in @('WeChat\Weixin\Weixin.exe','WeChat\WeChat.exe','WeChat\Weixin.exe',
                          'Program Files\Tencent\Weixin\Weixin.exe','Program Files\Tencent\WeChat\WeChat.exe',
                          'Program Files (x86)\Tencent\Weixin\Weixin.exe','Program Files (x86)\Tencent\WeChat\WeChat.exe')) {
            $candidate = Join-Path $drive.Root $sub
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    return $null
}

function Resolve-WeChatExe([string]$Path) {
    if (-not $Path) { $Path = Find-WeChatExe }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'WeChat executable not found. Supply -WeChatExe with the full path to Weixin.exe or WeChat.exe.'
    }
    $resolved = (Get-Item -LiteralPath $Path).FullName
    if ([IO.Path]::GetFileName($resolved) -notmatch '(?i)^(Weixin|WeChat)\.exe$') {
        throw 'WeChatExe must point to Weixin.exe or WeChat.exe.'
    }
    return $resolved
}

function Get-WeChatBackupPath { Join-Path $env:LOCALAPPDATA 'WeChatAutoLogin\autostart-backup.clixml' }

function Enter-WeChatStartupLock {
    $sid = (Get-WeChatIdentity).User.Value
    $mutex = New-Object Threading.Mutex($false, "Global\WeChatAutoLogin.Install.$sid")
    try {
        try { $acquired = $mutex.WaitOne(10000, $false) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another install/uninstall is in progress. Try again after it finishes.' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}

function Get-WeChatStartupFolder { [Environment]::GetFolderPath('Startup') }

function Test-WeChatScriptArgument([string]$Arguments) {
    $match = [regex]::Match($Arguments, '(?i)(?:^|\s)-File\s+(?:"(?<path>[^"]+)"|(?<path>[^\s"]+))(?:\s|$)')
    return ($match.Success -and [IO.Path]::GetFileName($match.Groups['path'].Value) -eq 'wechat_autologin.ps1')
}

function Test-WeChatShortcut([string]$Target, [string]$Arguments) {
    return ($Target -match '(?i)[\\/](weixin|wechat)\.exe$' -or
        ($Target -match '(?i)[\\/](powershell|pwsh)\.exe$' -and
         (Test-WeChatScriptArgument $Arguments)))
}

function Test-WeChatRunValue([string]$Value) {
    # Parse the first executable token; never match WeChat mentioned only as an argument.
    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    $match = [regex]::Match($expanded, '^\s*(?:"(?<exe>[^"]+)"|(?<exe>[^\s"]+))(?:\s|$)')
    if (-not $match.Success) { return $false }
    $exe = $match.Groups['exe'].Value
    return ([IO.Path]::IsPathRooted($exe) -and [IO.Path]::GetFileName($exe) -match '(?i)^(weixin|wechat)\.exe$')
}

function Get-WeChatScheduledTask {
    # Do not hide Task Scheduler service/access errors as "task not found".
    Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName -eq 'WeChatAutoLogin' }
}

function Assert-WeChatTaskOwner($Task) {
    $identity = Get-WeChatIdentity
    $owner = [string]$Task.Principal.UserId
    if ($owner -ne $identity.User.Value -and $owner -ne $identity.Name) {
        try { $owner = (New-Object Security.Principal.NTAccount($owner)).Translate([Security.Principal.SecurityIdentifier]).Value } catch {}
        if ($owner -ne $identity.User.Value) { throw 'WeChatAutoLogin belongs to another user; it will not be changed.' }
    }
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1 -or $actions[0].Execute -notmatch '(?i)[\\/](powershell|pwsh)\.exe$' -or -not (Test-WeChatScriptArgument $actions[0].Arguments)) {
        throw 'WeChatAutoLogin is used by an unrelated task; it will not be changed.'
    }
}

function Assert-WeChatBackup($Backup) {
    if ($Backup.Version -ne 1 -or $Backup.UserSid -ne (Get-WeChatIdentity).User.Value) {
        throw 'Startup backup has an unsupported version or belongs to another user.'
    }
    $startup = [IO.Path]::GetFullPath((Get-WeChatStartupFolder)).TrimEnd('\')
    foreach ($shortcut in @($Backup.Shortcuts)) {
        if (-not $shortcut.Path -or [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($shortcut.Path)).TrimEnd('\') -ne $startup -or
            [IO.Path]::GetExtension($shortcut.Path) -ne '.lnk' -or $null -eq $shortcut.Bytes) { throw 'Invalid shortcut in startup backup.' }
    }
    foreach ($item in @($Backup.RunItems)) {
        if ($item.Name -notin @('WeChat','Weixin') -or $item.Kind -notin @('String','ExpandString') -or -not (Test-WeChatRunValue $item.Value)) {
            throw 'Invalid Run entry in startup backup.'
        }
    }
}

function Get-WeChatStartupSnapshot {
    $shortcuts = @()
    $startup = Get-WeChatStartupFolder
    if ($startup -and (Test-Path -LiteralPath $startup)) {
        $shell = New-Object -ComObject WScript.Shell
        try {
            foreach ($file in @(Get-ChildItem -LiteralPath $startup -Filter '*.lnk' -File)) {
                $shortcut = $shell.CreateShortcut($file.FullName)
                if (Test-WeChatShortcut $shortcut.TargetPath $shortcut.Arguments) {
                    $shortcuts += [pscustomobject]@{
                        Path=$file.FullName; Bytes=[IO.File]::ReadAllBytes($file.FullName)
                        IsAutoLogin=($shortcut.TargetPath -match '(?i)[\\/](powershell|pwsh)\.exe$')
                    }
                }
            }
        } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    }
    $runItems = @()
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path -LiteralPath $runKey) {
        $key = Get-Item -LiteralPath $runKey
        foreach ($name in @('Weixin','WeChat')) {
            if ($key.GetValueNames() -notcontains $name) { continue }
            $value = [string]$key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if (-not (Test-WeChatRunValue $value) -or $key.GetValueKind($name).ToString() -notin @('String','ExpandString')) { continue }
            $runItems += [pscustomobject]@{ Name=$name; Value=$value; Kind=$key.GetValueKind($name).ToString() }
        }
    }
    [pscustomobject]@{ Version=1; UserSid=(Get-WeChatIdentity).User.Value; Shortcuts=$shortcuts; RunItems=$runItems }
}

function Restore-WeChatStartup {
    param($Snapshot, [switch]$ExcludeAutoLogin)
    Assert-WeChatBackup $Snapshot
    $complete = $true
    foreach ($shortcut in @($Snapshot.Shortcuts)) {
        if ($ExcludeAutoLogin -and $shortcut.IsAutoLogin) { continue }
        try {
            if (Test-Path -LiteralPath $shortcut.Path) {
                $existing = [Convert]::ToBase64String([IO.File]::ReadAllBytes($shortcut.Path))
                if ($existing -ne [Convert]::ToBase64String([byte[]]$shortcut.Bytes)) {
                    throw "A different shortcut exists at $($shortcut.Path); it will not be overwritten."
                }
            } else { [IO.File]::WriteAllBytes($shortcut.Path, [byte[]]$shortcut.Bytes) }
        } catch { $complete = $false; Write-Warning "Startup restore failed: $_" }
    }
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    foreach ($item in @($Snapshot.RunItems)) {
        try {
            if (-not (Test-Path -LiteralPath $runKey)) { [void](New-Item -Path $runKey -Force) }
            $key = Get-Item -LiteralPath $runKey
            if ($key.GetValueNames() -contains $item.Name) {
                $current = $key.GetValue($item.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($current -ne $item.Value -or $key.GetValueKind($item.Name).ToString() -ne $item.Kind) {
                    throw "Run entry $($item.Name) has changed; it will not be overwritten."
                }
            } else { [void](New-ItemProperty -LiteralPath $runKey -Name $item.Name -Value $item.Value -PropertyType $item.Kind) }
        } catch { $complete = $false; Write-Warning "Startup restore failed: $_" }
    }
    return $complete
}

function Install-WeChatAutostart {
    param([Parameter(Mandatory)][string]$ScriptDir, [Parameter(Mandatory)][string]$WeChatExe)
    $mainScript = Join-Path $ScriptDir 'wechat_autologin.ps1'
    foreach ($name in @('wechat_autologin.ps1','wechat_common.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $ScriptDir $name) -PathType Leaf)) { throw "Missing required file: $name" }
    }
    $WeChatExe = Resolve-WeChatExe $WeChatExe
    $identity = Get-WeChatIdentity
    $oldTask = Get-WeChatScheduledTask
    $oldXml = $null
    if ($oldTask) {
        Assert-WeChatTaskOwner $oldTask
        if ($oldTask.State -eq 'Running') { throw 'Auto-login is currently running. Wait for it to finish before updating.' }
        $oldXml = Export-ScheduledTask -TaskName 'WeChatAutoLogin' -TaskPath '\' -ErrorAction Stop
    }
    $running = New-Object Threading.Mutex($false, "Local\WeChatAutoLogin.$($identity.User.Value)")
    $ownsRunning = $false
    try {
        try { $ownsRunning = $running.WaitOne(0,$false) } catch [Threading.AbandonedMutexException] { $ownsRunning = $true }
        if (-not $ownsRunning) { throw 'A manual auto-login instance is running. Wait before updating.' }
    } finally {
        if ($ownsRunning) { $running.ReleaseMutex() }
        $running.Dispose()
    }
    $snapshot = Get-WeChatStartupSnapshot
    $backupPath = Get-WeChatBackupPath
    $oldBackupBytes = $null
    $baseline = $snapshot
    if (Test-Path -LiteralPath $backupPath) {
        $oldBackupBytes = [IO.File]::ReadAllBytes($backupPath)
        $baseline = Import-Clixml -LiteralPath $backupPath
        Assert-WeChatBackup $baseline
        foreach ($shortcut in @($snapshot.Shortcuts)) {
            if (@($baseline.Shortcuts | Where-Object { $_.Path -eq $shortcut.Path }).Count -eq 0) { $baseline.Shortcuts = @($baseline.Shortcuts) + $shortcut }
        }
        foreach ($item in @($snapshot.RunItems)) {
            if (@($baseline.RunItems | Where-Object { $_.Name -eq $item.Name }).Count -eq 0) { $baseline.RunItems = @($baseline.RunItems) + $item }
        }
    }
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mainScript`" -WeChatExe `"$WeChatExe`"" -WorkingDirectory $ScriptDir
    # Use the account name (DOMAIN\user), not the SID: when setup runs as "powershell.exe -File"
    # under Windows PowerShell 5.1, a SID in the logon trigger/principal fails with HRESULT 0x80070057.
    # The name is resolved at runtime, so no username is hardcoded; owner checks still compare the SID.
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $taskAttempted = $false
    $backupAttempted = $false
    try {
        # Persist backups before touching startup. Never unregister before replacing.
        [void](New-Item -ItemType Directory -Path (Split-Path $backupPath -Parent) -Force)
        $backupAttempted = $true
        $baseline | Export-Clixml -LiteralPath $backupPath -Depth 6 -ErrorAction Stop
        $taskAttempted = $true
        Register-ScheduledTask -TaskName 'WeChatAutoLogin' -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'WeChatAutoLogin: current-user interactive logon' -Force -ErrorAction Stop | Out-Null
        foreach ($shortcut in @($snapshot.Shortcuts)) { Remove-Item -LiteralPath $shortcut.Path -Force -ErrorAction Stop }
        foreach ($item in @($snapshot.RunItems)) { Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $item.Name -ErrorAction Stop }
    } catch {
        $failure = $_
        $restored = Restore-WeChatStartup $snapshot
        if ($taskAttempted) {
            try {
                if ($oldXml) { Register-ScheduledTask -TaskName 'WeChatAutoLogin' -TaskPath '\' -Xml $oldXml -Force -ErrorAction Stop | Out-Null }
                elseif (Get-WeChatScheduledTask) { Unregister-ScheduledTask -TaskName 'WeChatAutoLogin' -TaskPath '\' -Confirm:$false -ErrorAction Stop }
            } catch { $restored = $false; Write-Warning "Task rollback failed: $_" }
        }
        if ($backupAttempted -and $restored) {
            try {
                if ($null -ne $oldBackupBytes) { [IO.File]::WriteAllBytes($backupPath, $oldBackupBytes) }
                elseif (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
            } catch { Write-Warning "Backup rollback failed: $_" }
        }
        if (-not $restored) { Write-Warning "Rollback incomplete; recovery backup retained at $backupPath" }
        throw $failure
    }
}
