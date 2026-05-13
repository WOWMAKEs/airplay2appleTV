# airplay2appleTV

一个 macOS 命令行工具，用来一键打开、关闭或切换到 Apple TV 的 AirPlay / 屏幕镜像。

> CLI 命令：`airplay-tv`

> 说明：Apple 没有公开稳定的 AirPlay 显示选择 CLI/API，所以这个工具使用 macOS 辅助功能自动化操作控制中心。首次使用需要给当前终端应用授权"辅助功能"。

## 编译

```sh
swift build
```

## 安装

```sh
chmod +x install.sh
./install.sh
```

## 首次授权

```sh
airplay-tv setup
```

然后在：

```text
系统设置 > 隐私与安全性 > 辅助功能
```

允许你的终端应用，例如 Terminal、iTerm2 或 Codex。

## 使用

默认操作第一个可用的 Apple TV（index 1）：

```sh
airplay-tv on      # 打开（如果已是打开状态，提示 "already on"）
airplay-tv off    # 关闭（如果已是关闭状态，提示 "already off"）
airplay-tv toggle # 切换
airplay-tv status # 查看当前状态
airplay-tv list   # 列出可用设备
```

指定设备索引：

```sh
airplay-tv on --index 2
airplay-tv off --index 2
```

指定设备名称：

```sh
airplay-tv on --device "Living Room Apple TV"
```

查看调试信息：

```sh
airplay-tv debug
```

## 环境变量

```sh
export AIRPLAY_TV_INDEX=1   # 默认使用第一个设备
```

## 一键调用示例

把下面内容放进 shell 配置文件，例如 `~/.zshrc`：

```sh
alias aptv='airplay-tv toggle'
alias aptv-on='airplay-tv on'
alias aptv-off='airplay-tv off'
alias aptv-status='airplay-tv status'
```

## 工作原理

- `on` / `off` 命令会先调用 `status` 检查当前状态，只有在需要时才执行切换
- 如果 UI 没有显示设备名称，会自动 fallback 使用索引 1
- 使用 macOS Control Center 的 Accessibility 自动化

## 常见问题

- 如果提示找不到 Screen Mirroring，请手动打开一次控制中心，确认"屏幕镜像"控件可见
- 不同 macOS 版本的控制中心结构可能不同。如果 Apple 更新了 UI，可能需要调整内嵌自动化脚本