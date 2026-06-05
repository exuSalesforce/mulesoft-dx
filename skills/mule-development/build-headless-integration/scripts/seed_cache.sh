#!/usr/bin/env bash
# Pre-populate $ACB_HOME/.cache/go/<name>/ from RDS for one or more connector names.
#
# Why this exists: the skill no longer ships any local connector bundles. On a
# fresh checkout, picking a connector requires RDS to be running. This helper
# does a one-shot pre-warm so subsequent picks succeed even if RDS is down —
# matches the ACB plugin's own cache-first behavior.
#
# Resolution + write path are identical to fetch_bundle.sh; this script just
# loops over multiple names and lives outside the Phase-1 design flow so the
# user can run it ahead of time (e.g. as a one-time post-clone setup).
#
# Usage:
#   seed_cache.sh <name> [<name>...]
#   seed_cache.sh --from-rds          (seed every connector RDS reports)
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"

if [[ "$#" -lt 1 ]]; then
  echo "Usage: seed_cache.sh <name> [<name>...]" >&2
  echo "       seed_cache.sh --from-rds" >&2
  exit 2
fi

# rds.json must already exist (run ensure_rds.sh first).
RDS_JSON="$TMP_DIR/rds.json"
if [[ ! -f "$RDS_JSON" ]]; then
  echo "no RDS endpoint recorded ($RDS_JSON missing)" >&2
  echo "  run \"$SKILL_DIR/scripts/ensure_rds.sh\" first" >&2
  exit 1
fi

# Build the connector list — either user-supplied names or every name RDS reports.
if [[ "$1" == "--from-rds" ]]; then
  URL="$(jq -r .url "$RDS_JSON")"
  mapfile_compat() {
    NAMES=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && NAMES+=("$line")
    done
  }
  mapfile_compat < <(curl -fsS --max-time 5 "$URL/v1/connectors" | jq -r '.connectors[].name')
  if [[ "${#NAMES[@]}" -eq 0 ]]; then
    echo "RDS reported no connectors at $URL" >&2
    exit 1
  fi
else
  NAMES=("$@")
fi

echo "Seeding cache for: ${NAMES[*]}"
for name in "${NAMES[@]}"; do
  printf '  %-24s ' "$name"
  # Capture stdout (resolved path on success) and stderr (reason on failure) separately,
  # so a failure can surface the actual cause rather than a generic "see error above".
  ERR_TMP="$(mktemp)"
  if BUNDLE="$("$SKILL_DIR/scripts/fetch_bundle.sh" "$name" 2>"$ERR_TMP")"; then
    echo "✓ $BUNDLE"
    rm -f "$ERR_TMP"
  else
    # First non-empty line of stderr is the actionable cause (e.g. RDS 404).
    REASON="$(grep -m1 . "$ERR_TMP" 2>/dev/null || echo 'unknown error')"
    echo "✗ $REASON"
    rm -f "$ERR_TMP"
  fi
done
