<p align="center">
  <img src="docs/images/logo.svg" width="72" alt="logo">
</p>

<h1 align="center">ESP32 AI 小屏幕</h1>

<p align="center">ESP32-C3 / ESP8266 · 240×240 TFT · Claude Code / Codex 桌面伴侣</p>

<p align="center">
  中文 ·
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="docs/ESP32-C3.md">ESP32-C3 烧录说明</a> ·
  <a href="web-flasher/">Web 烧录器</a> ·
  <a href="https://github.com/pengchujin/esp8266-ai">上游 ESP8266 项目</a>
</p>

## 先看：ESP32-C3 1.54 寸屏幕点亮避坑

这个移植最容易出现的现象是：**固件正常启动、Wi-Fi 和桥接程序都能通信，但屏幕全黑，
只能从侧面看到微弱闪烁。** 此时不要先怀疑屏幕损坏，也不要照搬 ESP8266 的引脚。

我们最初根据低清原理图截图读出了错误的 GPIO，屏幕始终没有数据。最终从烧录前保存的
4MB 原厂 Flash 中只读分析出原厂 `TFT_eSPI` 初始化代码，确认它使用
`ST7789_2_DRIVER`，并实际调用 `SPI.begin(3, 5, 5, -1)`。原厂 GPIO 设置和本项目采用的
最终引脚如下：

| 信号 | ESP32-C3 GPIO | 说明 |
|---|---:|---|
| LCD_BL | 1 | AO3401 控制，**低电平点亮** |
| LCD_DC | 2 | 数据/命令选择 |
| LCD_SCL / SCLK | 3 | SPI 时钟 |
| LCD_SDA / MOSI | 5 | SPI 数据 |
| MISO | 5 | 屏幕只写；与 MOSI 同脚仅用于满足 C3 SPI 初始化 |
| LCD_RESET | 6 | 屏幕硬复位 |
| CS | `-1` | PCB 未接 MCU，屏幕保持选中 |

几个值得保留的经验：

1. **先备份再烧录。** 读取完整 4MB Flash，不要一上来执行 `erase-flash`；原厂备份既能恢复，
   也能在原理图不清楚时反向确认真实初始化参数。
2. **分辨率相同不等于驱动配置相同。** 这块 240×240 屏需要 TFT_eSPI 的
   `ST7789_2_DRIVER`；普通 `ST7789_DRIVER` 和错误 GPIO 都不会点亮。
3. **`MISO=MOSI` 不是接线错误。** 该屏幕没有回读数据，GPIO5 作为占位 MISO 是原厂固件和
   TFT_eSPI 在 ESP32-C3 上采用的初始化方式。
4. **日志正常不代表显示总线正常。** Wi-Fi、Web 管理页和 Mac 桥接均可工作，而屏幕仍因
   SCLK/MOSI/DC/RST 任一错误保持全黑。
5. **不要动 eFuse 或安全启动配置。** 普通应用固件不会覆盖 ROM 下载模式；烧录失败时按住
   BOOT、点按 RESET 后仍可重新写入。

本仓库的 C3 构建会静态校验这组引脚，Web 固件构建脚本也会再次检查，避免后续改动悄悄
破坏已验证配置。完整备份、恢复、串口烧录和故障排查见
[ESP32-C3 安全烧录文档](docs/ESP32-C3.md)。

### 本机 Web 烧录

```bash
cd /path/to/esp32ai
python3 -m http.server 8000
```

用桌面版 Chrome / Edge 打开 `http://localhost:8000/web-flasher/`，确认版本为
`0.4.6-c3.10` 后连接 ESP32-C3。当前 Web 固件已在上述成品板实机点亮；普通升级（不勾选
“抹除”）只写入启动、分区表和应用段，会保留 Wi-Fi 凭据与 LittleFS。只有首次安装或主动
勾选“抹除”才需要重新配网。

