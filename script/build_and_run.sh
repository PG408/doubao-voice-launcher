#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="DoubaoVoiceLauncher"
BUNDLE_DISPLAY_NAME="豆包语音输入切换"
BUNDLE_ID="com.local.doubao.voice-launcher"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$BUNDLE_DISPLAY_NAME.app"
EXECUTABLE_PATH="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
ZIP_PATH="$DIST_DIR/$PRODUCT_NAME.zip"
FILE_LOG_PATH="$HOME/Library/Logs/DoubaoVoiceLauncher/DoubaoVoiceLauncher.log"

cd "$ROOT_DIR"

pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true
swift build -c "$BUILD_CONFIGURATION" --product "$PRODUCT_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp ".build/$BUILD_CONFIGURATION/$PRODUCT_NAME" "$EXECUTABLE_PATH"
/usr/bin/swift "$ROOT_DIR/script/generate_app_icon.swift" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$BUNDLE_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$BUNDLE_DISPLAY_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.1</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>用于监听已录制的语音输入快捷键，以便自动切换到豆包语音输入。</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE" >/dev/null
/usr/bin/touch "$APP_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" >/dev/null 2>&1 || true

stream_logs() {
  local predicate="$1"
  /usr/bin/open -n "$APP_BUNDLE"
  sleep 1
  echo "Streaming logs with predicate: $predicate"
  /usr/bin/log stream --style compact --info --debug --predicate "$predicate"
}

case "${1:-}" in
  --package)
    rm -f "$ZIP_PATH"
    /usr/bin/ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    echo "Built $APP_BUNDLE"
    echo "Packaged $ZIP_PATH"
    ;;
  --verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x "$PRODUCT_NAME" >/dev/null
    echo "$BUNDLE_DISPLAY_NAME is running"
    ;;
  --logs)
    stream_logs "process == \"$PRODUCT_NAME\""
    ;;
  --telemetry)
    stream_logs "subsystem == \"$BUNDLE_ID\""
    ;;
  --tail-file-log)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    mkdir -p "$(dirname "$FILE_LOG_PATH")"
    touch "$FILE_LOG_PATH"
    echo "Tailing file log: $FILE_LOG_PATH"
    tail -f "$FILE_LOG_PATH"
    ;;
  --no-run)
    echo "Built $APP_BUNDLE"
    ;;
  *)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
esac
