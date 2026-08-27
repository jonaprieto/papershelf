#!/usr/bin/env bash
# Drive the MCP server over stdio and check every answer, both protocol eras.
# Usage: Tools/mcp-check.sh [path-to-binary]
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${1:-$(swift build --show-bin-path)/PDFHammerMCP}"
[[ -x "$BIN" ]] || { echo "no binary at $BIN; run 'swift build' first" >&2; exit 1; }

FOLDER="$(mktemp -d)"
trap 'rm -rf "$FOLDER"' EXIT

printf '%s\n' \
  '{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"list_documents\",\"arguments\":{\"folder\":\"$FOLDER\"}}}" \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"read_document","arguments":{"path":"/nope.pdf"}}}' \
  '{"jsonrpc":"2.0","id":6,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1999-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}' \
  | "$BIN" 2>/dev/null | python3 Tools/mcp-check.py
