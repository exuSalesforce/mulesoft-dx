#!/usr/bin/env bash
# Phase 1 — Design (collapsed into one bash invocation).
#
# This script does in one go what was previously 5+ separate "Used Bash"
# chips in the agent's chat: validate prereqs, ensure RDS is reachable,
# pick each connector, describe each connector. The agent ends up with
# the same on-disk state (tmp/headless-env.json, tmp/rds.json,
# tmp/connector-choices/*.json, tmp/connector-metadata/*.json,
# tmp/connector-errors/*.json) and the same combined digest on stdout.
#
# Why this exists:
#   Each individual bash invocation in Claude Desktop's chat tab is a
#   separate LLM round-trip. With 2-3 connectors per project, Phase 1
#   was 6-8 round-trips before the agent could even present the
#   Technical Design Summary. Collapsing to one chip cuts ~30 seconds
#   of perceived latency on a typical run.
#
# Usage:
#   bash "$SKILL/scripts/phase1.sh" <nick>:<connector> [<nick>:<connector> ...]
#
# Example:
#   bash "$SKILL/scripts/phase1.sh" sfdc:salesforce twilio:twilio
#
# Exit codes:
#   0  All steps succeeded; combined digest printed to stdout.
#   1  Some step failed; first failing step's error went to stderr.
#   2  Bad arguments.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"

if [[ "$#" -lt 1 ]]; then
  cat >&2 <<USAGE
Usage: phase1.sh <nick>:<connector> [<nick>:<connector> ...]

Each pair binds a nickname (the local handle used in the design spec
and config.yaml) to a connector loaded on RDS. Run
'bash "\$SKILL/scripts/list_rds_connectors.sh"' to see what's available.

Example:
  bash phase1.sh sfdc:salesforce twilio:twilio
USAGE
  exit 2
fi

# Validate the pair syntax up front so we fail fast instead of after the
# RDS bring-up.
declare -a NICKS=()
declare -a CONNECTORS=()
for pair in "$@"; do
  if [[ "$pair" != *":"* ]]; then
    echo "phase1.sh: bad pair '$pair' (expected <nick>:<connector>)" >&2
    exit 2
  fi
  nick="${pair%%:*}"
  conn="${pair#*:}"
  if [[ -z "$nick" || -z "$conn" ]]; then
    echo "phase1.sh: empty nick or connector in '$pair'" >&2
    exit 2
  fi
  NICKS+=("$nick")
  CONNECTORS+=("$conn")
done

step() {
  printf '\n=== %s ===\n' "$1"
}

# ---- Step 1: prerequisites + RDS reachability ------------------------------

step "Step 1: validate prerequisites + ensure RDS"
"$SKILL_DIR/scripts/validate_prerequisites.sh" >/dev/null
echo "  prereqs OK ($(jq -r .node_version "$TMP_DIR/headless-env.json"))"
echo "  rds: $(jq -r .url "$TMP_DIR/rds.json") (backend=$(jq -r .backend "$TMP_DIR/rds.json"))"

# ---- Step 4: pick each connector -------------------------------------------

step "Step 4: pick connectors"
for i in "${!NICKS[@]}"; do
  nick="${NICKS[$i]}"
  conn="${CONNECTORS[$i]}"
  echo "  picking $nick -> $conn"
  "$SKILL_DIR/scripts/pick_connector.sh" "$nick" "$conn" >/dev/null
done

# ---- Step 5: describe each connector + emit combined digest ----------------

step "Step 5: describe connectors"
for nick in "${NICKS[@]}"; do
  echo
  "$SKILL_DIR/scripts/describe_connector.sh" "$nick"
done

# ---- Final summary ---------------------------------------------------------

step "Phase 1 complete"
cat <<EOF

State on disk:
  $TMP_DIR/headless-env.json                 (env probes)
  $TMP_DIR/rds.json                          (RDS endpoint)
  $TMP_DIR/connector-choices/<nick>.json     (per-connector picks)
  $TMP_DIR/connector-metadata/<nick>.json    (per-connector flat metadata)
  $TMP_DIR/connector-metadata/<nick>-<op>.json
  $TMP_DIR/connector-metadata/<nick>-config.json
  $TMP_DIR/connector-errors/<nick>.json

Picks summary:
EOF
for i in "${!NICKS[@]}"; do
  nick="${NICKS[$i]}"
  conn="${CONNECTORS[$i]}"
  prefix="$(jq -r '.prefix' "$TMP_DIR/connector-choices/$nick.json")"
  printf '  %-12s -> %-30s (prefix: %s)\n' "$nick" "$conn" "$prefix"
done

cat <<'EOF'

Next steps for the agent:
  - Step 6: pick a trigger from the digest (look at "sources:" lines).
  - Step 7: pick a connection provider per connector ("connection providers:").
  - Step 8: present the Technical Design Summary and wait for user approval.
  - Step 9 (after approval): commit_design_spec + create_versionless_project.
EOF
