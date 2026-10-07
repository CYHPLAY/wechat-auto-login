# wechat-auto-login

微信 PC 开机自动登录：登录 Windows 后由计划任务自动启动微信，**检测到绿色“进入WeChat”按钮就绪再点击**（通常 1 次命中）。零第三方依赖、不多开、不写死用户名/路径、适配任意分辨率和安装位置。

## 特点

- 计划任务“登录时”触发，**无开机启动延迟**；唯一入口、幂等启动，不会多开
- 微信路径自动识别（进程 → 常见目录 → 各盘符 → 注册表），分辨率 / DPI 自适应，按钮按窗口比例定位
- 用 `GetPixel` 取色确认按钮变绿才点击（不截图、不图像识别、不写死坐标），鼠标用完自动归位
- 纯 PowerShell + Win32 API，无需安装任何东西；脚本不含用户名、计算机名或固定路径

## 一键安装

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

自动识别微信、生成脚本、清理重复自启、创建计划任务 `WeChatAutoLogin`。

## 测试 / 卸载

```powershell
# 手动触发一次（等同开机自启）
Start-ScheduledTask -TaskName 'WeChatAutoLogin'

# 或直接运行主脚本
powershell -NoProfile -ExecutionPolicy Bypass -File wechat_autologin.ps1

# 卸载自启
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

## 文件

| 文件 | 作用 |
| --- | --- |
| `wechat_autologin.ps1` | 主脚本：自动找微信 → 检测按钮 → 点击登录 |
| `setup.ps1` | 一键安装（识别环境、生成脚本、建计划任务、去重） |
| `install_autostart.ps1` | 仅创建 / 更新计划任务 |
| `uninstall.ps1` | 删除计划任务与残留启动项 |

## 常用参数（`wechat_autologin.ps1`）

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-WeChatExe` | 自动查找 | 手动指定 `Weixin.exe` 完整路径 |
| `-BtnX` / `-BtnY` | `0.498` / `0.773` | 按钮中心相对位置，点不准时微调 |
| `-GreenRatio` | `0.30` | 绿色像素占比阈值，误判调大、检测不到调小 |
| `-DontLaunch` | 开关 | 只等待并点击，不主动启动微信 |

其余超时 / 重试参数见脚本顶部 `param`。

## 注意

- 首次需在手机端勾选“自动登录该设备”。
- 点击后微信还需几秒联网登录、加载主界面，与网速 / 机器性能有关，属正常。
- 计划任务以当前登录用户、普通权限运行，不弹 UAC，笔记本用电池也会运行。
- 脚本为 UTF-8 带 BOM（`setup.ps1` 自动生成），手动编辑请勿改编码。
