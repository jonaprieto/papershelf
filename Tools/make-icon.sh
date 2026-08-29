#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from Tools/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O Tools/make-icon.swift -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK/AppIcon.iconset"
iconutil --convert icns --output Resources/AppIcon.icns "$WORK/AppIcon.iconset"
cp "$WORK/AppIcon.iconset/icon_512x512.png" Resources/PluginLogo.png
cp "$WORK/AppIcon.iconset/icon_256x256.png" docs/icon.png
echo "Wrote Resources/AppIcon.icns"
