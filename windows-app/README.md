# AIClockBridge for Windows

`mac-app/` 菜单栏桥接的 Windows 移植版：同一套功能、同一套设备协议（固件感知不到
桥接跑在哪个系统上），以系统托盘图标形式常驻。

功能与 Mac 版一致：

- **左键托盘图标** → ESP32-C3 / ESP8266 屏幕实时镜像（额度环 + 桌宠动画 + 网速图 + 音乐页 + 行情页，
  与设备渲染同一份数据），底部附 自动/Claude/Codex/网速/音乐/行情 快速切换
- **右键托盘图标** → 控制菜单：Claude 5h/周额度、Codex Weekly 额度、今日 Token 与折算金额、
  自动查找并配对设备、设置设备地址、屏幕显示模式、petdex 桌宠画廊、恢复默认动画、
  把本机设为设备桥接、桥接服务地址
- 本地 HTTP 服务 `0.0.0.0:8765`：`/status`、`/net`、`/music`、`/music/cover.raw`、
  `/music/text.raw`、`/btc`、`/btc/version`、`/btc/frame.rle`、`POST /event`
  （Claude Code / Codex hooks 秒级状态推送）
- 数据来源同 Mac 版：`%USERPROFILE%\.claude\projects` / `%USERPROFILE%\.codex\sessions`
  的 JSONL 日志 + 各自官方用量接口（凭据读
  `%USERPROFILE%\.claude\.credentials.json` 和 `%USERPROFILE%\.codex\auth.json`，
  token 只发给各自官方 API）
- 音乐页读系统级 Now Playing（WinRT `GlobalSystemMediaTransportControlsSessionManager`，
  Spotify / 浏览器 / 本地播放器都能识别）；网速取物理网卡（以太网/WiFi）字节计数，
  4Hz 采样，排除 VPN/虚拟网卡
- 行情支持 BTC/ETH、A股、港股、美股、韩股及常用指数，1/5/60 分钟 K线，
  10/30/60/120 秒轮换；帧在后台预取、渲染并压缩，切换时一次更新
- AUTO 根据最近真实活动选择 Claude Code / Codex；Fast / Priority 模式每次执行任务触发
  2.4 秒 Ludicrous 动画，当日统计窗口为本机时间 00:01–23:59

与 Mac 版的差异：

- 无固件刷写入口（刷写请用网页版刷写工具）
- 唯一的第三方依赖是 [ImageSharp](https://github.com/SixLabors/ImageSharp)——
  System.Drawing 解不了 petdex 的 WebP 精灵图、也编不了多帧 GIF

## 构建 / 运行

需要 [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)（Windows 10
19041+ / Windows 11）：

```powershell
cd windows-app\AIClockBridge
dotnet run                # 前台运行（托盘出现小电脑图标）
# 或发布无需预装 .NET 的单文件：
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
# 产物在 bin\Release\net8.0-windows10.0.19041.0\win-x64\publish\AIClockBridge.exe
```

首次启动 Windows 会弹防火墙授权（HTTP 服务监听 0.0.0.0:8765，设备要从局域网访问，
选"允许"）。

**开机自启**：`Win+R` → `shell:startup` → 把 `AIClockBridge.exe` 的快捷方式放进去。

**Hooks 实时状态**（可选，同主 README §7）：Claude Code / Codex 的 hooks 往
`http://127.0.0.1:8765/event` POST 事件即可，Windows 下 curl 自带。

## 验证

```powershell
curl.exe -s http://localhost:8765/status | python -m json.tool
```

配置持久化在 `%APPDATA%\AIClockBridge\settings.json`（设备地址等）。

## 代码结构

| 文件 | 对应 Mac 版 | 说明 |
|---|---|---|
| `Program.cs` | `main.swift` | 入口 + 路由表 + 被动发现 |
| `TrayAppContext.cs` | `MenuBarController.swift` | 托盘图标 + 控制菜单 |
| `MirrorForm.cs` | `MirrorPopover.swift` | 240x240 屏幕镜像弹窗 |
| `PetPickerForm.cs` | `PetPickerWindow.swift` | petdex 桌宠选择器 |
| `PetdexService.cs` | `PetdexService.swift` | manifest / 精灵图 / GIF 合成 |
| `StatusService.cs` | `StatusReader.swift` | 后台 JSONL 扫描 + Token/金额 + Fast 任务事件 |
| `UsageFetcher.cs` | `UsageFetcher.swift` | 官方额度接口 |
| `ModelPricing.cs` | `ModelPricing.swift` | 模型价格目录与离线回退 |
| `MarketMonitor.cs` | `MarketMonitor.swift` | 多市场行情、预取、K线渲染和压缩帧 |
| `NetSpeedMonitor.cs` | `NetSpeedMonitor.swift` | 4Hz 网速采样环 |
| `NowPlayingMonitor.cs` | `NowPlayingMonitor.swift` | 系统 Now Playing + 封面/文字条 RGB565 |
| `DeviceClient.cs` | `DeviceClient.swift` | 设备 HTTP API + 自动配对/子网扫描 |
| `MiniHttpServer.cs` | `HTTPServer.swift` | 0.0.0.0:8765 极简 HTTP 服务 |
| `Rgb565.cs` | （MirrorPopover 内联） | RGB565 大端编解码 |
