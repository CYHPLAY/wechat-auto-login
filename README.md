# wechat-auto-login

微信 PC 版开机自启自动登录工具 —— 自动点击"进入WeChat"，配合微信"自动登录"实现打开即登录。

## 功能

- 开机自启微信
- 自动检测微信登录窗口
- 自动点击"进入WeChat"按钮进入主界面
- **零第三方依赖**（纯 PowerShell + Windows user32 API）
- **分辨率 / DPI 自适应**：按钮定位采用窗口内**相对比例**，不依赖写死的屏幕坐标，在不同分辨率、不同缩放（DPI）的屏幕上均可准确定位。

## 原理

微信登录界面是自绘 UI（MMUI/Qt），**不接受后台消息注入**，只能通过真实鼠标输入触发。脚本流程：

1. 启动微信（若未运行）
2. 轮询检测登录窗口
3. 激活窗口
4. 通过窗口句柄读取登录窗口尺寸，用**相对比例**定位"进入WeChat"按钮（按钮中心约为渲染区域的 49.8%、77.3%）
5. 真实鼠标输入点击（SetCursorPos + mouse_event）

> 提示：请在微信登录时勾选**"自动登录该设备"**（手机端），这样点击"进入WeChat"后无需手机确认。

## 文件

| 文件 | 说明 |
| --- | --- |
| `wechat_autologin.ps1` | 主脚本：自动启动微信并点击进入 |
| `install_autostart.ps1` | 一键安装开机自启（含微信启动 + 自动点击） |

## 使用

### 手动运行

```powershell
powershell -ExecutionPolicy Bypass -File wechat_autologin.ps1
```

### 一键安装开机自启

```powershell
powershell -ExecutionPolicy Bypass -File install_autostart.ps1
```

如果微信不在 `D:\WeChat\Weixin\Weixin.exe`，用参数指定：

```powershell
powershell -ExecutionPolicy Bypass -File install_autostart.ps1 -WeChatExe "你的\Weixin.exe路径"
```

## 注意事项

- 脚本使用**真实鼠标输入**，点击时鼠标指针会移动到按钮上（这是微信自绘界面唯一可靠的触发方式）。
- 微信"自动登录"需先在**手机端**开启：登录电脑微信时，在手机确认页勾选"自动登录该设备"。
- 只建议在**自己的常用电脑**上启用自动登录，避免隐私泄露。
- 按钮定位使用**相对比例**而非绝对坐标，因此不同分辨率 / DPI 的机器均可直接使用，无需手动调整。
