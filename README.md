# wechat-auto-login

微信 PC 版开机自启自动登录工具 —— 自动点击"进入WeChat"，配合微信"自动登录"实现打开即登录。

## 功能

- 开机自启微信
- 自动检测微信登录窗口
- 自动点击"进入WeChat"按钮进入主界面
- **零第三方依赖**（纯 PowerShell + Windows user32 API）
- **分辨率 / DPI 自适应**：按钮定位采用窗口内**相对比例**，不依赖写死的屏幕坐标，在不同分辨率、不同缩放（DPI）的屏幕上均可准确定位
- **参数化**：微信路径、按钮相对位置、等待超时均可配置
- **一键部署**：`setup.ps1` 自动识别微信安装位置和物理分辨率，一条命令完成部署

## 项目文件

| 文件 | 说明 |
| --- | --- |
| `wechat_autologin.ps1` | 主脚本：自动启动微信并点击进入（含中文注释） |
| `install_autostart.ps1` | 安装开机自启：创建两个启动快捷方式（含中文注释） |
| `setup.ps1` | 一键部署：自动识别微信路径 + 物理分辨率，生成脚本并配置自启（含中文注释） |
| `README.md` | 项目说明（本文件） |

## 原理

微信登录界面是自绘 UI（MMUI/Qt），**不接受后台消息注入**，只能通过真实鼠标输入触发。脚本流程：

1. 启动微信（若未运行）
2. 轮询检测登录窗口（标题 WeChat + 可见 + 含 `MMUIRenderSubWindowHW` 渲染子窗口）
3. 激活窗口
4. 读取窗口尺寸，用**相对比例**定位"进入WeChat"按钮（默认按钮中心约为渲染区域的 49.8%、77.3%）
5. 真实鼠标输入点击（SetCursorPos + mouse_event）
6. 点击后静默退出

> 提示：请在微信登录时勾选**"自动登录该设备"**（手机端），这样点击"进入WeChat"后无需手机确认。

## 使用

### 方式一：一键部署（推荐）

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

自动完成：识别微信路径 → 识别物理分辨率 → 生成脚本 → 配置开机自启。

### 方式二：手动

1. 手动运行主脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File wechat_autologin.ps1
```

2. 安装开机自启：

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
- 按钮定位使用**相对比例**而非绝对坐标，因此不同分辨率 / DPI 的机器均可直接使用，无需手动调整。

## 编码说明（重要）

- 三个 `.ps1` 脚本均包含**中文注释**，请使用 **UTF-8（带 BOM）** 编码保存。
- 若在 Windows PowerShell 5.1 中打开出现乱码或报错，用**记事本打开 → 另存为 → 编码选择 `UTF-8（带 BOM）`**，保存后重新运行即可。
- 如果使用 PowerShell 7（pwsh）或 VS Code，通常不会遇到此问题。
