#!/usr/bin/env bash
# Phase 2 Step 10: render the generated flow XML as SVG (and PNG if resvg is available).
#
# Reads the project flow XML (defaults to <projectDir>/src/main/mule/<projectName>.xml)
# and writes:
#   tmp/flow.svg     # always
#   tmp/flow.png     # if @resvg/resvg-js is present
#
# Usage: visualize_flow.sh <projectDir> [flowXmlPath]
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"

PROJECT_DIR="${1:-}"
FLOW_XML="${2:-}"

if [[ -z "$PROJECT_DIR" ]]; then
  echo "Usage: visualize_flow.sh <projectDir> [flowXmlPath]" >&2
  exit 2
fi

if [[ -z "$FLOW_XML" ]]; then
  # Default: pick the only file under src/main/mule/, or fall back to a glob match.
  FLOW_DIR="$PROJECT_DIR/src/main/mule"
  if [[ ! -d "$FLOW_DIR" ]]; then
    echo "no flow dir at $FLOW_DIR" >&2
    exit 1
  fi
  FLOW_XML="$(find "$FLOW_DIR" -maxdepth 1 -type f -name '*.xml' | head -1)"
  if [[ -z "$FLOW_XML" ]]; then
    echo "no flow XML found under $FLOW_DIR" >&2
    exit 1
  fi
fi

mkdir -p "$TMP_DIR"
SVG_OUT="$TMP_DIR/flow.svg"
PNG_OUT="$TMP_DIR/flow.png"

node "$SKILL_DIR/helpers/visualize.mjs" "$FLOW_XML" --png "$PNG_OUT" >"$SVG_OUT"

# Always print the ASCII tree to stdout so the agent can read it inline.
node "$SKILL_DIR/helpers/visualize.mjs" "$FLOW_XML" --ascii

echo
echo "(svg: $SVG_OUT)"
[[ -f "$PNG_OUT" ]] && echo "(png: $PNG_OUT)"
