# wechat-auto-login

Windows 微信开机自动登录：登录 Windows 后自动启动微信，**检测到绿色“进入WeChat”按钮就绪再点击**进入主界面。纯 PowerShell + 系统 API，**零第三方依赖**，自动适配分辨率 / DPI / 微信安装位置，不会多开。

## 一键安装

**最简单：双击 `WeChatAutoLoginSetup.exe`**，自动识别微信并安装到当前用户，无需命令行、不装任何依赖。

或用命令行，在项目目录打开 PowerShell 运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -SetupDir "$env:LOCALAPPDATA\WeChatAutoLogin\app"
```

两种方式都会自动找到微信、复制脚本、创建登录计划任务 `WeChatAutoLogin`、清理重复开机项；装完下次开机登录即自动登录微信。

> 微信装在非默认位置时，命令行方式追加 `-WeChatExe "完整路径\Weixin.exe"`。

## 手动测试

```powershell
# 立即触发一次（等同开机）
Start-ScheduledTask -TaskName 'WeChatAutoLogin'
# 查看运行日志
Get-Content "$env:LOCALAPPDATA\WeChatAutoLogin\autologin.log" -Tail 30
```

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\WeChatAutoLogin\app\uninstall.ps1"
```

删除计划任务并恢复安装前的开机项；脚本文件保留，可自行删除安装目录。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `WeChatAutoLoginSetup.exe` | 一键安装程序，双击即可（推荐） |
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
