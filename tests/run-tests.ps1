#requires -Version 5.1
# No real Task Scheduler/registry changes, WeChat launch, foreground changes or mouse input.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$scratch=Join-Path $PSScriptRoot ('.work-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $scratch)
$script:passes=0; $script:failures=0

function Assert($Condition,[string]$Message='Assertion failed') { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action,[string]$Pattern='') {
    $caught=$false
    try { & $Action | Out-Null } catch { $caught=$true; if ($Pattern -and $_ -notmatch $Pattern) { throw "Unexpected error: $_" } }
    Assert $caught 'Expected an exception.'
}
function Test([string]$Name,[scriptblock]$Body) {
    try { & $Body; $script:passes++; Write-Host "PASS $Name" }
    catch { $script:failures++; Write-Host "FAIL $Name -- $_" -ForegroundColor Red; Write-Host $_.ScriptStackTrace }
}

try {
    . (Join-Path $repo 'wechat_common.ps1')
    $tokens=$null; $errors=$null
    $mainAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'wechat_autologin.ps1'),[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) 'Main script syntax errors.'
    # Native adapter doubles; import actual production function bodies with only type names substituted.
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public struct TestPosition { public int X; public int Y; public TestPosition(int x,int y) { X=x; Y=y; } }
public class TestCursor { public static TestPosition Position = new TestPosition(10,20); }
public class TestWxApi {
    public struct POINT { public int X; public int Y; public POINT(int x,int y) { X=x; Y=y; } }
    public static IntPtr Foreground = new IntPtr(100);
    public static IntPtr Root = new IntPtr(100);
    public static uint Color = 0x0030cc30;
    public static bool RectangleOK = true;
    public static bool InputOK = true;
    public static bool MoveOK = true;
    public static bool LoseFocusOnMove = false;
    public static bool ThrowOnMouseDown = false;
    public static int MouseDowns = 0;
    public static int MouseUps = 0;
    public static bool IsWindow(IntPtr h) { return h != IntPtr.Zero; }
    public static bool GetWindowRect(IntPtr h,IntPtr r) {
        if (!RectangleOK) return false;
        Marshal.WriteInt32(r,0,0); Marshal.WriteInt32(r,4,0);
        Marshal.WriteInt32(r,8,300); Marshal.WriteInt32(r,12,500); return true;
    }
    public static IntPtr GetForegroundWindow() { return Foreground; }
    public static IntPtr WindowFromPoint(POINT p) { return Root; }
    public static IntPtr GetAncestor(IntPtr h,uint flags) { return Root; }
    public static IntPtr OpenInputDesktop(uint f,bool i,uint a) { return InputOK ? new IntPtr(1) : IntPtr.Zero; }
    public static bool CloseDesktop(IntPtr d) { return true; }
    public static bool GetUserObjectInformation(IntPtr h,int index,StringBuilder name,int size,out uint needed) { name.Append("Default"); needed=16; return true; }
    public static IntPtr GetDC(IntPtr h) { return new IntPtr(1); }
    public static int ReleaseDC(IntPtr h,IntPtr dc) { return 1; }
    public static uint GetPixel(IntPtr dc,int x,int y) { return Color; }
    public static bool SetCursorPos(int x,int y) { if (!MoveOK) return false; TestCursor.Position=new TestPosition(x,y); if (LoseFocusOnMove) Foreground=new IntPtr(999); return true; }
    public static void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra) {
        if (flags==2) { MouseDowns++; if (ThrowOnMouseDown) throw new Exception("simulated mouse failure"); }
        if (flags==4) MouseUps++;
    }
}
'@
    $definitions=$mainAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    foreach ($definition in $definitions) {
        if ($definition.Name -eq 'Initialize-WxApi') { continue }
        $body=$definition.Extent.Text.Replace('[WxApi]', '[TestWxApi]').Replace('WxApi+POINT','TestWxApi+POINT').Replace('[System.Windows.Forms.Cursor]','[TestCursor]')
        . ([scriptblock]::Create($body))
    }
    $script:LogPath=Join-Path $scratch 'log\autologin.log'
    $script:BtnX=0.498; $script:BtnY=0.773; $script:GreenRatio=0.3; $script:RestoreMouse=$true
    $script:WeChatExe=''; $script:WeChatDir=''; $script:SW_RESTORE=9
    function Start-Sleep { param([int]$Milliseconds,[int]$Seconds) }

    Test 'Windows PowerShell parses every production/test script' {
        foreach ($file in @(Get-ChildItem -LiteralPath $repo -Recurse -Filter '*.ps1' -File)) {
            $t=$null; $e=$null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$t,[ref]$e)
            Assert ($e.Count -eq 0) "$($file.Name): $($e | Out-String)"
            $bytes=[IO.File]::ReadAllBytes($file.FullName)
            Assert ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "$($file.Name) requires UTF-8 BOM."
        }
    }
    Test 'Actual Win32 declarations compile without calling any native function' {
        $init=$definitions | Where-Object Name -eq 'Initialize-WxApi'
        $strings=$init.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match 'public class WxApi'},$true)
        Add-Type -TypeDefinition $strings[0].Value
    }
    Test 'Reject invalid coordinates, zero threshold, negative timeout and excessive retries' {
        $validator=[scriptblock]::Create($mainAst.ParamBlock.Extent.Text + "`r`n return 'valid'")
        Assert-Throws { & $validator -BtnX 1.5 }
        Assert-Throws { & $validator -BtnY -1 }
        Assert-Throws { & $validator -GreenRatio 0 }
        Assert-Throws { & $validator -WindowTimeoutSec -1 }
        Assert-Throws { & $validator -MaxRetries 11 }
        Assert-Throws { & $validator -ReviveIntervalSec 0 }
        Assert ((& $validator) -eq 'valid')
    }
    Test 'Resolve a custom executable path containing spaces and brackets' {
        $dir=Join-Path $scratch 'custom 微信 [4]'
        [void](New-Item -ItemType Directory -Path $dir)
        $exe=Join-Path $dir 'Weixin.exe'; [IO.File]::WriteAllBytes($exe,[byte[]]@(1,2))
        Assert ((Resolve-WeChatExe $exe) -eq $exe)
        Assert-Throws { Resolve-WeChatExe $dir }
        $other=Join-Path $dir 'other.exe'; [IO.File]::WriteAllBytes($other,[byte[]]@(1))
        Assert-Throws { Resolve-WeChatExe $other }
        Assert-Throws { Resolve-WeChatExe (Join-Path $dir 'missing.exe') }
    }
    Test 'Detect only shortcuts pointing to WeChat or the auto-login script' {
        Assert (Test-WeChatShortcut 'C:\apps\Weixin.exe' '')
        Assert (Test-WeChatShortcut 'C:\Windows\powershell.exe' '-File "C:\apps\wechat_autologin.ps1"')
        Assert (-not (Test-WeChatShortcut 'C:\apps\AyuGram.exe' ''))
        Assert (-not (Test-WeChatShortcut 'C:\apps\other.exe' '-File C:\apps\wechat_autologin.ps1'))
        Assert (-not (Test-WeChatShortcut 'C:\Windows\powershell.exe' '-File "C:\apps\wechat_autologin.ps1.bak"'))
        Assert (-not (Test-WeChatShortcut 'C:\Windows\powershell.exe' '-Command Write-Host C:\apps\wechat_autologin.ps1'))
    }
    Test 'Run entry matching rejects unrelated executables and command wrappers' {
        Assert (Test-WeChatRunValue '"D:\Program Files\Weixin.exe" /silent')
        Assert (Test-WeChatRunValue 'C:\apps\WeChat.exe')
        Assert (-not (Test-WeChatRunValue '"C:\apps\other.exe" "C:\apps\WeChat.exe"'))
        Assert (-not (Test-WeChatRunValue 'C:\apps\WeChat.exe.bak'))
        Assert (-not (Test-WeChatRunValue 'cmd.exe /c C:\apps\WeChat.exe'))
        Assert (Test-WeChatRunValue 'C:\Weixin.exe')
    }
    Test 'Prevent changing a task owned by another user or unrelated task' {
        $identity=Get-WeChatIdentity
        $task=[pscustomobject]@{Principal=[pscustomobject]@{UserId=$identity.User.Value};Actions=@([pscustomobject]@{Execute='C:\Windows\powershell.exe';Arguments='-File "C:\apps\wechat_autologin.ps1"'})}
        Assert-WeChatTaskOwner $task
        # Task Scheduler may return the full account name or only the SAM short name; both are still the current user.
        $task.Principal.UserId=$identity.Name; Assert-WeChatTaskOwner $task
        $task.Principal.UserId=(Split-Path $identity.Name -Leaf); Assert-WeChatTaskOwner $task
        $task.Principal.UserId='S-1-5-18'; Assert-Throws { Assert-WeChatTaskOwner $task }
        $task.Principal.UserId=$identity.User.Value; $task.Actions[0].Arguments='-File "C:\apps\other.ps1"'
        Assert-Throws { Assert-WeChatTaskOwner $task }
    }
    Test 'Restrict process detection to the current Windows session' {
        function Get-Process { param($Id,$Name) if ($PSBoundParameters.ContainsKey('Id')) { [pscustomobject]@{SessionId=3} } else { @([pscustomobject]@{Id=10;SessionId=3},[pscustomobject]@{Id=20;SessionId=7}) } }
        $processes=@(Get-WeChatProcesses)
        Assert ($processes.Count -eq 1 -and $processes[0].Id -eq 10)
    }
    Test 'Do not relaunch an already-running WeChat process' {
        function Get-WeChatPids { 123 }
        function Start-Process { throw 'Unexpected process launch.' }
        Start-WeChat
    }
    Test 'Failed rectangle retrieval returns no fabricated coordinates' {
        [TestWxApi]::RectangleOK=$false
        Assert ($null -eq (Get-WxRect ([IntPtr]100)))
        [TestWxApi]::RectangleOK=$true
        Assert ((Get-WxRect ([IntPtr]100)).W -eq 300)
    }
    Test 'Green button requires foreground ownership, visible sample points and unlocked desktop' {
        $script:curTarget=[IntPtr]100; $script:curRender=[IntPtr]101
        [TestWxApi]::Foreground=[IntPtr]100; [TestWxApi]::Root=[IntPtr]100; [TestWxApi]::InputOK=$true; [TestWxApi]::Color=0x0030cc30
        $info=$null; Assert (Test-ButtonReady ([ref]$info)); Assert ($info.Ratio -eq 1)
        [TestWxApi]::Foreground=[IntPtr]999; Assert (-not (Test-ButtonReady ([ref]$info)))
        [TestWxApi]::Foreground=[IntPtr]100; [TestWxApi]::Root=[IntPtr]999; Assert (-not (Test-ButtonReady ([ref]$info)))
        [TestWxApi]::Root=[IntPtr]100; [TestWxApi]::InputOK=$false; Assert (-not (Test-ButtonReady ([ref]$info)))
        [TestWxApi]::InputOK=$true; [TestWxApi]::Color=[uint32]::MaxValue; Assert (-not (Test-ButtonReady ([ref]$info)))
        [TestWxApi]::Color=0x0030cc30
    }
    Test 'A disappearing login window alone does not confirm login' {
        function Test-LoggedIn { $false }
        function Update-WxWindow { $script:curRender=[IntPtr]::Zero }
        Assert (-not (Test-LoginConfirmed))
    }
    Test 'Transient main window and coexisting login window do not confirm login' {
        $script:sample=0
        function Test-LoggedIn { $script:sample++; return ($script:sample -lt 2) }
        function Update-WxWindow { $script:curRender=[IntPtr]::Zero }
        Assert (-not (Test-LoginConfirmed))
        function Test-LoggedIn { $true }
        function Update-WxWindow { $script:curRender=[IntPtr]101 }
        Assert (-not (Test-LoginConfirmed))
    }
    Test 'Stable main window across three observations confirms login' {
        function Test-LoggedIn { $true }
        function Update-WxWindow { $script:curRender=[IntPtr]::Zero }
        Assert (Test-LoginConfirmed)
    }
    Test 'Click skips changed button without mouse input' {
        function Bring-ToFront { $true }
        function Update-WxWindow {}
        function Test-ButtonReady { param([ref]$Info) $false }
        [TestWxApi]::MouseDowns=0
        Assert (-not (Invoke-WeChatClick))
        Assert ([TestWxApi]::MouseDowns -eq 0)
    }
    Test 'Focus lost after cursor movement prevents click and restores cursor' {
        function Bring-ToFront { $true }
        function Update-WxWindow {}
        function Test-ButtonReady { param([ref]$Info) $Info.Value=[pscustomobject]@{Cx=150;Cy=380}; $true }
        function Test-InteractiveDesktop { $true }
        function Test-PointOwnedByWeChat { $true }
        $script:curTarget=[IntPtr]100
        [TestWxApi]::Foreground=[IntPtr]100; [TestWxApi]::LoseFocusOnMove=$true; [TestWxApi]::MouseDowns=0
        [TestCursor]::Position=New-Object TestPosition(10,20)
        Assert (-not (Invoke-WeChatClick))
        Assert ([TestWxApi]::MouseDowns -eq 0)
        Assert ([TestCursor]::Position.X -eq 10 -and [TestCursor]::Position.Y -eq 20)
        [TestWxApi]::LoseFocusOnMove=$false
    }
    Test 'Successful click releases mouse and restores original cursor' {
        function Bring-ToFront { $true }
        function Update-WxWindow {}
        function Test-ButtonReady { param([ref]$Info) $Info.Value=[pscustomobject]@{Cx=150;Cy=380}; $true }
        function Test-InteractiveDesktop { $true }
        function Test-PointOwnedByWeChat { $true }
        $script:curTarget=[IntPtr]100
        [TestWxApi]::Foreground=[IntPtr]100; [TestWxApi]::MouseDowns=0; [TestWxApi]::MouseUps=0
        [TestCursor]::Position=New-Object TestPosition(10,20)
        Assert (Invoke-WeChatClick)
        Assert ([TestWxApi]::MouseDowns -eq 1 -and [TestWxApi]::MouseUps -eq 1)
        Assert ([TestCursor]::Position.X -eq 10 -and [TestCursor]::Position.Y -eq 20)
    }
    Test 'Native mouse failure still releases button and restores cursor' {
        function Bring-ToFront { $true }
        function Update-WxWindow {}
        function Test-ButtonReady { param([ref]$Info) $Info.Value=[pscustomobject]@{Cx=150;Cy=380}; $true }
        function Test-InteractiveDesktop { $true }
        function Test-PointOwnedByWeChat { $true }
        $script:curTarget=[IntPtr]100
        [TestWxApi]::Foreground=[IntPtr]100; [TestWxApi]::MouseUps=0; [TestWxApi]::ThrowOnMouseDown=$true
        [TestCursor]::Position=New-Object TestPosition(10,20)
        Assert-Throws { Invoke-WeChatClick } 'simulated mouse failure'
        Assert ([TestWxApi]::MouseUps -eq 1)
        Assert ([TestCursor]::Position.X -eq 10 -and [TestCursor]::Position.Y -eq 20)
        [TestWxApi]::ThrowOnMouseDown=$false
    }
    function Reset-FlowFixture {
        $script:clock=[datetime]'2026-01-01T00:00:00'
        $script:updates=0; $script:clicks=0; $script:confirmations=0
        $script:WindowTimeoutSec=5; $script:ButtonTimeoutSec=2; $script:LoginTimeoutSec=10
        $script:MaxRetries=1; $script:MinReadyMs=250; $script:ReviveGraceSec=0; $script:ReviveIntervalSec=1
        $script:DontLaunch=$false
    }
    Test 'Full flow: login window disappears without main window, returns failure without clicking' {
        Reset-FlowFixture
        function Get-Date { param($Format) if ($Format) { return $script:clock.ToString($Format) }; $script:clock=$script:clock.AddMilliseconds(150); return $script:clock }
        function Get-WeChatPids { 123 }
        function Start-WeChat { throw 'Unexpected relaunch.' }
        function Test-LoginConfirmed { $false }
        function Update-WxWindow { $script:updates++; $script:curTarget=[IntPtr]100; if ($script:updates -le 3) { $script:curRender=[IntPtr]101 } else { $script:curRender=[IntPtr]::Zero } }
        function Invoke-WeChatClick { $script:clicks++; $true }
        Assert ((Invoke-WeChatAutoLogin) -eq 1)
        Assert ($script:clicks -eq 0)
    }
    Test 'Full flow: process crash after login window appears is an error, not success' {
        Reset-FlowFixture
        function Get-Date { param($Format) if ($Format) { return $script:clock.ToString($Format) }; $script:clock=$script:clock.AddMilliseconds(150); return $script:clock }
        function Get-WeChatPids { if ($script:updates -le 4) { 123 } }
        function Start-WeChat { throw 'Unexpected relaunch.' }
        function Test-LoginConfirmed { $false }
        function Update-WxWindow { $script:updates++; $script:curTarget=[IntPtr]100; $script:curRender=[IntPtr]101 }
        function Test-InteractiveDesktop { $true }
        function Bring-ToFront { $true }
        function Test-ButtonReady { param([ref]$Info) $false }
        Assert-Throws { Invoke-WeChatAutoLogin } 'exited before login'
    }
    Test 'Full flow: already-visible main window returns success without launching/clicking' {
        Reset-FlowFixture
        function Get-WeChatPids { 123 }
        function Start-WeChat { throw 'Unexpected relaunch.' }
        function Test-LoginConfirmed { $true }
        function Invoke-WeChatClick { throw 'Unexpected click.' }
        Assert ((Invoke-WeChatAutoLogin) -eq 0)
    }
    Test 'Full flow: allow slow login after one click instead of immediately retrying' {
        Reset-FlowFixture
        function Get-Date { param($Format) if ($Format) { return $script:clock.ToString($Format) }; $script:clock=$script:clock.AddMilliseconds(150); return $script:clock }
        function Get-WeChatPids { 123 }
        function Start-WeChat { throw 'Unexpected relaunch.' }
        function Test-LoginConfirmed { if ($script:clicks) { $script:confirmations++; return ($script:confirmations -ge 16) }; $false }
        function Update-WxWindow { $script:curTarget=[IntPtr]100; $script:curRender=[IntPtr]101 }
        function Test-InteractiveDesktop { $true }
        function Bring-ToFront { $true }
        function Test-ButtonReady { param([ref]$Info) $Info.Value=[pscustomobject]@{Ratio=1}; $true }
        function Invoke-WeChatClick { $script:clicks++; $true }
        Assert ((Invoke-WeChatAutoLogin) -eq 0)
        Assert ($script:clicks -eq 1 -and $script:confirmations -eq 16)
    }
    Test 'Full flow: DontLaunch waits for external launch and never starts WeChat' {
        Reset-FlowFixture; $script:DontLaunch=$true
        function Get-Date { param($Format) if ($Format) { return $script:clock.ToString($Format) }; $script:clock=$script:clock.AddMilliseconds(150); return $script:clock }
        function Get-WeChatPids {}
        function Start-WeChat { throw 'Unexpected launch.' }
        function Test-LoginConfirmed { $false }
        function Update-WxWindow { $script:curRender=[IntPtr]::Zero }
        Assert ((Invoke-WeChatAutoLogin) -eq 1)
    }
    Test 'Write persistent diagnostics and rotate oversized log' {
        Log 'regression-test'
        Assert ((Get-Content -LiteralPath $script:LogPath -Raw) -match 'regression-test')
        [IO.File]::WriteAllText($script:LogPath,('x' * (1MB+1)))
        Log 'after-rotation'
        Assert (Test-Path -LiteralPath ($script:LogPath+'.1'))
        Assert ((Get-Item -LiteralPath $script:LogPath).Length -lt 1KB)
    }

    # Fake scheduler and snapshots, real file backups inside this test's scratch directory only.
    $script:testStartup=Join-Path $scratch 'startup'
    [void](New-Item -ItemType Directory -Path $script:testStartup)
    $script:testBackup=Join-Path $scratch 'state\autostart-backup.clixml'
    $script:testExe=Join-Path $scratch 'Weixin.exe'; [IO.File]::WriteAllBytes($script:testExe,[byte[]]@(1))
    $script:testShortcut=Join-Path $script:testStartup '微信.lnk'
    function Get-WeChatStartupFolder { $script:testStartup }
    function Get-WeChatBackupPath { $script:testBackup }
    function Get-WeChatScheduledTask { $script:fakeTask }
    function Export-ScheduledTask { param($TaskName,$TaskPath) '<previous-task />' }
    function New-ScheduledTaskAction { param($Execute,$Argument,$WorkingDirectory) [pscustomobject]@{Execute=$Execute;Arguments=$Argument;WorkingDirectory=$WorkingDirectory} }
    function New-ScheduledTaskTrigger { param([switch]$AtLogOn,$User) [pscustomobject]@{User=$User} }
    function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel} }
    function New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,[switch]$StartWhenAvailable,$MultipleInstances,$ExecutionTimeLimit) [pscustomobject]@{Limit=$ExecutionTimeLimit} }
    function Register-ScheduledTask {
        [CmdletBinding()]param($TaskName,$TaskPath,$Action,$Trigger,$Principal,$Settings,$Description,$Xml,[switch]$Force)
        $script:events.Add('register')
        if ($script:failRegister -and -not $Xml) { throw 'simulated registration failure' }
        if ($Xml) { $script:fakeTask=$script:oldFakeTask; return }
        $script:fakeTask=[pscustomobject]@{Principal=$Principal;Actions=@($Action);State='Ready';Trigger=$Trigger;Settings=$Settings}
    }
    function Unregister-ScheduledTask { [CmdletBinding(SupportsShouldProcess)]param($TaskName,$TaskPath) $script:events.Add('unregister'); $script:fakeTask=$null }
    function Get-WeChatStartupSnapshot {
        $items=@()
        if (Test-Path -LiteralPath $script:testShortcut) { $items=@([pscustomobject]@{Path=$script:testShortcut;Bytes=[IO.File]::ReadAllBytes($script:testShortcut)}) }
        [pscustomobject]@{Version=1;UserSid=(Get-WeChatIdentity).User.Value;Shortcuts=$items;RunItems=@()}
    }
    function Reset-Fixture {
        $script:fakeTask=$null; $script:oldFakeTask=$null; $script:failRegister=$false
        $script:events=New-Object 'Collections.Generic.List[string]'
        if (Test-Path -LiteralPath $script:testBackup) { Remove-Item -LiteralPath $script:testBackup -Force }
        [IO.File]::WriteAllBytes($script:testShortcut,[byte[]]@(3,4,5))
    }
    Test 'Registration failure keeps original startup shortcut and no new task' {
        Reset-Fixture
        $script:failRegister=$true
        Assert-Throws { Install-WeChatAutostart $repo $script:testExe } 'registration failure'
        Assert (Test-Path -LiteralPath $script:testShortcut)
        Assert ($null -eq $script:fakeTask)
        Assert (-not (Test-Path -LiteralPath $script:testBackup))
    }
    Test 'Successful installation saves path and current-user interactive principal before cleanup' {
        Reset-Fixture
        Install-WeChatAutostart $repo $script:testExe
        Assert ($script:events[0] -eq 'register')
        Assert (-not ($script:events -contains 'unregister'))
        Assert (-not (Test-Path -LiteralPath $script:testShortcut))
        Assert (Test-Path -LiteralPath $script:testBackup)
        Assert ($script:fakeTask.Actions[0].Arguments.Contains('-WeChatExe "'+$script:testExe+'"'))
        Assert ($script:fakeTask.Principal.LogonType -eq 'Interactive' -and $script:fakeTask.Principal.RunLevel -eq 'Limited')
        # Logon trigger/principal use the account name, not the SID: a SID fails when setup runs
        # via powershell.exe -File under Windows PowerShell 5.1 (HRESULT 0x80070057). The name still
        # uniquely identifies the current user; owner comparisons continue to resolve against the SID.
        $identity = Get-WeChatIdentity
        Assert ($script:fakeTask.Trigger.User -eq $identity.Name)
        Assert ($script:fakeTask.Principal.UserId -eq $identity.Name)
    }
    Test 'Updating installation retains original backup and rolls back old task on registration failure' {
        Reset-Fixture
        Install-WeChatAutostart $repo $script:testExe
        $original=[IO.File]::ReadAllBytes($script:testBackup)
        $script:oldFakeTask=$script:fakeTask
        $script:failRegister=$true
        Assert-Throws { Install-WeChatAutostart $repo $script:testExe } 'registration failure'
        Assert ($script:fakeTask -eq $script:oldFakeTask)
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:testBackup)) -eq [Convert]::ToBase64String($original))
    }
    Test 'Repeated installation preserves original shortcut backup for uninstall' {
        Reset-Fixture
        Install-WeChatAutostart $repo $script:testExe
        Install-WeChatAutostart $repo $script:testExe
        $backup=Import-Clixml -LiteralPath $script:testBackup
        Assert (@($backup.Shortcuts).Count -eq 1)
        Assert (Restore-WeChatStartup $backup)
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:testShortcut)) -eq 'AwQF')
    }
    Test 'Uninstall excludes old project auto-login shortcuts while rollback restores them' {
        Reset-Fixture
        $backup=Get-WeChatStartupSnapshot
        $backup.Shortcuts[0] | Add-Member -NotePropertyName IsAutoLogin -NotePropertyValue $true
        Remove-Item -LiteralPath $script:testShortcut -Force
        Assert (Restore-WeChatStartup $backup -ExcludeAutoLogin)
        Assert (-not (Test-Path -LiteralPath $script:testShortcut))
        Assert (Restore-WeChatStartup $backup)
        Assert (Test-Path -LiteralPath $script:testShortcut)
    }
    Test 'Uninstall restore does not overwrite a shortcut changed by the user' {
        Reset-Fixture
        Install-WeChatAutostart $repo $script:testExe
        $backup=Import-Clixml -LiteralPath $script:testBackup
        [IO.File]::WriteAllBytes($script:testShortcut,[byte[]]@(9))
        Assert (-not (Restore-WeChatStartup $backup))
        Assert ([IO.File]::ReadAllBytes($script:testShortcut)[0] -eq 9)
    }
    Test 'Reject backup owned by another user or pointing outside startup folder' {
        Reset-Fixture
        $backup=Get-WeChatStartupSnapshot
        $backup.UserSid='S-1-5-18'; Assert-Throws { Assert-WeChatBackup $backup }
        $backup.UserSid=(Get-WeChatIdentity).User.Value
        $backup.Shortcuts[0].Path=Join-Path $scratch 'outside.lnk'
        Assert-Throws { Assert-WeChatBackup $backup }
    }
    Test 'Do not update a running scheduled task' {
        Reset-Fixture
        Install-WeChatAutostart $repo $script:testExe
        $script:fakeTask.State='Running'
        Assert-Throws { Install-WeChatAutostart $repo $script:testExe } 'currently running'
    }
    Test 'Newly registered task is removed and shortcut restored if cleanup fails' {
        Reset-Fixture
        function Remove-Item { [CmdletBinding()]param($LiteralPath,[switch]$Force) if ($LiteralPath -eq $script:testShortcut) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force; throw 'simulated cleanup failure' }; Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force }
        Assert-Throws { Install-WeChatAutostart $repo $script:testExe } 'cleanup failure'
        Assert ($null -eq $script:fakeTask)
        Assert (Test-Path -LiteralPath $script:testShortcut)
        Assert ($script:events -contains 'unregister')
    }
    Test 'Cleanup failure during update restores previous task and original backup bytes' {
        Reset-Fixture
        Install-WeChatAutostart $repo $script:testExe
        $script:oldFakeTask=$script:fakeTask
        $original=[IO.File]::ReadAllBytes($script:testBackup)
        [IO.File]::WriteAllBytes($script:testShortcut,[byte[]]@(3,4,5))
        function Remove-Item { [CmdletBinding()]param($LiteralPath,[switch]$Force) if ($LiteralPath -eq $script:testShortcut) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force; throw 'simulated cleanup failure' }; Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force }
        Assert-Throws { Install-WeChatAutostart $repo $script:testExe } 'cleanup failure'
        Assert ($script:fakeTask -eq $script:oldFakeTask)
        Assert (Test-Path -LiteralPath $script:testShortcut)
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:testBackup)) -eq [Convert]::ToBase64String($original))
    }
    # Run actual installer/uninstaller entry logic with fixture-native command doubles.
    # Translate exit only so a failure cannot end this runner; substitute the source root for scriptblock execution.
    $setupSource=(Get-Content -LiteralPath (Join-Path $repo 'setup.ps1') -Raw).Replace('. (Join-Path $PSScriptRoot ''wechat_common.ps1'')','').Replace('$PSScriptRoot','$repo').Replace('exit 1','throw ''InstallerFailed''')
    $setupBlock=[scriptblock]::Create($setupSource)
    Test 'Setup deploys all dependencies to a new directory and schedules that copy' {
        Reset-Fixture
        $target=Join-Path $scratch 'deployed'
        & $setupBlock -SetupDir $target -WeChatExe $script:testExe
        foreach ($file in @('wechat_autologin.ps1','wechat_common.ps1','setup.ps1','install_autostart.ps1','uninstall.ps1','README.md')) {
            Assert (Test-Path -LiteralPath (Join-Path $target $file)) "Missing $file"
        }
        Assert ($script:fakeTask.Actions[0].WorkingDirectory -eq $target)
        Assert ($script:fakeTask.Actions[0].Arguments.Contains((Join-Path $target 'wechat_autologin.ps1')))
    }
    Test 'Setup failure restores existing destination files and removes newly deployed files' {
        Reset-Fixture
        $target=Join-Path $scratch 'failed-deploy'
        [void](New-Item -ItemType Directory -Path $target)
        $existing=Join-Path $target 'wechat_autologin.ps1'
        [IO.File]::WriteAllText($existing,'original-content')
        $script:failRegister=$true
        Assert-Throws { & $setupBlock -SetupDir $target -WeChatExe $script:testExe 2>$null } 'InstallerFailed'
        Assert ([IO.File]::ReadAllText($existing) -eq 'original-content')
        Assert (@(Get-ChildItem -LiteralPath $target -File).Count -eq 1)
        Assert (Test-Path -LiteralPath $script:testShortcut)
    }
    $uninstallSource=(Get-Content -LiteralPath (Join-Path $repo 'uninstall.ps1') -Raw).Replace('. (Join-Path $PSScriptRoot ''wechat_common.ps1'')','').Replace('exit 1','throw ''UninstallFailed''')
    $uninstallBlock=[scriptblock]::Create($uninstallSource)
    function Stop-ScheduledTask { [CmdletBinding()]param($TaskName,$TaskPath) $script:events.Add('stop'); $script:fakeTask.State='Ready' }
    Test 'Uninstall removes own task and restores original startup without deleting unrelated entries' {
        Reset-Fixture
        Install-WeChatAutostart $repo $script:testExe
        $unrelated=Join-Path $script:testStartup 'other.lnk'; [IO.File]::WriteAllBytes($unrelated,[byte[]]@(8))
        & $uninstallBlock
        Assert ($null -eq $script:fakeTask)
        Assert (Test-Path -LiteralPath $script:testShortcut)
        Assert (Test-Path -LiteralPath $unrelated)
        Assert (-not (Test-Path -LiteralPath $script:testBackup))
    }
    Test 'Uninstall KeepBackup permits deferred startup restoration' {
        Reset-Fixture
        Install-WeChatAutostart $repo $script:testExe
        & $uninstallBlock -KeepBackup
        Assert ($null -eq $script:fakeTask)
        Assert (-not (Test-Path -LiteralPath $script:testShortcut))
        Assert (Test-Path -LiteralPath $script:testBackup)
        & $uninstallBlock
        Assert (Test-Path -LiteralPath $script:testShortcut)
    }
    Test 'Uninstall stops a running own task before removing it' {
        Reset-Fixture
        Install-WeChatAutostart $repo $script:testExe
        $script:fakeTask.State='Running'
        & $uninstallBlock
        $stopIndex=$script:events.IndexOf('stop'); $removeIndex=$script:events.IndexOf('unregister')
        Assert ($stopIndex -ge 0 -and $removeIndex -gt $stopIndex)
    }
} finally {
    # Verify the resolved target is this test's own scratch directory before deletion.
    $resolved=[IO.Path]::GetFullPath($scratch)
    $root=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if ($resolved.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "Tests: $script:passes passed, $script:failures failed."
if ($script:failures) { exit 1 }
