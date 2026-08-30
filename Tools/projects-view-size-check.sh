#!/usr/bin/env bash
# Lays out the reading-projects SwiftUI views off-screen at several widths and checks that
# each produces the right number of rows and section headers, with every row a finite,
# sane height. Not part of 'swift test': SwiftUI layout wants a live NSApplication, which
# the test bundle does not run under.
#
#   Tools/projects-view-size-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --target PaperShelfCore >/dev/null

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
MODULES=".build/arm64-apple-macosx/debug/Modules"
COREOBJS=".build/arm64-apple-macosx/debug/PaperShelfCore.build"

# Swift only allows top-level code in a file called main.swift once more than one file is
# in the compilation (Tools/real-library-check.sh has the same fix, for the same reason).
cp Tools/projects-view-size-check.swift "$OUT/main.swift"

# -swift-version 5 matches Package.swift's swiftLanguageMode(.v5) for every target this
# links against; without it, top-level code in this file defaults to Swift 6 mode and
# nothing here may call the @MainActor-isolated SwiftUI/AppKit layout calls synchronously.
swiftc -O -swift-version 5 \
    -I "$MODULES" \
    "$OUT/main.swift" \
    Sources/PaperShelf/Projects.swift \
    "$COREOBJS"/*.swift.o \
    -o "$OUT/check"
"$OUT/check"
