#!/usr/bin/env bash
# Drives a built PaperShelf through AppleScript and System Events.
#
# It runs against a copy of the app, never the app it was given. The copy has an identity
# of its own, so its preferences are a domain of their own, and its support folder and
# library live in a scratch directory that is deleted afterwards. The test changes theme
# and contrast, toggles panels and bookmarks the current page: none of that may land in
# the preferences or library of whoever runs it.
#
# The environment is written into the copy's Info.plist as LSEnvironment rather than set
# on a launch this script makes. AppleScript's `tell application "<path>"` launches the app
# through LaunchServices whenever it is not running, and a launch made that way carries no
# environment from here: an earlier version set nothing at all, and a run started with
# arguments was not recognised as running, so the script opened a second, unsandboxed copy
# that wrote into the real support folder.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="${1:-dist/PaperShelf.app}"
if [[ "$APP_PATH" != /* ]]; then APP_PATH="$PWD/$APP_PATH"; fi
[[ -d "$APP_PATH" ]] || { echo "App not found: $APP_PATH" >&2; exit 1; }
[[ -x "$APP_PATH/Contents/MacOS/PaperShelf" ]] || {
  echo "App executable not found in $APP_PATH" >&2; exit 1; }

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Resolved, because the process table reports the executable by its real path:
# mktemp answers /var/folders/... and ps answers /private/var/folders/..., and a sandbox
# that never recognises its own copy can neither drive it nor stop it.
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/papershelf-smoke.XXXXXX")" && pwd -P)"
SMOKE_APP="$SANDBOX/PaperShelf.app"
SMOKE_EXECUTABLE="$SMOKE_APP/Contents/MacOS/PaperShelf"
BASE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist")"
SMOKE_ID="$BASE_ID.smoketest"

# The processes running this exact executable. Matched on the executable itself rather than
# on the whole command line, which is what `pgrep -x` compares and which any argument
# changes.
smoke_pids() {
  local pid
  for pid in $(/usr/bin/pgrep -f "$SMOKE_EXECUTABLE" 2>/dev/null || true); do
    [[ "$(/bin/ps -p "$pid" -o comm= 2>/dev/null)" == "$SMOKE_EXECUTABLE" ]] && echo "$pid"
  done
  return 0
}

cleanup() {
  local pids
  pids="$(smoke_pids)"
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
    sleep 1
  fi
  defaults delete "$SMOKE_ID" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$SMOKE_APP" >/dev/null 2>&1 || true
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

mkdir -p "$SANDBOX/support"
ditto "$APP_PATH" "$SMOKE_APP"
PLIST="$SMOKE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SMOKE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :LSEnvironment" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
  -c "Add :LSEnvironment dict" \
  -c "Add :LSEnvironment:PAPERSHELF_SUPPORT_PATH string $SANDBOX/support" \
  -c "Add :LSEnvironment:PAPERSHELF_LIBRARY_PATH string $SANDBOX/support/library.sqlite" \
  -c "Add :LSEnvironment:PAPERSHELF_HIGHLIGHT_PROFILE_PATH string $SANDBOX/support/highlight-profile.json" \
  -c "Add :LSEnvironment:PAPERSHELF_AI_DISABLED string 1" \
  -c "Add :LSEnvironment:PDFHAMMER_SKIP_KEYCHAIN string 1" \
  "$PLIST"
codesign --force --deep --sign - "$SMOKE_APP" >/dev/null 2>&1
"$LSREGISTER" -f "$SMOKE_APP"

open -n "$SMOKE_APP"
PID=""
for _ in $(seq 1 100); do
  PID="$(smoke_pids | head -n 1)"
  [[ -n "$PID" ]] && break
  sleep 0.1
done
[[ -n "$PID" ]] || { echo "The sandboxed copy never started" >&2; exit 1; }

# LSEnvironment is only worth anything if the running copy honours it. Every launch writes a
# line to the diagnostics log in its own support folder, so that log appearing in the
# sandbox is proof of where this copy writes. Reading the environment of the process back
# is not: `ps -E` does not reliably show another process's variables on current macOS.
for _ in $(seq 1 100); do
  [[ -s "$SANDBOX/support/diagnostics.log" ]] && break
  sleep 0.1
done
if [[ ! -s "$SANDBOX/support/diagnostics.log" ]]; then
  echo "The copy is not writing into its sandbox; refusing to drive it" >&2
  exit 1
fi

escape() {
  local value=${1//\\/\\\\}
  value=${value//&/\\&}
  printf '%s' "${value//|/\\|}"
}
sed "s|__PAPERSHELF_APP_PATH__|$(escape "$SMOKE_APP")|g; s|__PAPERSHELF_EXECUTABLE__|$(escape "$SMOKE_EXECUTABLE")|g; s|__PAPERSHELF_PID__|$PID|g" \
  Tools/ui-smoke-test.applescript | osascript
