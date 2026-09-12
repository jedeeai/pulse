#!/usr/bin/env bash
# 构建 Pulse 并打包成 macOS 菜单栏 .app（无需 Xcode，纯 SwiftPM + CLT）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Pulse"
CONFIG="${1:-release}"

VERSION="${PULSE_VERSION:-1.0.0}"
BUILD_VERSION="${PULSE_BUILD_VERSION:-1}"

echo "[pulse] swift build ($CONFIG)..."
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
  echo "[pulse] 找不到编译产物: $BIN" >&2
  exit 1
fi

APP_DIR="$ROOT/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.jedee.pulse</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Jedee</string>
</dict>
</plist>
PLIST

# 临时签名（ad-hoc），避免 Gatekeeper 直接拦
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "[pulse] 打包完成: $APP_DIR (version $VERSION, build $BUILD_VERSION)"
echo "[pulse] 启动:   open \"$APP_DIR\""
echo "[pulse] 或前台跑: \"$APP_DIR/Contents/MacOS/$APP_NAME\""
