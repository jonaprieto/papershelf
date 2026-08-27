#!/usr/bin/env bash
# Install PDF Hammer as a local plugin for the ChatGPT desktop app.
#
# The app reads plugins from a personal marketplace at ~/.agents/plugins/marketplace.json.
# A plugin may declare an MCP server, and that server may be a local one spoken to over
# stdio, which is exactly what PDF Hammer already ships inside its bundle. Nothing is
# published, nothing is reviewed, and nothing leaves this machine.
set -euo pipefail

PLUGIN_SOURCE="$(cd "$(dirname "$0")/.." && pwd)/Plugin/pdf-hammer"
AGENTS="$HOME/.agents/plugins"
DESTINATION="$AGENTS/pdf-hammer"
MARKETPLACE="$AGENTS/marketplace.json"
SERVER="/Applications/PDF Hammer.app/Contents/MacOS/pdf-hammer-mcp"

[[ -x "$SERVER" ]] || { echo "PDF Hammer is not installed in /Applications. Run ./build.sh --install first." >&2; exit 1; }

mkdir -p "$AGENTS"
rm -rf "$DESTINATION"
cp -R "$PLUGIN_SOURCE" "$DESTINATION"

# The marketplace may already list other plugins, so it is merged rather than replaced.
python3 - "$MARKETPLACE" <<'PY'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
market = {"name": "local", "interface": {"displayName": "Local plugins"}, "plugins": []}
if path.exists():
    try:
        market = json.loads(path.read_text())
    except json.JSONDecodeError:
        print(f"{path} is not readable JSON; leaving it alone", file=sys.stderr)
        raise SystemExit(1)

market.setdefault("plugins", [])
entry = {
    "name": "pdf-hammer",
    "source": {"source": "local", "path": "./pdf-hammer"},
    "policy": {"installation": "AVAILABLE"},
    "category": "Productivity",
}
market["plugins"] = [p for p in market["plugins"] if p.get("name") != "pdf-hammer"]
market["plugins"].append(entry)
path.write_text(json.dumps(market, indent=2) + "\n")
print(f"listed pdf-hammer in {path}")
PY

echo "Installed to $DESTINATION"
echo
echo "Restart the ChatGPT app, then add PDF Hammer from its plugin list."
