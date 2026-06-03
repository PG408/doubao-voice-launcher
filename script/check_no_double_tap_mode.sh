#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if rg -n '双击模式|doubleTap|double-tap' Sources/DoubaoVoiceLauncher/main.swift README.md; then
  echo "Double-tap mode is still exposed in app source or documentation." >&2
  exit 1
fi
