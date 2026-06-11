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
#   bash "$SKILL/scripts/phase1.sh" [--no-http] <nick>:<connector> [<nick>:<connector> ...]
#
# Flags:
#   --no-http     Skip the defensive http auto-add. Default: phase1.sh
#                 picks + describes the http connector alongside the user-
#                 named systems if it isn't explicitly listed. Most
#                 realistic headless integrations need it (HTTP listener
#                 trigger, outbound REST calls, OAuth callback path), and
#                 adding it here saves a follow-up "pick + describe http"
#                 chip in the chat. Pass --no-http when you're sure the
#                 integration won't touch HTTP at all.
#   -h, --help    Print this usage block.
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
# RDS bring-up. Two flags:
#   --no-http     skip the defensive http auto-add (default: add http if not requested)
#   --help, -h    print usage and exit
#
# Why http is added by default: every realistic headless integration either
# (a) uses an HTTP listener trigger or (b) makes outbound HTTP calls or (c)
# uses an OAuth-family connection provider whose callback path needs an http
# listener-config. Letting Phase 1 describe http alongside the user-named
# systems means the agent's `sources[]` view at Step 3 (trigger ladder)
# already includes http:listener — without a separate "now pick + describe
# http" round-trip that costs a chat turn. Mirror of the build-mule-integration
# skill's "HTTP defensive add" (Step 8 there).
SKIP_HTTP_AUTO=0
declare -a NICKS=()
declare -a CONNECTORS=()
for arg in "$@"; do
  case "$arg" in
    --no-http)
      SKIP_HTTP_AUTO=1
      ;;
    -h|--help)
      cat <<'HELP'
Usage: phase1.sh [--no-http] <nick>:<connector> [<nick>:<connector> ...]

Brings up RDS, picks each connector, describes each connector, and prints
a combined digest. Replaces 5+ separate bash chips in the agent's chat.

Flags:
  --no-http   Skip the defensive http auto-add. By default, phase1.sh
              also picks + describes the http connector if it isn't
              explicitly listed (most headless integrations need it).
  -h, --help  Print this usage block and exit.

Example:
  bash phase1.sh sfdc:salesforce twilio:twilio
  → also picks + describes http (defensive add)

  bash phase1.sh --no-http sfdc:salesforce
  → picks only salesforce
HELP
      exit 0
      ;;
    -*)
      echo "phase1.sh: unknown flag '$arg'" >&2
      echo "Try 'phase1.sh --help' for usage." >&2
      exit 2
      ;;
    *)
      if [[ "$arg" != *":"* ]]; then
        echo "phase1.sh: bad pair '$arg' (expected <nick>:<connector>)" >&2
        exit 2
      fi
      nick="${arg%%:*}"
      conn="${arg#*:}"
      if [[ -z "$nick" || -z "$conn" ]]; then
        echo "phase1.sh: empty nick or connector in '$arg'" >&2
        exit 2
      fi
      NICKS+=("$nick")
      CONNECTORS+=("$conn")
      ;;
  esac
done

# Defensive http auto-add. Opt-out with --no-http.
if [[ "$SKIP_HTTP_AUTO" -eq 0 ]]; then
  HAS_HTTP=0
  for c in "${CONNECTORS[@]}"; do
    if [[ "$c" == "http" ]]; then HAS_HTTP=1; break; fi
  done
  if [[ "$HAS_HTTP" -eq 0 ]]; then
    NICKS+=("http")
    CONNECTORS+=("http")
    AUTO_HTTP_ADDED=1
  fi
fi

step() {
  printf '\n=== %s ===\n' "$1"
}

# ---- Step 1: prerequisites + RDS reachability ------------------------------

step "Step 1: validate prerequisites + ensure RDS"
"$SKILL_DIR/scripts/validate_prerequisites.sh" >/dev/null
echo "  prereqs OK ($(jq -r .node_version "$TMP_DIR/headless-env.json"))"
echo "  rds: $(jq -r .url "$TMP_DIR/rds.json") (backend=$(jq -r .backend "$TMP_DIR/rds.json"))"

# ---- Clean stale per-nick artifacts ----------------------------------------
#
# tmp/ persists across runs by design (it's a scratchpad the agent reads
# back). But per-nick files left over from a prior run with different
# nicks pollute downstream steps — most visibly create_versionless_project's
# config.yaml emit, which used to glob *-digest.json and ended up writing
# the same connector block twice. Wipe just the per-nick directories;
# preserve env/RDS state since that's still valid.
rm -rf \
  "$TMP_DIR/connector-choices" \
  "$TMP_DIR/connector-metadata" \
  "$TMP_DIR/connector-errors" \
  "$TMP_DIR/design-spec.json"

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
  marker=""
  if [[ "$conn" == "http" && "${AUTO_HTTP_ADDED:-0}" -eq 1 ]]; then
    marker=" [auto-added; use --no-http to skip]"
  fi
  printf '  %-12s -> %-30s (prefix: %s)%s\n' "$nick" "$conn" "$prefix" "$marker"
done

cat <<'EOF'

Next steps for the agent:
  - Step 3: pick a trigger from the digest (look at "sources:" lines).
  - Step 4: pick a connection provider per connector ("connection providers:").
  - Step 5: present the Technical Design Summary and wait for user approval.
  - Step 6 (after approval): commit_design_spec + create_versionless_project.

Reminder for the agent:
  The output above is the digest you need for Steps 3-5. Do NOT re-Read
  tmp/connector-metadata/*.json files individually — every operation,
  source, and connection provider for every picked connector is already
  in this stdout block. Use jq against the on-disk file ONLY when you
  need a field that the printed digest didn't include (rare).
EOF
