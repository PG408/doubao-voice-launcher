#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="DoubaoVoiceLauncher"
BUNDLE_DISPLAY_NAME="豆包语音输入切换"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$BUNDLE_DISPLAY_NAME.app"
EXECUTABLE_PATH="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
BASE_ICON="/Library/Input Methods/DoubaoIme.app/Contents/Resources/AppIcon.icns"

cd "$ROOT_DIR"

pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true
swift build -c debug --product "$PRODUCT_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp ".build/debug/$PRODUCT_NAME" "$EXECUTABLE_PATH"
if [ -f "$BASE_ICON" ]; then
  /usr/bin/swift "$ROOT_DIR/script/generate_app_icon.swift" "$BASE_ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.doubao.voice-launcher</string>
  <key>CFBundleName</key>
  <string>$BUNDLE_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$BUNDLE_DISPLAY_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>用于监听已录制的语音输入快捷键，以便自动切换到豆包语音输入。</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - --identifier "com.local.doubao.voice-launcher" "$APP_BUNDLE" >/dev/null

case "${1:-}" in
  --verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x "$PRODUCT_NAME" >/dev/null
    echo "$BUNDLE_DISPLAY_NAME is running"
    ;;
  --no-run)
    echo "Built $APP_BUNDLE"
    ;;
  *)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
esac
