#!/usr/bin/env bash
# Build "PDF Hammer.app" into dist/, ad-hoc signed.
# Pass --install to also copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PDF Hammer"
APP="dist/${APP_NAME}.app"

swift build -c release
BINDIR="$(swift build -c release --show-bin-path)"
BIN="$BINDIR/PDFHammer"

if [[ ! -f Resources/AppIcon.icns ]]; then Tools/make-icon.sh; fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PDFHammer"
# The MCP server ships inside the bundle so an editor's config can point at one stable
# path that survives every rebuild.
cp "$BINDIR/PDFHammerMCP" "$APP/Contents/MacOS/pdf-hammer-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The plugin listing in the ChatGPT app shows this, copied into the plugin folder at
# install time. It has to travel inside the bundle: a built .app has no source checkout.
cp Resources/PluginLogo.png "$APP/Contents/Resources/PluginLogo.png"

# Ad-hoc signature: enough for a locally built app, no Developer ID needed.
codesign --force --sign - "$APP/Contents/MacOS/pdf-hammer-mcp"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP" "/Applications/${APP_NAME}.app"
  echo "Installed /Applications/${APP_NAME}.app"
fi
