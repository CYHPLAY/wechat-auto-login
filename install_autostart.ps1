# ============================================================
# 一键安装开机自启（install_autostart.ps1）
# ------------------------------------------------------------
# 只创建“一个”开机自启入口：
#   WeChatAutoLogin.lnk -> 开机立即隐藏运行 wechat_autologin.ps1
# 微信本体由该脚本负责幂等启动（进程已在就不重复启动），因此：
#   * 不再创建单独启动微信的 WeChat.lnk；
#   * 自动清理旧的重复启动项（启动文件夹里的 WeChat.lnk / 微信.lnk 等）；
#   * 自动移除微信写在注册表 HKCU\...\Run 里的开机自启（Weixin/WeChat），
#     避免“注册表 + 启动文件夹 + 脚本”三处同时拉起微信而多开。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File install_autostart.ps1
# 编码：本文件含中文注释，请用 UTF-8（带 BOM）保存。
# ============================================================

$ErrorActionPreference = 'Stop'

$scriptDir  = $PSScriptRoot                                       # 本脚本所在目录
$mainScript = Join-Path $scriptDir "wechat_autologin.ps1"         # 主脚本（同目录）

if (-not (Test-Path $mainScript)) {
    Write-Host "[ERROR] 未找到同目录下的 wechat_autologin.ps1。" -ForegroundColor Red
    exit 1
}

$startup = [Environment]::GetFolderPath('Startup')   # 当前用户启动文件夹
$ws = New-Object -ComObject WScript.Shell

# 1) 清理“启动文件夹”里旧的、会直接启动微信本体的重复快捷方式
$legacyNames = @('WeChat.lnk', '微信.lnk', 'Weixin.lnk', '微信自动登录.lnk')
foreach ($name in $legacyNames) {
    $p = Join-Path $startup $name
    if (Test-Path $p) {
        Remove-Item $p -Force
        Write-Host "[CLEAN] 删除重复的开机启动项: $name" -ForegroundColor Yellow
    }
}

# 2) 移除注册表中微信自带的开机自启（HKCU\...\Run 的 Weixin / WeChat）
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
foreach ($v in @('Weixin', 'WeChat')) {
    $existing = Get-ItemProperty -Path $runKey -Name $v -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Remove-ItemProperty -Path $runKey -Name $v -ErrorAction SilentlyContinue
        Write-Host "[CLEAN] 移除注册表开机自启项: $v" -ForegroundColor Yellow
    }
}

# 3) 只创建一个自启项：开机立即隐藏运行自动登录脚本（无固定延迟，脚本内部智能等待）
$lnkAuto = Join-Path $startup "WeChatAutoLogin.lnk"
$s = $ws.CreateShortcut($lnkAuto)
$s.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$s.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mainScript`""
$s.WorkingDirectory = $scriptDir
$s.WindowStyle = 7
$s.Description = "WeChat auto login (single entry)"
$s.Save()

Write-Host ""
Write-Host "[OK] 已设置唯一开机自启入口:" -ForegroundColor Green
Write-Host "     WeChatAutoLogin.lnk -> $mainScript"
Write-Host "     开机会由该脚本自动启动微信并登录，不会再多开。"
Write-Host "提示：请在手机端登录确认页勾选“自动登录该设备”。" -ForegroundColor Gray
