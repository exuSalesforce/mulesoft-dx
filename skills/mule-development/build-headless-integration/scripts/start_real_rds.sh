#!/usr/bin/env bash
# Step 2 (--real mode): bring up the real RemoteDesignService stack from go-runtime.
#
# Defers to go-runtime/start-rds.sh (the canonical entrypoint maintained by the RDS team)
# which handles `go mod vendor`, building WASM modules, `docker compose up -d rds connector-service`,
# and waiting for /healthz. We just locate the script, override GO_RUNTIME so it points at
# our checkout, and record the resulting URL into tmp/rds.json so the rest of the skill
# (which reads tmp/rds.json) is path-agnostic.
#
# After this returns:
#   - RDS is healthy at http://localhost:8090
#   - tmp/rds.json carries { url: "http://localhost:8090", managed: false, pid: null }
#   - Real connector binaries (salesforce.wasm, http.wasm, twilio.wasm) are loaded by
#     connector-service; calls hit those binaries via gRPC
#
# Usage:
#   bash scripts/start_real_rds.sh                # build + up + wait
#   bash scripts/start_real_rds.sh --rebuild      # force rebuild
#   bash scripts/start_real_rds.sh down           # docker compose down
#
# Override the go-runtime checkout path via GO_RUNTIME env var; default is
# $HOME/Salesforce/workspace/go-runtime.
set -euo pipefail

WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"
mkdir -p "$TMP_DIR"

GO_RUNTIME="${GO_RUNTIME:-$HOME/Salesforce/workspace/go-runtime}"
START_SCRIPT="$GO_RUNTIME/start-rds.sh"
RDS_URL="${MULE_DX_RDS_URL:-http://localhost:8090}"

if [[ ! -x "$START_SCRIPT" ]]; then
  echo "go-runtime/start-rds.sh not found at $START_SCRIPT" >&2
  echo "Set GO_RUNTIME=/path/to/go-runtime if your checkout is elsewhere." >&2
  exit 1
fi

# Preflight: 'down' just stops containers, no toolchain needed. For 'up' we need
# Go (for the host-side `go mod vendor`), Docker, and the data-weave/go sibling
# repo (the go-runtime go.mod has `replace github.com/mulesoft/data-weave/go => ../data-weave/go`).
if [[ "${1:-}" != "down" ]]; then
  PREREQS_MISSING=()
  command -v docker >/dev/null 2>&1 || PREREQS_MISSING+=("docker (CLI not on PATH)")
  docker info >/dev/null 2>&1 || PREREQS_MISSING+=("docker daemon (not running — start Docker Desktop)")
  command -v go >/dev/null 2>&1 || PREREQS_MISSING+=("go toolchain (need Go 1.26.3+ for 'go mod vendor'; install via 'brew install go')")
  DW_DIR="$(dirname "$GO_RUNTIME")/data-weave/go"
  [[ -d "$DW_DIR" ]] || PREREQS_MISSING+=("../data-weave/go sibling checkout at $DW_DIR (clone the data-weave repo on branch labs/dw-golang)")

  if (( ${#PREREQS_MISSING[@]} > 0 )); then
    echo "Real RDS prerequisites missing:" >&2
    printf '  - %s\n' "${PREREQS_MISSING[@]}" >&2
    echo >&2
    echo "Workarounds:" >&2
    echo "  - run the skill against the local Node stub instead (omit --real / unset MULE_DX_USE_REAL_RDS)" >&2
    echo "  - or install the missing tools and rerun" >&2
    exit 1
  fi
fi

# Pass through 'down' / '--rebuild' verbatim. start-rds.sh handles them.
GO_RUNTIME="$GO_RUNTIME" bash "$START_SCRIPT" "$@"

# 'down' returns before /healthz is up; nothing else to write.
if [[ "${1:-}" == "down" ]]; then
  rm -f "$TMP_DIR/rds.json"
  exit 0
fi

# Verify the RDS the upstream script claimed is healthy actually answers us.
if ! curl -fsS --max-time 2 "$RDS_URL/healthz" >/dev/null; then
  echo "start-rds.sh exited 0 but $RDS_URL/healthz did not respond" >&2
  exit 1
fi

cat >"$TMP_DIR/rds.json" <<JSON
{ "url": "$RDS_URL", "managed": false, "pid": null, "backend": "real" }
JSON

echo "$TMP_DIR/rds.json"
