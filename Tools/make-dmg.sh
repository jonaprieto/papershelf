#!/usr/bin/env bash
# Builds a distributable disk image at dist/PaperShelf-<version>.dmg.
#
# Signing is layered, and each layer changes what someone downloading it sees:
#
#   unsigned          Gatekeeper refuses it outright: "damaged and can't be opened".
#                     Only right-click > Open, or removing the quarantine flag, gets past.
#   DEVELOPER_ID set  Signed with your Developer ID and a hardened runtime. Still shows
#                     an unidentified-developer warning until it has been notarized.
#   NOTARY_PROFILE    Submitted to Apple and stapled. Opens with no warning at all.
#
# Both are read from the environment, so nothing secret lives in this repo:
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=papershelf ./Tools/make-dmg.sh
#
# The notary profile is created once with:
#   xcrun notarytool store-credentials papershelf --apple-id you@example.com \
#         --team-id TEAMID --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PaperShelf"
APP="dist/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/PaperShelf-${VERSION}.dmg"

./build.sh

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "Signing with ${DEVELOPER_ID}"
  # A hardened runtime and a secure timestamp are both required for notarization.
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "No DEVELOPER_ID set, leaving the ad-hoc signature in place (local use only)."
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
# The drag-to-install target everyone expects inside a Mac disk image.
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null
echo "Built $DMG"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --sign "$DEVELOPER_ID" "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "Notarizing, this takes a few minutes"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "Notarized and stapled"
else
  echo "No NOTARY_PROFILE set, skipping notarization."
fi

shasum -a 256 "$DMG"
