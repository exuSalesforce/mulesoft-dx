#!/usr/bin/env bash
# Build the mule-flow-canvas MCP server into a single-click .mcpb bundle that
# users can drag into Claude Desktop. Idempotent — safe to re-run.
#
# What it produces:
#   <skill>/mcp/build/mule-flow-canvas-<version>.mcpb
#
# How it works:
#   `mcpb pack <dir> <out>` zips <dir> after applying the default exclusion
#   list plus any patterns in <dir>/.mcpbignore (we ship one). The manifest
#   declares server.type = "uv", so Claude Desktop runs `uv run` inside the
#   unpacked bundle on first launch — uv resolves and caches the deps from
#   pyproject.toml on the user's machine, no platform-specific bundling
#   needed for our pure-Python + lxml (lxml ships prebuilt wheels).
#
# Why this is separate from install_mcp_server.sh:
#   install_mcp_server.sh is the dev-loop path — pip install -e + edit a
#   global JSON config — used while iterating on the server code in this
#   repo. build_mcpb.sh is the distribution path — produces an artifact
#   the user installs by double-clicking it in Claude Desktop. The two
#   coexist; build_mcpb.sh does not touch the user's Claude config.
#
# Prereqs (one-time, host-side):
#   npm i -g @anthropic-ai/mcpb
#
# Usage:
#   bash "$SKILL/scripts/build_mcpb.sh"
#   bash "$SKILL/scripts/build_mcpb.sh" --output /custom/path.mcpb
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_DIR="$SKILL_DIR/mcp"
MANIFEST="$MCP_DIR/manifest.json"

CUSTOM_OUTPUT=""
for arg in "$@"; do
  case "$arg" in
    --output)
      shift
      CUSTOM_OUTPUT="${1:-}"
      [[ -z "$CUSTOM_OUTPUT" ]] && { echo "build_mcpb.sh: --output requires a path" >&2; exit 2; }
      shift
      ;;
    --output=*)
      CUSTOM_OUTPUT="${arg#--output=}"
      ;;
    -h|--help)
      sed -n '1,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "build_mcpb.sh: unknown argument '$arg'" >&2
      exit 2
      ;;
  esac
done

# --- preflight ---------------------------------------------------------------

if ! command -v mcpb >/dev/null 2>&1; then
  cat >&2 <<EOF
build_mcpb.sh: 'mcpb' CLI not found on PATH.

Install once with:
  npm i -g @anthropic-ai/mcpb

Then re-run this script. (mcpb is Anthropic's official packaging tool for
Claude Desktop extensions; it produces .mcpb bundles users can install with
a single click.)
EOF
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "build_mcpb.sh: missing manifest at $MANIFEST" >&2
  exit 1
fi

# Validate the manifest — catches a malformed JSON edit before we waste
# `mcpb pack`'s time.
if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$MANIFEST" 2>/dev/null; then
  echo "build_mcpb.sh: manifest at $MANIFEST is not valid JSON" >&2
  exit 1
fi

VERSION="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$MANIFEST")"
NAME="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$MANIFEST")"

# --- resolve output path -----------------------------------------------------

if [[ -n "$CUSTOM_OUTPUT" ]]; then
  OUTPUT="$CUSTOM_OUTPUT"
else
  BUILD_DIR="$MCP_DIR/build"
  mkdir -p "$BUILD_DIR"
  OUTPUT="$BUILD_DIR/$NAME-$VERSION.mcpb"
fi

# --- pack --------------------------------------------------------------------

echo "Packing $NAME@$VERSION → $OUTPUT"
mcpb pack "$MCP_DIR" "$OUTPUT"

# --- verify ------------------------------------------------------------------

if [[ ! -f "$OUTPUT" ]]; then
  echo "build_mcpb.sh: mcpb pack returned 0 but output file is missing: $OUTPUT" >&2
  exit 1
fi

SIZE_BYTES="$(stat -f '%z' "$OUTPUT" 2>/dev/null || stat -c '%s' "$OUTPUT" 2>/dev/null)"

# Sanity: bundle should be small (we excluded .venv + caches via .mcpbignore).
# A multi-MB bundle usually means .venv slipped in somehow.
if [[ "${SIZE_BYTES:-0}" -gt 5242880 ]]; then  # 5 MB
  echo "warning: bundle is $((SIZE_BYTES / 1024)) KB — larger than expected (~5 MB threshold)." >&2
  echo "         Check that .mcpbignore excluded .venv/, *.egg-info/, __pycache__/." >&2
fi

cat <<EOF

Built: $OUTPUT  (${SIZE_BYTES:-?} bytes)

To install in Claude Desktop:
  open "$OUTPUT"

  This launches Claude Desktop's install dialog. Approve it, quit + relaunch
  Claude Desktop, and the 'render_mule_flow' tool becomes available.

To inspect what's inside before shipping it:
  unzip -l "$OUTPUT"

EOF
