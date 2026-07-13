# ESP32-C3 移植与安全烧录

本分支默认构建 `esp32-c3-devkitm-1`，已按 4MB Flash、Arduino framework、
LittleFS 和原生 USB Serial/JTAG 配置。原 ESP8266 环境仍保留为 `nodemcuv2`。

## 屏幕接线

固件按「C3 天气预报」板原理图配置 240×240 ST7789 SPI 屏：

| ST7789 | ESP32-C3 GPIO |
|---|---:|
| SCLK | 3 |
| MOSI / SDA | 5 |
| MISO（仅作 SPI 初始化占位，与 MOSI 同脚） | 5 |
| CS | 未连接到主控（固件设为 `-1`，常选中） |
| DC | 2 |
| RST | 6 |
| BL（低电平点亮） | 1 |

这组值不是按网络标签位置目测推断，而是从该板可正常显示的原厂 Flash 备份中还原：原厂
`TFT_eSPI` 调用 `SPI.begin(3, 5, 5, -1)`，并将 GPIO2、GPIO6 分别配置为 DC、RESET。
屏幕是只写设备，MISO 与 MOSI 同为 GPIO5 是 TFT_eSPI 在 ESP32-C3 上的初始化占位方式，
不是额外接线。GPIO18/19 保留给原生 USB。若使用其他 ESP32-C3 板，只修改
`firmware/platformio.ini` 中 ESP32-C3 环境的 `TFT_*` 值并先核对其原理图。

## 构建与生成 Web 固件

```bash
cd firmware
python3 -m venv .pio-venv
.pio-venv/bin/pip install platformio esptool
.pio-venv/bin/python scripts/build_web_firmware.py
```

脚本会构建固件，并用 esptool 按 ESP32-C3 的正确偏移合并 bootloader、分区表、
boot_app0 和应用：

- bootloader：`0x0`
- partition table：`0x8000`
- boot_app0：`0xe000`
- application：`0x10000`

合并产物使用 `web-flasher/firmware/esp32c3-ai-clock-<版本>-<SHA>.bin` 不可变文件名，
网页清单位于 `web-flasher/manifest.json`。构建脚本先校验临时镜像，再生成哈希文件，最后
只原子切换 manifest；失败时旧 manifest 仍指向上一份已验证镜像。

本机测试网页：

```bash
cd ..
python3 -m http.server 8000
```

然后用桌面版 Chrome/Edge 打开 `http://localhost:8000/web-flasher/`。Web Serial 要求
HTTPS 或安全的 localhost 上下文，普通局域网 HTTP 地址不能烧录。

部署到静态托管时，还应让平台应用 `web-flasher/_headers` 中的 CSP、Permissions-Policy
和防嵌入响应头；不支持 `_headers` 的平台需在其配置中设置等价 HTTP headers。页面内另有
同源 frame guard 作为静态托管兜底。

## 烧录前备份与恢复

不要先执行 `erase-flash`。先在仓库外创建私有目录，并完整备份当前 4MB Flash：

```bash
mkdir -p "$HOME/esp32c3-backups" && chmod 700 "$HOME/esp32c3-backups"
esptool --chip esp32c3 --port /dev/cu.usbmodem21101 read-flash 0 0x400000 \
  "$HOME/esp32c3-backups/esp32c3-backup.bin"
```

备份可能含 Wi-Fi 凭据，必须仅保存在本机，不要提交到 Git。若新固件无法启动，可按住
BOOT、点按 RESET、松开 BOOT 进入 ROM 下载模式，然后恢复：

```bash
esptool --chip esp32c3 --port /dev/cu.usbmodem21101 write-flash 0 \
  "$HOME/esp32c3-backups/esp32c3-backup.bin"
```

普通应用固件无法覆盖芯片内部 ROM 下载器，因此只要没有启用安全启动、Flash 加密或烧写
不可逆 eFuse，错误应用通常都能通过 BOOT/RESET 和 esptool 恢复。本项目的构建与网页清单
不包含任何 eFuse、安全启动或 Flash 加密操作。
