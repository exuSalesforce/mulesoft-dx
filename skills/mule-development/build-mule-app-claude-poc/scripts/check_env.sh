#!/usr/bin/env bash
#
# Copyright (c) 2026, Salesforce, Inc.
# All rights reserved.
# For full license text, see the LICENSE.txt file
#
# Part of build-mule-app-claude-poc skill.
#
# Step 1 helper — validate that the POC's runtime requirements are present
# (curl, jq) and that the Remote Design Service responds to GET /healthz.
# No Java, no Anypoint CLI, no Maven — all of those were intentionally
# dropped from this POC.
#
# Output path: ${POC_ENV_FILE} when set, otherwise tmp/poc-env.json
# (workspace-relative). The default lives inside the current workspace so
# each task gets its own env cache.
#
# Output JSON shape:
#   {
#     "ok": true|false,
#     "errors": [...],
#     "warnings": [...],
#     "rds_base_url": "http://localhost:8090",
#     "rds_auth_token": "",          // never the literal token — just "" or "set"
#     "rds_health": { "status": "ok" }
#   }
#
# Exit code:
#   0  all checks passed
#   1  one or more fatal checks failed — agent should act on the errors array
set -euo pipefail

OUT_FILE="${POC_ENV_FILE:-tmp/poc-env.json}"
mkdir -p "$(dirname "$OUT_FILE")" 2>/dev/null || true

ERRORS=()
WARNINGS=()

echo "Validating environment for the Mule App POC..."

# 1. jq — required by every other script for JSON I/O
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq not installed"
    case "$(uname -s)" in
        Darwin*)              ERRORS+=("jq not installed. Fix: brew install jq") ;;
        MINGW*|MSYS*|CYGWIN*) ERRORS+=("jq not installed. Download https://jqlang.github.io/jq/download/, rename to jq.exe, place on PATH") ;;
        *)                    ERRORS+=("jq not installed. Fix: sudo apt-get install jq (or distro equivalent)") ;;
    esac
else
    echo "✅ jq found: $(jq --version)"
fi

# 2. curl
if ! command -v curl >/dev/null 2>&1; then
    echo "❌ curl not installed"
    ERRORS+=("curl not installed. Fix: install via your package manager (brew/apt/etc.).")
else
    echo "✅ curl found"
fi

# 3. RDS_BASE_URL — fall back to a sensible default for the Docker container.
#    The skill's Step 1 prompts the user via AskUserQuestion if the default
#    is wrong; this script never prompts.
RDS_BASE_URL="${RDS_BASE_URL:-http://localhost:8090}"
RDS_AUTH_TOKEN="${RDS_AUTH_TOKEN:-}"
echo "ℹ️  RDS_BASE_URL = $RDS_BASE_URL"
if [ -n "$RDS_AUTH_TOKEN" ]; then
    echo "ℹ️  RDS_AUTH_TOKEN is set (value redacted)"
else
    echo "ℹ️  RDS_AUTH_TOKEN not set (anonymous access)"
fi

# 4. Healthz — only attempt if curl was found.
HEALTH_BODY=""
HEALTH_STATUS=""
if command -v curl >/dev/null 2>&1; then
    AUTH_ARGS=()
    if [ -n "$RDS_AUTH_TOKEN" ]; then
        AUTH_ARGS=(-H "Authorization: Bearer $RDS_AUTH_TOKEN")
    fi
    HEALTH_TMP="$(mktemp)"
    HEALTH_HTTP_CODE=$(curl -sS -o "$HEALTH_TMP" -w "%{http_code}" \
        "${AUTH_ARGS[@]}" \
        "$RDS_BASE_URL/healthz" 2>/dev/null || echo "000")
    HEALTH_BODY="$(cat "$HEALTH_TMP")"
    rm -f "$HEALTH_TMP"

    if [ "$HEALTH_HTTP_CODE" = "200" ]; then
        if echo "$HEALTH_BODY" | jq -e '.ready == true' >/dev/null 2>&1; then
            HEALTH_STATUS="ok"
            echo "✅ Remote Design Service healthy at $RDS_BASE_URL"
        else
            HEALTH_STATUS="unexpected"
            ERRORS+=("Remote Design Service /healthz returned 200 but body was not {\"ready\":true}: $HEALTH_BODY")
        fi
    elif [ "$HEALTH_HTTP_CODE" = "000" ]; then
        ERRORS+=("Remote Design Service unreachable at $RDS_BASE_URL — curl could not connect. Start the Docker container or set RDS_BASE_URL.")
    else
        ERRORS+=("Remote Design Service /healthz returned HTTP $HEALTH_HTTP_CODE: $HEALTH_BODY")
    fi
fi

OK="true"
if [ ${#ERRORS[@]} -gt 0 ]; then
    OK="false"
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    ERRORS_JSON=$(printf '%s\n' "${ERRORS[@]}" | jq -R . | jq -s .)
else
    ERRORS_JSON="[]"
fi
if [ ${#WARNINGS[@]} -gt 0 ]; then
    WARNINGS_JSON=$(printf '%s\n' "${WARNINGS[@]}" | jq -R . | jq -s .)
else
    WARNINGS_JSON="[]"
fi

if [ -n "$RDS_AUTH_TOKEN" ]; then
    AUTH_PRESENCE='"set"'
else
    AUTH_PRESENCE='""'
fi

if [ "$HEALTH_STATUS" = "ok" ]; then
    HEALTH_JSON='{"status":"ok"}'
else
    HEALTH_JSON='null'
fi

cat >"$OUT_FILE" <<JSON
{
  "ok": $OK,
  "errors": $ERRORS_JSON,
  "warnings": $WARNINGS_JSON,
  "rds_base_url": "$RDS_BASE_URL",
  "rds_auth_token": $AUTH_PRESENCE,
  "rds_health": $HEALTH_JSON
}
JSON

echo "📝 Wrote $OUT_FILE"

if [ "$OK" = "false" ]; then
    exit 1
fi
