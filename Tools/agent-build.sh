#!/usr/bin/env bash
# Rebuilds whenever a source file changes and writes a short, greppable result to
# .build/agent/status.txt, so an agent working in this repo can read its own errors
# instead of asking you to paste them.
#
#   ./Tools/agent-build.sh          watch and rebuild forever
#   ./Tools/agent-build.sh --once   build once and exit
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=.build/agent
mkdir -p "$OUT"

watched() { find Sources Tests Package.swift -type f \( -name '*.swift' -o -name 'Package.swift' \) 2>/dev/null; }
signature() { watched | xargs stat -f '%m %N' 2>/dev/null | shasum | cut -d' ' -f1; }

build_once() {
  local started; started=$(date -u +%FT%TZ)
  printf 'building…\n' >&2
  swift build > "$OUT/build.raw" 2>&1; local b=$?
  local t=-1
  if [ $b -eq 0 ]; then swift test > "$OUT/test.raw" 2>&1; t=$?; fi
  {
    echo "at=$started build_exit=$b test_exit=$t head=$(git rev-parse --short HEAD 2>/dev/null)"
    echo "errors=$(grep -c 'error:' "$OUT/build.raw" 2>/dev/null || echo 0)"
    echo "--- build errors ---"
    grep -E '(error|warning): ' "$OUT/build.raw" 2>/dev/null | grep -v 'warning: .*never used' | head -80
    if [ $b -eq 0 ]; then
      echo "--- tests ---"
      grep -E '(Test Suite|failed|error:|Executed [0-9]+ test)' "$OUT/test.raw" 2>/dev/null | tail -40
    fi
  } > "$OUT/status.txt" 2>&1
  printf 'build_exit=%s test_exit=%s errors=%s\n' "$b" "$t" "$(grep -c 'error:' "$OUT/build.raw" 2>/dev/null || echo 0)" >&2
}

if [ "${1:-}" = "--once" ]; then build_once; exit 0; fi

echo "watching Sources, Tests and Package.swift — ctrl-C to stop" >&2
last=""
while true; do
  cur=$(signature)
  if [ "$cur" != "$last" ]; then last="$cur"; build_once; fi
  sleep 3
done
