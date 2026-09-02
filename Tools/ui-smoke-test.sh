#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="${1:-dist/PaperShelf.app}"
if [[ "$APP_PATH" != /* ]]; then APP_PATH="$PWD/$APP_PATH"; fi
[[ -d "$APP_PATH" ]] || { echo "App not found: $APP_PATH" >&2; exit 1; }
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/PaperShelf"
[[ -x "$APP_EXECUTABLE" ]] || { echo "App executable not found: $APP_EXECUTABLE" >&2; exit 1; }

if ! pgrep -f -x "$APP_EXECUTABLE" >/dev/null; then
  open -n "$APP_PATH"
fi

SCRIPT_APP_PATH=${APP_PATH//\\/\\\\}
SCRIPT_APP_PATH=${SCRIPT_APP_PATH//&/\\&}
SCRIPT_APP_PATH=${SCRIPT_APP_PATH//|/\\|}
SCRIPT_EXECUTABLE=${APP_EXECUTABLE//\\/\\\\}
SCRIPT_EXECUTABLE=${SCRIPT_EXECUTABLE//&/\\&}
SCRIPT_EXECUTABLE=${SCRIPT_EXECUTABLE//|/\\|}
sed "s|__PAPERSHELF_APP_PATH__|$SCRIPT_APP_PATH|g; s|__PAPERSHELF_EXECUTABLE__|$SCRIPT_EXECUTABLE|g" \
  Tools/ui-smoke-test.applescript | osascript
