#!/usr/bin/env bash
# Build "PaperShelf.app" into dist/, ad-hoc signed.
# Pass --install to also copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PaperShelf"
APP="dist/${APP_NAME}.app"

swift build -c release
BINDIR="$(swift build -c release --show-bin-path)"
BIN="$BINDIR/PaperShelf"

if [[ ! -f Resources/AppIcon.icns ]]; then Tools/make-icon.sh; fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PaperShelf"
# The MCP server ships inside the bundle so an editor's config can point at one stable
# path that survives every rebuild.
cp "$BINDIR/PaperShelfMCP" "$APP/Contents/MacOS/papershelf-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signed, so the Keychain would treat every rebuild as a different application and
# ask again. The app reads this and keeps the API key in memory for the session instead.
/usr/libexec/PlistBuddy -c "Add :PaperShelfAdHocBuild bool true" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The plugin listing in the ChatGPT app shows this, copied into the plugin folder at
# install time. It has to travel inside the bundle: a built .app has no source checkout.
cp Resources/PluginLogo.png "$APP/Contents/Resources/PluginLogo.png"
[[ -f Resources/PaperShelf.sdef ]] || { echo "Resources/PaperShelf.sdef is missing; AppleScript support would be absent" >&2; exit 1; }
cp Resources/PaperShelf.sdef "$APP/Contents/Resources/PaperShelf.sdef"
# Same reasoning for the changelog the About window's fourth page reads: there is exactly
# one copy of it, at the repository root, so nothing here can drift from it the way the
# three version numbers once did. Checked explicitly, with a message, rather than letting
# a missing file fail on a bare `cp`: that failed silently enough in the past that nobody
# noticed the version numbers had drifted either.
[[ -f CHANGELOG.md ]] || { echo "CHANGELOG.md is missing at the repository root; the About window would ship with no changelog to read" >&2; exit 1; }
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"

# Ad-hoc signature: enough for a locally built app, no Developer ID needed.
codesign --force --sign - "$APP/Contents/MacOS/papershelf-mcp"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP" "/Applications/${APP_NAME}.app"
  echo "Installed /Applications/${APP_NAME}.app"
fi
