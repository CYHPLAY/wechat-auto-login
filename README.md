# wechat-auto-login

微信 PC 版开机自启自动登录工具 —— 自动点击"进入WeChat"，配合微信"自动登录"实现打开即登录。

## 功能

- 开机自启微信
- 自动检测微信登录窗口并点击"进入WeChat"进入主界面
- **更快**：事件驱动轮询 —— 窗口一出现就点击，确认进入主界面后立即退出，不做固定长等待
- **点击失败自动重试**：点击后校验窗口是否由竖版（登录）变为横版（主界面），未进入则重新点击，默认最多 3 次
- **鼠标自动归位**：登录完成后把鼠标指针移回点击前的位置，尽量不打扰你的操作
- **零第三方依赖**（纯 PowerShell + Windows user32 API）
- **分辨率 / DPI 自适应**：按钮定位采用窗口内相对比例，不写死屏幕坐标
- **一键部署 / 一键卸载**：`setup.ps1` 自动识别微信路径与物理分辨率；`uninstall.ps1` 干净移除自启

## 项目文件

| 文件 | 说明 |
| --- | --- |
| `wechat_autologin.ps1` | 主脚本：启动微信、点击进入、校验重试、鼠标归位（含中文注释） |
| `install_autostart.ps1` | 手动安装开机自启（创建两个启动快捷方式） |
| `setup.ps1` | **一键部署**：自动识别微信路径 + 物理分辨率，生成脚本（UTF-8 带 BOM）并配置自启 |
| `uninstall.ps1` | **一键卸载**：按目标匹配删除本项目创建的开机自启项，不误删其他启动项 |
| `README.md` | 项目说明（本文件） |

## 原理

微信登录界面是自绘 UI（MMUI/Qt），**不接受后台消息注入**，只能通过真实鼠标输入触发。脚本流程：

1. 启动微信（若未运行）
2. 快速轮询检测登录窗口（标题 WeChat + 可见 + 含 `MMUIRenderSubWindowHW` 渲染子窗口，且为竖版）
3. 记住当前鼠标位置，激活窗口
4. 读取窗口尺寸，用**相对比例**定位"进入WeChat"按钮（默认约为渲染区域的 49.8%、77.3%）
5. 真实鼠标输入点击（SetCursorPos + mouse_event）
6. 轮询校验是否变为横版主界面：是则成功；否则重试（默认 3 次）
7. 把鼠标移回原位并退出

> 提示：请在微信登录时勾选**"自动登录该设备"**（手机端），点击"进入WeChat"后即可免手机确认。

## 使用

### 一键部署（推荐）

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

自动完成：识别微信路径 → 识别物理分辨率 → 生成脚本（UTF-8 带 BOM）→ 配置开机自启。

### 手动

```powershell
# 运行一次主脚本（立即自动登录）
powershell -NoProfile -ExecutionPolicy Bypass -File wechat_autologin.ps1

# 安装开机自启
powershell -ExecutionPolicy Bypass -File install_autostart.ps1
```

### 卸载（移除开机自启）

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

## 参数

`wechat_autologin.ps1`：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-WeChatExe` | `D:\WeChat\Weixin\Weixin.exe` | 微信程序路径 |
| `-WeChatDir` | `D:\WeChat\Weixin` | 微信工作目录 |
| `-TimeoutSec` | `30` | 等待登录窗口超时（秒） |
| `-BtnX` / `-BtnY` | `0.498` / `0.773` | "进入WeChat"按钮相对位置（点不准时可微调） |
| `-MaxRetries` | `3` | 点击失败后的最大尝试次数 |
| `-RestoreMouse` | `$true` | 登录完成后是否把鼠标移回原位 |

`install_autostart.ps1`：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-WeChatExe` | `D:\WeChat\Weixin\Weixin.exe` | 微信程序路径 |

## 注意事项

- 脚本使用**真实鼠标输入**，点击瞬间指针会移动到按钮上，登录完成后会自动移回原位（可用 `-RestoreMouse $false` 关闭归位）。
- "自动登录"需先在**手机端**开启：登录电脑微信时，在手机确认页勾选"自动登录该设备"。
- 只建议在**自己的常用电脑**上启用自动登录。
- 按钮定位使用**相对比例**，不同分辨率 / DPI 的机器可直接使用；若个别微信版本按钮位置有偏差，可用 `-BtnX`/`-BtnY` 微调。

## 编码说明

- 脚本含**中文注释**，需使用 **UTF-8（带 BOM）** 编码保存。
- `setup.ps1` 生成的 `wechat_autologin.ps1` **自动带 BOM**，Windows PowerShell 5.1 下不会乱码。
- 若你手动编辑后在 PowerShell 5.1 打开出现乱码：用记事本"另存为"→ 编码选 `UTF-8（带 BOM）`；PowerShell 7 / VS Code 通常无此问题。
