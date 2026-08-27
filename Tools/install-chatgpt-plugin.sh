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
# A marketplace entry's relative path is read from the home directory, not from beside the
# marketplace file, so `./plugins/pdf-hammer` in the listing means exactly this.
DESTINATION="$HOME/plugins/pdf-hammer"
LEGACY_DESTINATION="$AGENTS/pdf-hammer"
MARKETPLACE="$AGENTS/marketplace.json"
SERVER="/Applications/PDF Hammer.app/Contents/MacOS/pdf-hammer-mcp"

[[ -x "$SERVER" ]] || { echo "PDF Hammer is not installed in /Applications. Run ./build.sh --install first." >&2; exit 1; }

mkdir -p "$AGENTS" "$(dirname "$DESTINATION")"
rm -rf "$DESTINATION" "$LEGACY_DESTINATION"
cp -R "$PLUGIN_SOURCE" "$DESTINATION"

# The marketplace may already list other plugins, so it is merged rather than replaced.
# The copied manifest is also stamped with the moment of the install: a local plugin is
# cached by version, so reinstalling the same 1.2.0 over itself would leave the old name,
# description and icon on screen.
python3 - "$MARKETPLACE" "$DESTINATION" <<'PY'
import datetime, json, pathlib, sys

manifest_path = pathlib.Path(sys.argv[2]) / ".codex-plugin" / "plugin.json"
manifest = json.loads(manifest_path.read_text())
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M%S")
manifest["version"] = manifest["version"].split("+")[0] + f"+codex.{stamp}"
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

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
    "source": {"source": "local", "path": "./plugins/pdf-hammer"},
    "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
    "category": "Education & Research",
}
market["plugins"] = [p for p in market["plugins"] if p.get("name") != "pdf-hammer"]
market["plugins"].append(entry)
path.write_text(json.dumps(market, indent=2) + "\n")
print(f"listed pdf-hammer in {path}")
PY

echo "Installed to $DESTINATION"
echo
echo "Restart the ChatGPT app, then add PDF Hammer from its plugin list."