> 本项目基于 [pengchujin/esp8266-ai](https://github.com/pengchujin/esp8266-ai) 移植。
> 默认目标现为 4MB Flash、原生 USB 的 ESP32-C3，原 ESP8266 构建环境仍保留为
> `nodemcuv2`。

<p align="center">
  <img src="docs/images/hero.jpg" width="640" alt="AI Mac 小屏幕">
</p>

一块 240×240 的复古小电视，放在桌上实时显示 **Claude Code / Codex CLI 在干什么、额度还剩多少**。不需要任何 API key：数据来自本机已有的 CLI 登录凭据和会话日志，由配套的 Mac / Windows 桥接程序在局域网内提供给设备。

## 功能

| | |
|---|---|
| <img src="docs/images/feature1.jpg" width="360" alt="AI 工作状态"> | **AI 工作状态、额度与当日成本**<br>桌宠动起来 = AI 正在干活。Claude 显示 5 小时 / 周额度，Codex 只显示 Weekly；同时统计本机时间 00:01 到 23:59 的 token 和模型折算金额。AUTO 空闲时保持最近活跃项，不再无意义轮播。Fast / Priority 模式的每次任务会触发 2.4 秒 Ludicrous 全屏动画。 |
| <img src="docs/images/feature2.jpg" width="360" alt="多市场行情"> | **多市场行情**<br>同一页支持 BTC/ETH、A 股、港股、美股和韩股，以及上证、恒生、SPX、NDX、AAPL、NVDA、KOSPI 等常用标的。收藏列表最多 15 个，行情页每 10 秒自动轮换；腾讯/东方财富/Naver 直连中国大陆网络，无接口时保留最后画面并标记 STALE。 |
| <img src="docs/images/feature2.jpg" width="360" alt="网速监视"> | **网速实时监视**<br>任务管理器风格的上下行曲线，56 秒滚动窗口，量程自动调整。 |
| <img src="docs/images/music.jpg" width="360" alt="音乐播放"> | **音乐播放显示**<br>专辑封面、歌名、歌手、进度条实时同步；音乐响起自动切入，停止自动切回。 |
| <img src="docs/images/feature3.jpg" width="360" alt="桌宠可换"> | **可换桌宠**<br>内置 [petdex.dev](https://petdex.dev) 画廊 3300+ 开源桌宠，也可上传任意 GIF，设备板上直接解码，无需重烧固件。 |

## 快速上手

以下步骤是上游 ESP8266 / SD2 小电视的使用方式。ESP32-C3 请优先按上面的实机配置和
[专用烧录文档](docs/ESP32-C3.md)操作。

需要的东西：一台「SD2 小电视」开发板（[开源硬件](https://oshwhub.com/q21182889/sd2)，也可[直接购买成品](https://mobile.yangkeduo.com/goods.html?ps=OuBjGMWE82)）、一根 USB **数据**线。

### 第 1 步 · 刷固件（约 30 秒）

用 Chrome / Edge 打开 **[mac.qust.me/#flash](https://mac.qust.me/#flash)**，USB 连接设备，点「连接设备并烧录」，选择串口等待完成即可，无需安装任何工具。

> 弹窗里看不到串口？Windows 需要装 [CH340 驱动](https://www.wch.cn/downloads/CH341SER_EXE.html)，Mac 系统自带无需安装；换根 USB 线（很多线只能充电）；更多排查见[官网 FAQ](https://mac.qust.me/#flash-faq)。
>
> 命令行党也可以用 esptool 把 [Releases](https://github.com/pengchujin/esp8266-ai/releases/latest) 里的 `esp8266-ai-firmware-*.bin` 刷到 `0x0`。

### 第 2 步 · 配 WiFi

设备首次开机会开热点 **`AI-Clock-Setup`**：手机连上后自动弹出配网页（没弹就用浏览器打开 `192.168.4.1`），选择家里 WiFi、输入密码，完成。

### 第 3 步 · 装桥接程序

从 [Releases](https://github.com/pengchujin/esp8266-ai/releases/latest) 下载并打开：

- **macOS**：`AIClockBridge-*-macOS.dmg`，拖入 Applications（ad-hoc 签名，首次启动需在「系统设置 → 隐私与安全性」允许，并同意本地网络权限）
- **Windows**：`AIClockBridge-*-Windows-x64.exe`，双击即用

桥接程序常驻菜单栏 / 托盘，会**自动发现并配对**同一局域网内的设备——到这里屏幕就活了。

<p align="center">
  <img src="docs/images/working.jpg" width="640" alt="工作演示">
</p>

日常使用都在托盘图标上：**左键**打开设备画面的实时镜像（底部有屏幕亮度滑条），**右键**是完整菜单（额度详情、屏幕切换、更换桌宠、音乐/网速页等）。

## 常见问题

- **屏幕边框红色闪烁**：设备连不上桥接程序——确认电脑端程序在运行、和设备在同一 WiFi。
- **额度一直显示 `-`**：本机没有登录过 Claude Code / Codex CLI，桥接程序读不到凭据。
- **想换桌宠**：右键托盘图标 → 「更换桌宠动画…」，挑一个点上传就行。

## 开发

```
firmware/     ESP32-C3 / ESP8266 固件（PlatformIO + Arduino，含板上 GIF 解码）
mac-app/      macOS 菜单栏桥接（Swift/SPM，零第三方依赖）
windows-app/  Windows 托盘桥接（C# / .NET 8 WinForms）
tools/        GIF → RGB565 内置精灵图转换脚本
docs/         开发文档（硬件引脚、HTTP API、架构细节）
```

```bash
cd firmware && pio run -t upload   # 固件：编译 + USB 烧录
cd mac-app && swift run            # Mac 桥接：本地跑起来
```

硬件引脚表、屏幕驱动的坑、设备 HTTP API、GIF 板上解码架构等细节见 **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**。

硬件、固件、软件全部开源，拿去改、拿去做、拿去卖都行。
