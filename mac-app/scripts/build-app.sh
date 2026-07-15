#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/.build/AIClockBridge.app"

cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE="$BIN_DIR/AIClockBridge"
RESOURCE_BUNDLE="$BIN_DIR/AIClockBridge_AIClockBridge.bundle"
APP_ICON="$ROOT/Assets/AppIcon.icns"

[[ -x "$EXECUTABLE" ]] || { print -u2 "missing executable: $EXECUTABLE"; exit 1; }
[[ -d "$RESOURCE_BUNDLE" ]] || { print -u2 "missing resources: $RESOURCE_BUNDLE"; exit 1; }
[[ -f "$APP_ICON" ]] || { print -u2 "missing app icon: $APP_ICON"; exit 1; }
command -v trash >/dev/null || { print -u2 "the macOS trash command is required"; exit 1; }

TEMP_ROOT="$(mktemp -d "$ROOT/.build/.package-app.XXXXXX")"
STAGED_APP="$TEMP_ROOT/AIClockBridge.app"
SMOKE_PID=""
cleanup() {
  if [[ -n "$SMOKE_PID" ]] && kill -0 "$SMOKE_PID" 2>/dev/null; then
    kill "$SMOKE_PID"
    wait "$SMOKE_PID" 2>/dev/null || true
  fi
  [[ -d "$TEMP_ROOT" ]] && trash "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
install -m 755 "$EXECUTABLE" "$STAGED_APP/Contents/MacOS/AIClockBridge"
install -m 644 "$ROOT/Info.plist" "$STAGED_APP/Contents/Info.plist"
install -m 644 "$APP_ICON" "$STAGED_APP/Contents/Resources/AppIcon.icns"

ditto "$RESOURCE_BUNDLE" "$STAGED_APP/Contents/Resources/AIClockBridge_AIClockBridge.bundle"

codesign --force --deep --sign - --timestamp=none "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
plutil -lint "$STAGED_APP/Contents/Info.plist"

# Catch launch-time crashes such as failures in the first serial scan timer.
"$STAGED_APP/Contents/MacOS/AIClockBridge" >/dev/null 2>&1 &
SMOKE_PID=$!
sleep 1
if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
  wait "$SMOKE_PID" 2>/dev/null || true
  SMOKE_PID=""
  print -u2 "packaged app exited during launch smoke test"
  exit 1
fi
kill "$SMOKE_PID"
wait "$SMOKE_PID" 2>/dev/null || true
SMOKE_PID=""

[[ -e "$OUTPUT" ]] && trash "$OUTPUT"
mv "$STAGED_APP" "$OUTPUT"
print "$OUTPUT"
