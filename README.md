# wechat-auto-login

Windows 微信自动登录工具：登录 Windows 后自动启动微信，等待绿色登录按钮就绪，再点击进入主界面。采用 PowerShell + Windows 原生 API，无第三方运行依赖。

适合已在手机端授权自动登录的 Windows 微信用户，减少每次开机后手动启动和点击登录的步骤。

## 功能亮点

- **开机自启**：通过当前用户的登录计划任务运行，支持自动识别微信路径和手动指定安装位置。
- **先检测再点击**：核对窗口、按钮颜色和遮挡状态，确认按钮可见后再操作鼠标。
- **避免重复启动**：同会话脚本互斥，已有微信进程时不再重复拉起。
- **方便排错**：记录启动、检测、点击和结果日志，失败时返回明确状态。
- **安装可恢复**：清理重复自启前备份，安装失败回滚，卸载恢复原微信自启。

已通过 39 项回归测试，并在一次关闭微信后重新启动、自动点击登录的实机测试中确认主界面出现。适用范围和操作条件见下文。

## 使用条件与兼容范围

- Windows 10 / 11，Windows PowerShell 5.1，建议使用系统自带的 64 位 `powershell.exe`。
- 已在手机端授权该设备自动登录。首次扫码、设备验证、需要手机确认的情况仍需手动处理。
- 当前适配原项目使用的 `MMUIRenderSubWindowHW` 渲染类与纵向登录窗口布局。**检测到了安装路径，并不等于支持该微信版本的界面。**旧版微信或未来改版可能超时，不会盲目点击。
- 需要当前用户的已解锁交互桌面。锁屏、UAC 安全桌面、已断开的远程桌面不适合执行鼠标自动化。
- 使用窗口比例定位，优先启用每显示器 DPI 感知；混合 DPI、多显示器和具体微信版本仍需实机验证。

“完成”的判据是同会话中的受支持主窗口连续三次出现、登录窗口消失；它是界面启发式判断，无法证明服务器认证成功。主窗口宽度需至少 500、高度至少 300 且宽大于高。

## 安装

下载完整项目并解压，进入项目目录后运行。建议部署到稳定的本地目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -SetupDir "$env:LOCALAPPDATA\WeChatAutoLogin\app"
```

自动识别失败或安装位置特殊时，明确指定微信程序：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 `
    -SetupDir "$env:LOCALAPPDATA\WeChatAutoLogin\app" `
    -WeChatExe "D:\软件\Weixin\Weixin.exe"
```

省略 `-SetupDir` 时安装位置就是当前项目目录，**安装后不能直接移动或删除它**；移动前请从新目录重新安装。指定的新目录会被创建。主脚本只有一份，安装时直接复制，不再生成内嵌副本。

安装器会：

1. 校验程序路径和必要文件，将路径保存在计划任务参数中。
2. 备份需要清理的微信原生自启及旧自动登录快捷方式。
3. 创建或更新 `WeChatAutoLogin`，限定当前用户登录触发、交互桌面、普通权限、电池可运行。
4. 新任务注册成功后，才清理快捷方式和 HKCU Run 中的重复来源；按真实目标匹配，不按快捷方式名称删除。
5. 失败时恢复任务、已清理入口及部署时覆盖的文件；恢复受权限或配置冲突阻碍时保留备份并输出原因。

不需要主动以管理员身份运行；若系统策略拒绝注册任务，请查看错误输出。已有同名任务属于其他用户或用途时会拒绝覆盖。任务不设置额外登录延迟，但 Windows 调度、微信启动与联网仍需要时间。

如果无需复制文件，只想对当前项目目录安装自启：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install_autostart.ps1 -WeChatExe "D:\软件\Weixin\Weixin.exe"
```

## 测试与日志

安装后手动触发计划任务（会启动微信并可能操作鼠标）：

```powershell
Start-ScheduledTask -TaskName 'WeChatAutoLogin'
Get-ScheduledTaskInfo -TaskName 'WeChatAutoLogin'
Get-Content "$env:LOCALAPPDATA\WeChatAutoLogin\autologin.log" -Tail 50
```

也可前台直接运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\wechat_autologin.ps1 -WeChatExe "D:\软件\Weixin\Weixin.exe"
```

前台直接运行不会自动读取已安装任务中的路径；省略路径时会重新自动查找。日志默认保存在 `%LOCALAPPDATA%\WeChatAutoLogin\autologin.log`，超过 1 MiB 后轮转到 `.log.1`，仅保留一份历史日志。

退出码：`0` 表示受支持主窗口已确认，或已有同会话脚本运行而跳过；`1` 表示超时、异常或未完成。参数绑定错误也会由 PowerShell 返回失败。

## 自动化行为

