#!/usr/bin/env bash
# Rebuilds whenever a source file changes and writes a short, greppable result to
# .build/agent/status.txt, so an agent working in this repo can read its own compile
# errors instead of asking you to paste them.
#
#   ./Tools/agent-build.sh            watch and rebuild until stopped
#   ./Tools/agent-build.sh --once     build once and exit
#   ./Tools/agent-build.sh --stop     stop a watcher started earlier
#
# Started in the background it survives the terminal closing:
#   nohup ./Tools/agent-build.sh >/dev/null 2>&1 &
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=.build/agent
LOCK="$OUT/watcher.pid"
mkdir -p "$OUT"

# launchd hands a process almost no PATH, and `swift` is a shim that needs xcrun on it.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

case "${1:-}" in
  --stop)
    if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK")" 2>/dev/null; then
      kill "$(cat "$LOCK")" && rm -f "$LOCK" && echo "stopped"
    else
      rm -f "$LOCK"; echo "not running"
    fi
    exit 0 ;;
esac

watched()   { find Sources Tests Package.swift -type f -name '*.swift' 2>/dev/null; }
signature() { { watched; echo Package.swift; } | xargs stat -f '%m %N' 2>/dev/null | shasum | cut -d' ' -f1; }

build_once() {
  local started; started=$(date -u +%FT%TZ)
  printf 'building… ' >&2
  swift build > "$OUT/build.raw" 2>&1; local b=$?
  local t=-1
  if [ $b -eq 0 ]; then swift test > "$OUT/test.raw" 2>&1; t=$?; fi
  local errors; errors=$(grep -c 'error:' "$OUT/build.raw" 2>/dev/null || echo 0)
  {
    echo "at=$started build_exit=$b test_exit=$t errors=$errors head=$(git rev-parse --short HEAD 2>/dev/null)"
    echo "--- compiler ---"
    grep -E '(error|warning): ' "$OUT/build.raw" 2>/dev/null \
      | grep -vE 'warning: .*(never used|never mutated|was never)' | head -80
    if [ $b -eq 0 ]; then
      echo "--- tests ---"
      grep -E '(error:|failed|XCTAssert|Executed [0-9]+ test)' "$OUT/test.raw" 2>/dev/null | tail -40
    fi
  } > "$OUT/status.txt" 2>&1
  printf 'build_exit=%s test_exit=%s errors=%s\n' "$b" "$t" "$errors" >&2
}

if [ "${1:-}" = "--once" ]; then build_once; exit 0; fi

# One watcher at a time, so starting it twice does not double every build.
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK")" 2>/dev/null; then
  echo "already watching (pid $(cat "$LOCK"))" >&2; exit 0
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

echo "watching Sources, Tests and Package.swift — ./Tools/agent-build.sh --stop to end" >&2
last=""
while true; do
  cur=$(signature)
  if [ "$cur" != "$last" ]; then last="$cur"; build_once; fi
  sleep 3
done
