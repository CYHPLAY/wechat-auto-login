# wechat-auto-login

Windows 微信开机自动登录：登录 Windows 后自动启动微信，**检测到绿色“进入WeChat”按钮就绪再点击**进入主界面。纯 PowerShell + 系统 API，**零第三方依赖**，自动适配分辨率 / DPI / 微信安装位置，不会多开。

## 一键安装（推荐）

**双击 `WeChatAutoLoginSetup.exe`** 打开管理菜单，按数字选择：

- `1` 安装 / 修复：自动找微信、复制脚本、创建登录计划任务 `WeChatAutoLogin`、清理重复开机项
- `2` 立即测试：等同开机触发一次，并显示结果
- `3` 卸载：移除计划任务、恢复安装前的开机项
- 菜单顶部显示安装状态、微信路径、开机自启入口数量；发现多个入口会提示多开风险

装完下次开机登录即自动登录微信，全程不装任何依赖。自动化可静默运行：`WeChatAutoLoginSetup.exe install -silent`（另支持 `test` / `uninstall` / `status`）。

> 不想用 exe，也可在项目目录运行 PowerShell：
> `powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -SetupDir "$env:LOCALAPPDATA\WeChatAutoLogin\app"`
> 微信装在非默认位置时追加 `-WeChatExe "完整路径\Weixin.exe"`。

## 日志与命令行卸载

```powershell
# 查看运行日志
Get-Content "$env:LOCALAPPDATA\WeChatAutoLogin\autologin.log" -Tail 30
# 命令行卸载（与 exe 菜单的“卸载”等效）
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\WeChatAutoLogin\app\uninstall.ps1"
```

卸载会删除计划任务并恢复安装前的开机项；脚本文件保留，可自行删除安装目录。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `WeChatAutoLoginSetup.exe` | 一键管理程序，双击打开菜单（推荐） |
| `manager.ps1` | 管理菜单：状态 / 重复检测 / 安装 / 测试 / 卸载（随 exe 释放） |
| `setup.ps1` | 命令行一键安装 |
| `uninstall.ps1` | 卸载并恢复原开机项 |
| `wechat_autologin.ps1` | 主程序：启动微信、检测按钮、点击登录 |
| `wechat_common.ps1` | 公共函数（被其它脚本调用，勿单独运行） |
| `install_autostart.ps1` | 可选：不复制文件，仅在当前目录创建计划任务 |
| `Installer.cs` | 安装程序源码（用系统自带编译器生成，普通用户可忽略） |
| `tests/` | 开发用回归测试，普通用户可忽略 |

## 使用前提

- Windows 10 / 11 + 系统自带的 Windows PowerShell 5.1；首次需在手机端勾选“自动登录该设备”。
- 需要登录到已解锁的桌面；锁屏或 UAC 安全桌面下不会执行点击。
- 不写死用户名或路径：微信路径运行时自动查找，计划任务以当前用户、普通权限运行。
- exe 未做数字签名，首次运行若出现 SmartScreen 提示，选择“更多信息 → 仍要运行”即可。
- 点击后微信仍需几秒联网登录，与网速 / 机器性能有关，属正常现象。