- 同用户同会话互斥，手动运行与计划任务不会同时点击。
- 仅查找当前 Windows 会话的微信进程；已有进程不会通过再次执行 EXE 来“唤起”。每次脚本至多主动启动一次。
- 先确认解锁桌面并激活窗口，再取色。所有采样点都须属于目标窗口；点击前再次核对颜色、窗口归属和前台状态。
- 若窗口被遮挡、失去前台、按钮变化或进程退出，跳过点击或报错；登录窗口消失本身不会被当成成功。
- 点击后等待主界面，默认最多 30 秒，再决定是否重试。总运行预算 270 秒，计划任务限制 5 分钟。
- 每次点击后立即恢复鼠标位置；异常路径也尝试释放按键、恢复位置。

全局鼠标输入仍存在极短的检查与点击竞态。执行时尽量避免同时操作鼠标，不应将其用于需要完全无人干预保证的场景。

## 参数（主脚本）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-WeChatExe` | 自动查找 | 微信 EXE 完整路径；明确给出的无效路径会报错 |
| `-WeChatDir` | EXE 所在目录 | 启动工作目录 |
| `-BtnX` / `-BtnY` | `0.498` / `0.773` | 按钮中心的窗口比例，范围 0.01–0.99 |
| `-GreenRatio` | `0.30` | 绿色采样点比例阈值，范围 0.01–1 |
| `-WindowTimeoutSec` | `30` | 等待受支持登录窗的秒数，范围 1–120 |
| `-ButtonTimeoutSec` | `60` | 每次等待绿色按钮的秒数，范围 1–120 |
| `-LoginTimeoutSec` | `30` | 每次点击后等待主界面的秒数，范围 1–120 |
| `-MaxRetries` | `5` | 最多尝试次数，范围 1–10，仍受总运行预算限制 |
| `-MinReadyMs` | `250` | 窗口稳定后的最短等待毫秒数，范围 0–10000 |
| `-ReviveGraceSec` | `12` | 兼容原参数；已有进程消失后首次检查时间，范围 0–120 |
| `-ReviveIntervalSec` | `8` | 兼容原参数；检查进程间隔，范围 1–120，不再重复拉起已有进程 |
| `-RestoreMouse` | `$true` | 是否恢复鼠标；需以 PowerShell 表达式方式传入布尔值 |
| `-DontLaunch` | 关闭 | 只等待外部启动微信 |
| `-LogPath` | 当前用户日志目录 | 自定义日志文件完整路径 |

## 卸载与恢复

在安装目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

删除本项目任务，恢复安装前备份的微信原生自启；不会恢复旧的本项目自动登录快捷方式，防止卸载后重新启用自动登录。不会删除后来新增的微信自启或其他软件入口。若原位置已有不同快捷方式/Run 值，会保留现状和备份并报告冲突，避免覆盖用户后续修改。

备份位于 `%LOCALAPPDATA%\WeChatAutoLogin\autostart-backup.clixml`，重复安装保留最初备份并补充新的入口。`-KeepBackup` 只删除任务，暂不恢复旧自启，也不删除备份；稍后可再次运行卸载恢复。项目文件和日志保留，可在卸载完成后自行删除安装目录。

从旧版迁移时，旧版已经删除且没有备份的原入口无法恢复；可在微信设置中重新启用微信原生开机启动。

## 故障排查

- 找不到微信：使用 `-WeChatExe`；移动微信安装位置后重新安装计划任务。
- 找不到登录窗：确认微信界面版本受支持、当前桌面已解锁、远程会话在线。
- 找不到绿色按钮：先手动确认设备授权和登录按钮布局，再调整比例或阈值；不支持的布局不要靠降低阈值强行适配。
- 激活窗口失败：确认微信与脚本以同一用户、相同普通权限运行。
- 安装失败：查看终端错误。若回滚不完整，保留备份，排除权限或冲突后运行卸载恢复。

## 开发验证

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

测试采用原函数与 Win32/计划任务替身，临时文件仅在测试目录中创建并清理，**不会启动微信、操作真实鼠标或修改真实自启配置**。覆盖登录误判、焦点变化、桌面遮挡、鼠标恢复、路径持久化、安装回滚和备份恢复。GitHub Actions 使用 Windows PowerShell 5.1 执行同一套测试。

这些测试不能替代具体微信版本、手机授权、真实 Task Scheduler 权限与多显示器 DPI 的实机测试。所有 `.ps1` 文件使用 UTF-8 BOM 保存，以兼容 Windows PowerShell 5.1 的中文解码。

## 文件

| 文件 | 作用 |
| --- | --- |
| `wechat_autologin.ps1` | 窗口检测、按钮验证、点击与日志 |
| `wechat_common.ps1` | 路径识别、任务安装与备份恢复 |
| `setup.ps1` | 部署文件并安装自启 |
| `install_autostart.ps1` | 在当前目录安装自启 |
| `uninstall.ps1` | 删除任务并恢复原生自启 |
| `tests/run-tests.ps1` | 不接触真实自启的回归测试 |
