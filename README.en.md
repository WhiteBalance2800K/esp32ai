<p align="center">
  <img src="docs/images/logo.svg" width="72" alt="logo">
</p>

<h1 align="center">ESP32 AI Mini Display</h1>

<p align="center">ESP32-C3 / ESP8266 · 240×240 TFT · Claude Code / Codex desktop companion</p>

<p align="center">
  <a href="README.md">中文</a> ·
  English
</p>

<p align="center">
  <a href="docs/ESP32-C3.md">ESP32-C3 flashing guide</a> ·
  <a href="web-flasher/">Web flasher</a> ·
  <a href="https://github.com/pengchujin/esp8266-ai">Upstream ESP8266 project</a>
</p>

## Read first: getting the 1.54-inch ESP32-C3 display to light up

The misleading failure mode is a completely black screen with faint light visible from the side,
while firmware logs, Wi-Fi, the admin page, and the bridge all work normally. The original schematic
screenshot was easy to read one row off. We recovered the actual display setup from a read-only
analysis of the board's backed-up factory Flash: it uses TFT_eSPI's `ST7789_2_DRIVER` and calls
`SPI.begin(3, 5, 5, -1)`.

| Signal | ESP32-C3 GPIO | Notes |
|---|---:|---|
| Backlight | 1 | Active LOW through AO3401 |
| DC | 2 | Data/command |
| SCLK | 3 | SPI clock |
| MOSI | 5 | SPI data |
| MISO | 5 | Write-only display; placeholder required for C3 SPI initialization |
| RESET | 6 | Hardware reset |
| CS | `-1` | Not routed to the MCU; display stays selected |

Back up the complete 4MB Flash before replacing factory firmware, do not modify eFuses, and do not
assume that an ESP8266 pin map carries over to ESP32-C3. The build now checks this known-good pin map
at compile time and again when generating the Web image. See the
[ESP32-C3 backup, recovery, and flashing guide](docs/ESP32-C3.md) for the complete procedure.

To use the bundled flasher locally, run `python3 -m http.server 8000` from the repository root and
open `http://localhost:8000/web-flasher/` in desktop Chrome or Edge. The verified build is
`0.4.6-c3.5`.

> This port is based on [pengchujin/esp8266-ai](https://github.com/pengchujin/esp8266-ai).
> ESP32-C3 is now the default target; the original `nodemcuv2` ESP8266 target remains available.

<p align="center">
  <img src="docs/images/hero.jpg" width="640" alt="AI Mac Mini Display">
</p>

A retro mini-TV with a 240×240 screen that sits on your desk showing **what Claude Code / Codex CLI are doing right now and how much quota you have left**. No API key needed: everything comes from the CLI credentials and session logs already on your machine, served to the device over your LAN by the companion Mac / Windows bridge app.

## Features

| | |
|---|---|
| <img src="docs/images/feature1.jpg" width="360" alt="AI status"> | **AI status & quota**<br>Pet is walking = the AI is working. A square progress ring plus large digits show your real 5-hour / weekly quota usage; when a window is used up the pet becomes a reset countdown, and the border flashes red when the AI is waiting for your approval. |
| <img src="docs/images/feature2.jpg" width="360" alt="Network monitor"> | **Live network monitor**<br>Task-manager-style upload/download curves, 56-second rolling window, auto-scaling axis. |
| <img src="docs/images/music.jpg" width="360" alt="Now playing"> | **Now playing**<br>Album art, title, artist and progress bar in real time; switches in automatically when music starts, back when it stops. |
| <img src="docs/images/feature3.jpg" width="360" alt="Swappable pets"> | **Swappable pets**<br>Built-in [petdex.dev](https://petdex.dev) gallery with 3300+ open-source pets, or upload any GIF — decoded on the board itself, no reflashing needed. |

## Getting started

What you need: an "SD2 mini-TV" dev board ([open-source hardware](https://oshwhub.com/q21182889/sd2), or [buy one assembled](https://mobile.yangkeduo.com/goods.html?ps=OuBjGMWE82)) and a USB **data** cable.

### Step 1 · Flash the firmware (~30 s)

Open **[mac.qust.me/#flash](https://mac.qust.me/#flash)** in Chrome / Edge, plug the device in over USB, click "Connect & Flash", pick the serial port and wait. No tools to install.

> Serial port not showing up? On Windows install the [CH340 driver](https://www.wch.cn/downloads/CH341SER_EXE.html); macOS has it built in. Try another USB cable (many are charge-only). More troubleshooting in the [website FAQ](https://mac.qust.me/#flash-faq).
>
> Command-line folks can also flash `esp8266-ai-firmware-*.bin` from [Releases](https://github.com/pengchujin/esp8266-ai/releases/latest) to address `0x0` with esptool.

### Step 2 · Connect WiFi

On first boot the device opens a hotspot named **`AI-Clock-Setup`**: join it from your phone and the setup page pops up (or browse to `192.168.4.1`), pick your WiFi and enter the password. Done.

### Step 3 · Install the bridge app

Download from [Releases](https://github.com/pengchujin/esp8266-ai/releases/latest) and open:

- **macOS**: `AIClockBridge-*-macOS.dmg`, drag into Applications (ad-hoc signed; on first launch allow it in "System Settings → Privacy & Security" and grant local-network access)
- **Windows**: `AIClockBridge-*-Windows-x64.exe`, just double-click

The bridge lives in your menu bar / tray and **auto-discovers and pairs** with the device on the same LAN — at this point the screen comes alive.

<p align="center">
  <img src="docs/images/working.jpg" width="640" alt="In action">
</p>

Daily use is all on the tray icon: **left-click** opens a live mirror of the device screen (with a brightness slider at the bottom), **right-click** opens the full menu (quota details, screen switching, pet swapping, music/network pages, and more).

## FAQ

- **Screen border flashing red**: the device can't reach the bridge — make sure the app is running and on the same WiFi.
- **Quota shows `-` forever**: no Claude Code / Codex CLI login on this machine, so the bridge has no credentials to read.
- **Want a different pet**: right-click the tray icon → "Change pet animation…", pick one and upload.

## Development

```
firmware/     ESP32-C3 / ESP8266 firmware (PlatformIO + Arduino, with on-board GIF decoding)
mac-app/      macOS menu bar bridge (Swift/SPM, zero third-party dependencies)
windows-app/  Windows tray bridge (C# / .NET 8 WinForms)
tools/        GIF → RGB565 built-in sprite conversion script
docs/         Developer docs (pinout, HTTP API, architecture details)
```

```bash
cd firmware && pio run -t upload   # firmware: build + flash over USB
cd mac-app && swift run            # Mac bridge: run locally
```

Hardware pinout, display-driver gotchas, the device HTTP API and the on-board GIF decoding architecture are documented in **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** (Chinese).

Hardware, firmware and software are all open source — modify it, build it, even sell it.
