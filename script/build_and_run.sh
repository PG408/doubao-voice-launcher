#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="DoubaoVoiceSwitch"
LEGACY_APP_NAME="DoubaoVoiceLauncher"
DISPLAY_APP_NAME="Doubao Voice Switch"
BUNDLE_ID="com.bytedance.DoubaoVoiceSwitch"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_APP_NAME.app"
LEGACY_APP_BUNDLE="$DIST_DIR/$LEGACY_APP_NAME.app"
LEGACY_PRODUCT_APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Sources/DoubaoVoiceSwitch/Resources/AppIcon.icns"

cd "$ROOT_DIR"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stop_running_apps() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x "$LEGACY_APP_NAME" >/dev/null 2>&1 || true
}

verify_existing_app() {
  if [[ ! -x "$APP_BINARY" ]]; then
    echo "existing app bundle not found at $APP_BUNDLE; run $0 first" >&2
    exit 1
  fi

  stop_running_apps
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
  open_app
  sleep 1
  pgrep -x "$APP_NAME" >/dev/null
}

case "$MODE" in
  --launch-existing|launch-existing)
    if [[ ! -x "$APP_BINARY" ]]; then
      echo "existing app bundle not found at $APP_BUNDLE; run $0 first" >&2
      exit 1
    fi
    stop_running_apps
    open_app
    exit 0
    ;;
  --verify-existing|verify-existing)
    verify_existing_app
    exit 0
    ;;
esac

stop_running_apps

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE" "$LEGACY_APP_BUNDLE" "$LEGACY_PRODUCT_APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ -f "$APP_ICON_SOURCE" ]]; then
  cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.2</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--launch-existing|--verify-existing]" >&2
    exit 2
    ;;
esac
