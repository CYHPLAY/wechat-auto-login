# wechat-auto-login

微信 PC 版开机自启自动登录工具 —— 自动点击"进入WeChat"，配合微信"自动登录"实现打开即登录。

## 功能

- 开机自启微信
- 自动检测微信登录窗口
- 自动点击"进入WeChat"按钮进入主界面
- **零第三方依赖**（纯 PowerShell + Windows user32 API）
- **分辨率 / DPI 自适应**：按钮定位采用窗口内**相对比例**，不依赖写死的屏幕坐标，在不同分辨率、不同缩放（DPI）的屏幕上均可准确定位
- **参数化**：微信路径、按钮相对位置、等待超时均可配置

## 原理

微信登录界面是自绘 UI（MMUI/Qt），**不接受后台消息注入**，只能通过真实鼠标输入触发。脚本流程：

1. 启动微信（若未运行）
2. 轮询检测登录窗口
3. 激活窗口
4. 读取窗口尺寸，用**相对比例**定位"进入WeChat"按钮（默认按钮中心约为渲染区域的 49.8%、77.3%）
5. 真实鼠标输入点击（SetCursorPos + mouse_event）
6. 点击后静默退出

> 提示：请在微信登录时勾选**"自动登录该设备"**（手机端），这样点击"进入WeChat"后无需手机确认。

## 文件

| 文件 | 说明 |
| --- | --- |
| `wechat_autologin.ps1` | 主脚本：自动启动微信并点击进入 |
| `install_autostart.ps1` | 一键安装开机自启 |

## 使用

### 手动运行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File wechat_autologin.ps1
```

### 一键安装开机自启

```powershell
powershell -ExecutionPolicy Bypass -File install_autostart.ps1
```

该脚本会在启动文件夹创建两个快捷方式：

- `WeChat.lnk` —— 开机启动微信
- `WeChatAutoLogin.lnk` —— 开机隐藏运行自动登录脚本

### 参数

`wechat_autologin.ps1`：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-WeChatExe` | `D:\WeChat\Weixin\Weixin.exe` | 微信程序路径 |
| `-WeChatDir` | `D:\WeChat\Weixin` | 微信工作目录 |
| `-TimeoutSec` | `30` | 等待登录窗口的超时（秒） |
| `-BtnX` / `-BtnY` | `0.498` / `0.773` | "进入WeChat"按钮相对位置（不同机器可按需微调） |

`install_autostart.ps1`：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-WeChatExe` | `D:\WeChat\Weixin\Weixin.exe` | 微信程序路径 |

## 注意事项

- 脚本使用**真实鼠标输入**，点击时鼠标指针会移动到按钮上（这是微信自绘界面唯一可靠的触发方式）。
- 微信"自动登录"需先在**手机端**开启：登录电脑微信时，在手机确认页勾选"自动登录该设备"。
- 只建议在**自己的常用电脑**上启用自动登录，避免隐私泄露。
- 两个脚本均为**纯 ASCII**，兼容 Windows PowerShell 5.1（避免无 BOM 的 UTF-8 中文被误解析）。
