#!/usr/bin/env bash
# Run the core against a real folder of PDFs. Reads only; writes nothing but a temporary
# database. Not part of 'swift test', because it needs documents that are not in the repo.
#
#   Tools/real-library-check.sh ~/Documents/books
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -ge 1 ]] || { echo "usage: $0 <folder-of-pdfs>" >&2; exit 2; }

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Swift only allows top-level code in a file called main.swift, so it is compiled under
# that name rather than being written as one in a Tools directory full of other things.
cp Tools/real-library-check.swift "$OUT/main.swift"
swiftc -O Sources/PaperShelfCore/*.swift "$OUT/main.swift" -o "$OUT/check"
"$OUT/check" "$1"
