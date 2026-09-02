#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="${1:-dist/PaperShelf.app}"
if [[ "$APP_PATH" != /* ]]; then APP_PATH="$PWD/$APP_PATH"; fi
[[ -d "$APP_PATH" ]] || { echo "App not found: $APP_PATH" >&2; exit 1; }

if ! pgrep -x PaperShelf >/dev/null; then
  open -n "$APP_PATH"
fi
osascript Tools/ui-smoke-test.applescript
