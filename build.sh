#!/usr/bin/env bash
# Build "PDF Hammer.app" into dist/, ad-hoc signed.
# Pass --install to also copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PDF Hammer"
APP="dist/${APP_NAME}.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PDFHammer"

if [[ ! -f Resources/AppIcon.icns ]]; then Tools/make-icon.sh; fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PDFHammer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough for a locally built app, no Developer ID needed.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP" "/Applications/${APP_NAME}.app"
  echo "Installed /Applications/${APP_NAME}.app"
fi
