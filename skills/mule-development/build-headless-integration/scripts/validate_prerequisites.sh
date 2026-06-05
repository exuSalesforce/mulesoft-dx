#!/usr/bin/env bash
# Phase 1 Step 1: validate the headless skill toolchain AND ensure RDS is reachable.
# No anypoint-cli-v4 check (this skill does not use it). No JAR check
# (Go/RDS path bypasses MTF entirely).
#
# Hard requirements:
#   - Node 18+, jq, curl, ACB install dir
#   - Real RDS reachable at MULE_DX_RDS_URL (default http://localhost:8090).
#     If RDS isn't up, this step auto-brings it up via ensure_rds.sh
#     (which delegates to go-runtime/start-rds.sh under the hood). On failure,
#     the skill cannot proceed — there is no stub fallback.
#
# Writes tmp/headless-env.json and exits non-zero if a hard requirement is missing.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# WS_DIR is the workspace root: scratch state lives at $WS_DIR/tmp/ and generated
# projects live at $WS_DIR/<projectName>/. Override with WS_DIR=... if needed; the
# default keeps everything under $HOME/Salesforce/projects/headless so the skill never
# scribbles wherever the agent's $PWD happens to point.
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"
mkdir -p "$WS_DIR" "$TMP_DIR"

ENV_FILE="$TMP_DIR/headless-env.json"
ERRORS=()

require() {
  local name="$1" cmd="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    ERRORS+=("missing required tool: $name ($cmd)")
    echo "null"
    return
  fi
  printf '"%s"' "$(command -v "$cmd")"
}

probe_node_version() {
  if ! command -v node >/dev/null 2>&1; then
    echo "null"
    return
  fi
  local v
  v="$(node --version 2>/dev/null | sed 's/^v//')"
  printf '"%s"' "$v"
}

probe_acb() {
  local acb_home="$HOME/AnypointCodeBuilder"
  if [[ -d "$acb_home" ]]; then
    printf '"%s"' "$acb_home"
  else
    echo "null"
  fi
}

probe_rds_url() {
  if [[ -n "${MULE_DX_RDS_URL:-}" ]]; then
    printf '"%s"' "$MULE_DX_RDS_URL"
  else
    echo "null"
  fi
}

probe_docker() {
  if command -v docker >/dev/null 2>&1; then
    printf '"%s"' "$(command -v docker)"
  else
    echo "null"
  fi
}

NODE_PATH="$(require "Node.js 18+" node)"
NODE_VERSION="$(probe_node_version)"
JQ_PATH="$(require "jq" jq)"
CURL_PATH="$(require "curl" curl)"
ACB_HOME="$(probe_acb)"
RDS_URL="$(probe_rds_url)"
DOCKER_PATH="$(probe_docker)"

# Node 18+ is required for fetch() and import.meta etc.
if [[ "$NODE_VERSION" != "null" ]]; then
  major="$(printf '%s' "$NODE_VERSION" | tr -d '"' | cut -d. -f1)"
  if (( major < 18 )); then
    ERRORS+=("Node.js 18+ required, found $NODE_VERSION")
  fi
fi

# Ensure RDS is reachable. ensure_rds.sh probes MULE_DX_RDS_URL (default
# http://localhost:8090) and brings up the real Go RDS via start_real_rds.sh
# if it's not already up. There is no stub fallback — RDS is a hard requirement.
RDS_STATUS="unknown"
if (( ${#ERRORS[@]} == 0 )); then
  if "$SKILL_DIR/scripts/ensure_rds.sh" >/dev/null 2>"$TMP_DIR/ensure_rds.err"; then
    RDS_STATUS="reachable"
  else
    RDS_STATUS="unreachable"
    ERRORS+=("RDS not reachable — see $TMP_DIR/ensure_rds.err for details. Manual bring-up: bash $SKILL_DIR/scripts/start_real_rds.sh")
  fi
fi

cat >"$ENV_FILE" <<JSON
{
  "skill_dir": "$SKILL_DIR",
  "ws_dir": "$WS_DIR",
  "tmp_dir": "$TMP_DIR",
  "node": $NODE_PATH,
  "node_version": $NODE_VERSION,
  "jq": $JQ_PATH,
  "curl": $CURL_PATH,
  "docker": $DOCKER_PATH,
  "acb_home": $ACB_HOME,
  "rds_url_env": $RDS_URL,
  "rds_status": "$RDS_STATUS",
  "compatibility_mode": "stub-pom",
  "errors": $(printf '%s\n' "${ERRORS[@]:-}" | jq -R . | jq -s '.[] | select(. != "")' | jq -s .)
}
JSON

if (( ${#ERRORS[@]} > 0 )); then
  printf 'validate_prerequisites: %d error(s)\n' "${#ERRORS[@]}" >&2
  printf '  - %s\n' "${ERRORS[@]}" >&2
  exit 1
fi

echo "$ENV_FILE"
