#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

source_file="Sources/DoubaoVoiceLauncher/main.swift"

rg -q 'NSStatusItem|statusItem' "$source_file"
rg -q '显示设置窗口' "$source_file"
rg -q 'showSettingsWindowFromStatusItem' "$source_file"
rg -q '暂停监听|继续监听' "$source_file"
rg -q '退出' "$source_file"
rg -q 'makeStatusItemImage' "$source_file"
rg -q 'voiceprintBarHeights' "$source_file"
rg -q 'roundedRect' "$source_file"
rg -q 'quitFromStatusItem' "$source_file"
if rg -q 'systemSymbolName: "mic.circle"|#selector\\(NSApplication\\.terminate\\(_:\\)\\).*keyEquivalent: "q"|waveform\\.curve|let arrow = NSBezierPath' "$source_file"; then
  echo "Status item menu should use the app-style template icon and custom quit action." >&2
  exit 1
fi
