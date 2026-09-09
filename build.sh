#!/usr/bin/env bash
# Build "PaperShelf.app" into dist/, ad-hoc signed.
# Pass --install to also copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PaperShelf"
DESTINATION="dist/${APP_NAME}.app"
CHANNEL=development
INSTALL=false
for option in "$@"; do
  case "$option" in
    --release) CHANNEL=release ;;
    --install) INSTALL=true ;;
    *) echo "Usage: $0 [--release] [--install]" >&2; exit 1 ;;
  esac
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
PLUGIN_VERSION="$(plutil -extract version raw Plugin/papershelf/.codex-plugin/plugin.json)"
[[ "$VERSION" == "$PLUGIN_VERSION" ]] || { echo "App and plugin versions differ" >&2; exit 1; }
REVISION="$(git rev-parse --short=12 HEAD)"
DIRTY="$(git status --porcelain)"
if [[ "$CHANNEL" == release ]]; then
  [[ -z "$DIRTY" ]] || { echo "Release builds require a clean checkout" >&2; exit 1; }
  TAG_COMMIT="$(git rev-parse --verify "refs/tags/v${VERSION}^{commit}")"
  [[ "$TAG_COMMIT" == "$(git rev-parse HEAD)" ]] || { echo "Release builds require the exact v${VERSION} tag" >&2; exit 1; }
elif [[ -n "$DIRTY" ]]; then
  REVISION="${REVISION}+dirty"
fi

swift build -c release
BINDIR="$(swift build -c release --show-bin-path)"
BIN="$BINDIR/PaperShelf"
[[ "$("$BINDIR/PaperShelfMCP" --version)" == "$VERSION" ]] || { echo "Core and app versions differ" >&2; exit 1; }

if [[ ! -f Resources/AppIcon.icns ]]; then Tools/make-icon.sh; fi

mkdir -p dist
BUILD_STAGE="$(mktemp -d dist/.PaperShelf-build.XXXXXX)"
trap 'rm -rf "$BUILD_STAGE"' EXIT
APP="$BUILD_STAGE/${APP_NAME}.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PaperShelf"
# The MCP server ships inside the bundle so an editor's config can point at one stable
# path that survives every rebuild.
cp "$BINDIR/PaperShelfMCP" "$APP/Contents/MacOS/papershelf-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The status bar identifies the exact source revision that made this bundle. A local
# rebuild says so rather than borrowing the commit of the release it started from.
/usr/libexec/PlistBuddy -c "Add :PaperShelfGitCommit string $REVISION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PaperShelfBuildChannel string $CHANNEL" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PaperShelfBuildID string $(uuidgen)" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PaperShelfBuiltAt string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP/Contents/Info.plist"
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
if [[ "$CHANNEL" == development ]]; then
  swift Tools/publish-app.swift "$APP" "$DESTINATION" --record "$HOME/Library/Caches/PaperShelf/development-build.json"
else
  swift Tools/publish-app.swift "$APP" "$DESTINATION"
fi
echo "Built $DESTINATION"

if [[ "$INSTALL" == true ]]; then
  swift Tools/publish-app.swift "$DESTINATION" "/Applications/${APP_NAME}.app"
  echo "Installed /Applications/${APP_NAME}.app"
fi
