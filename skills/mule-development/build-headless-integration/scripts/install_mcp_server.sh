#!/usr/bin/env bash
# Install the build-headless-integration MCP server (mule-flow-canvas) into
# Claude Desktop. Idempotent — safe to re-run.
#
# What it does:
#   1. Creates a Python venv at mcp/.venv/ using a 3.11+ interpreter.
#   2. Runs `pip install -e .` so the build-headless-integration-mcp console
#      script lands on the venv's PATH.
#   3. Adds (or updates) an `mcpServers.mule-flow-canvas` entry in
#      ~/Library/Application Support/Claude/claude_desktop_config.json so
#      Claude Desktop spawns the server on next launch.
#
# What it does NOT do:
#   - Restart Claude Desktop (the user must quit + relaunch to pick up
#     newly-registered MCP servers — Claude Desktop hot-reloads the
#     config, but the iframe pipeline only initialises at app start).
#
# Why this exists:
#   The MCP server lives inside the skill folder so all flow-canvas code
#   ships with the skill, but Claude Desktop has no auto-install mechanism
#   for plain mcpServers entries (Desktop Extensions / .mcpb is a separate
#   packaging story we may adopt later). This script bridges the gap so
#   Step 10 of the skill works end-to-end without manual JSON editing.
#
# Usage:
#   bash "$SKILL/scripts/install_mcp_server.sh"
#   bash "$SKILL/scripts/install_mcp_server.sh" --uninstall
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_DIR="$SKILL_DIR/mcp"
VENV_DIR="$MCP_DIR/.venv"
SERVER_NAME="mule-flow-canvas"
CLAUDE_CONFIG="${CLAUDE_DESKTOP_CONFIG:-$HOME/Library/Application Support/Claude/claude_desktop_config.json}"

# --- uninstall ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
  if [[ ! -f "$CLAUDE_CONFIG" ]]; then
    echo "Claude Desktop config not found at: $CLAUDE_CONFIG"
    exit 0
  fi
  echo "Removing mcpServers.$SERVER_NAME from $CLAUDE_CONFIG"
  python3 - "$CLAUDE_CONFIG" "$SERVER_NAME" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
servers = cfg.get("mcpServers", {})
if name in servers:
    del servers[name]
    if not servers:
        del cfg["mcpServers"]
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print(f"removed.")
else:
    print(f"{name} was not registered; nothing to do.")
PY
  echo
  echo "Uninstall complete. The venv at $VENV_DIR is left in place."
  echo "Quit and relaunch Claude Desktop to drop the running server."
  exit 0
fi

# --- preflight ---------------------------------------------------------------

# Find a Python 3.11+ interpreter. We prefer python3.12 (matches what the
# rest of the skill develops against), but accept any 3.11+.
PYTHON=""
for candidate in python3.12 python3.13 python3.14 python3.11 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
      PYTHON="$candidate"
      break
    fi
  fi
done

if [[ -z "$PYTHON" ]]; then
  echo "Error: no Python 3.11+ interpreter found on PATH." >&2
  echo "  brew install python@3.12   (macOS)" >&2
  echo "Then re-run this script." >&2
  exit 1
fi

echo "Using $PYTHON ($("$PYTHON" --version 2>&1))"

# --- venv + pip install -e ---------------------------------------------------

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  echo "Creating venv at $VENV_DIR"
  "$PYTHON" -m venv "$VENV_DIR"
else
  echo "Reusing existing venv at $VENV_DIR"
fi

# Quiet pip so the only stdout is our own progress logs.
"$VENV_DIR/bin/pip" install -q --upgrade pip
"$VENV_DIR/bin/pip" install -q -e "$MCP_DIR"

SERVER_BIN="$VENV_DIR/bin/build-headless-integration-mcp"
if [[ ! -x "$SERVER_BIN" ]]; then
  echo "Error: console script not found at $SERVER_BIN after install." >&2
  echo "Check pip output above for errors." >&2
  exit 1
fi
echo "MCP server installed: $SERVER_BIN"

# --- claude_desktop_config.json ----------------------------------------------

mkdir -p "$(dirname "$CLAUDE_CONFIG")"

# Create an empty {} if the file is missing — Claude Desktop tolerates
# being out of sync but our jq merge wants something to read from.
if [[ ! -f "$CLAUDE_CONFIG" ]]; then
  echo '{}' >"$CLAUDE_CONFIG"
  echo "Created $CLAUDE_CONFIG"
fi

# Back up before editing, so a buggy config never costs the user their
# existing mcpServers entries.
BACKUP="${CLAUDE_CONFIG}.bak.$(date +%s)"
cp "$CLAUDE_CONFIG" "$BACKUP"
echo "Backed up existing config to: $BACKUP"

# Merge the entry idempotently (preserves any other servers + preferences).
python3 - "$CLAUDE_CONFIG" "$SERVER_NAME" "$SERVER_BIN" <<'PY'
import json, sys
config_path, server_name, server_bin = sys.argv[1], sys.argv[2], sys.argv[3]
with open(config_path) as f:
    cfg = json.load(f)
cfg.setdefault("mcpServers", {})[server_name] = {"command": server_bin}
with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)
PY

echo "Registered '$SERVER_NAME' in $CLAUDE_CONFIG"

# --- final note --------------------------------------------------------------

cat <<EOF

Installed. Next steps:
  1. Quit Claude Desktop completely (⌘Q on macOS).
  2. Relaunch it.
  3. In a fresh chat: "Use render_mule_flow to render the flow at <projectDir>"
     (the Step 10 prompt the skill emits).

To verify the server is healthy without leaving the shell:
  $SERVER_BIN <<<'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
  (should print a JSON line ending with "serverInfo":{"name":"build-headless-integration-mcp",...)

To uninstall:
  bash "$SKILL_DIR/scripts/install_mcp_server.sh" --uninstall

EOF
