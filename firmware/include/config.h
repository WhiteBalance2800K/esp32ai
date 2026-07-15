#pragma once

// ---- Firmware version (shown on the first-time WiFi setup screen & /api/info) ----
#define FW_VERSION_ESP32_C3 "0.4.6-c3.10"
#if defined(ESP32)
#define FW_VERSION FW_VERSION_ESP32_C3
#else
#define FW_VERSION "0.4.6"
#endif

// ---- Bridge polling ----
#define BRIDGE_DEFAULT_PORT 8765
#define BRIDGE_DEFAULT_PATH "/status"
#define BRIDGE_POLL_INTERVAL_MS 2000
#define BRIDGE_HTTP_TIMEOUT_MS 3000

// ---- WiFiManager ----
#define WIFI_PORTAL_AP_NAME "AI-Clock-Setup"
#define WIFI_CONFIG_FILE "/bridge_host.txt"

// ---- Backlight ----
#define BRIGHTNESS_FILE "/brightness.txt"
#define BRIGHTNESS_DEFAULT 100
#define BRIGHTNESS_PWM_FREQ 2000 // Hz; high enough to avoid visible flicker when dim

// ---- Display layout (240x240 ST7789) ----
#define SCREEN_W 240
#define SCREEN_H 240

// Source frames remain unchanged so existing LittleFS uploads and the Mac
// mirror wire format stay compatible. Both pets are reduced on-screen to 85%.
#define CLAUDE_DISPLAY_PERCENT 85
#define CODEX_DISPLAY_PERCENT 85
