#!/usr/bin/env bash
#
# Copyright (c) 2026, Salesforce, Inc.
# All rights reserved.
# For full license text, see the LICENSE.txt file
#
# Part of build-mule-app-claude-poc skill.
#
# Shared helper sourced by every script that talks to the Remote Design
# Service. Provides:
#   rds_base_url        — resolves the RDS base URL (env var → poc-env.json
#                         → default http://localhost:8090).
#   rds_auth_header     — emits the curl `-H "Authorization: Bearer <tok>"`
#                         args when a token is present; nothing otherwise.
#   rds_get <path> <out_file>
#                       — GET <RDS>/<path>, write body to <out_file>, exit
#                         non-zero with stderr error envelope on any HTTP
#                         status outside 2xx or any curl transport error.
#
# Sourcing convention:
#   POC_SKILL_DIR=... # absolute skill dir handed to the agent at runtime
#   . "$POC_SKILL_DIR/scripts/_rds_lib.sh"
# (or, with the more common idiom, source by relative dir from the script
# itself — every script computes its own dir below.)

# Safe to source under `set -u` callers: only set defaults if not already set.
: "${POC_ENV_FILE:=tmp/poc-env.json}"
: "${RDS_API_PREFIX:=/v1}"

rds_base_url() {
    if [ -n "${RDS_BASE_URL:-}" ]; then
        printf '%s' "$RDS_BASE_URL"
        return
    fi
    if [ -f "$POC_ENV_FILE" ]; then
        local from_file
        from_file="$(jq -r '.rds_base_url // empty' "$POC_ENV_FILE" 2>/dev/null || true)"
        if [ -n "$from_file" ]; then
            printf '%s' "$from_file"
            return
        fi
    fi
    printf '%s' "http://localhost:8090"
}

rds_auth_args() {
    # Emit curl args (one per line — caller `mapfile`s them) for the auth
    # header. No output if no token.
    if [ -n "${RDS_AUTH_TOKEN:-}" ]; then
        printf '%s\n' "-H" "Authorization: Bearer $RDS_AUTH_TOKEN"
    fi
}

# rds_get <path> <out_file>
#   <path>     — e.g. "/connectors" or "/connectors/salesforce/descriptor"
#                The path is prefixed with $RDS_API_PREFIX (default "/v1")
#                unless it already starts with "/v" or with "/healthz".
#   <out_file> — destination file for the response body
#
# On success: out_file contains the body, function returns 0.
# On any non-2xx or curl error: prints body + diagnostic to stderr,
# removes out_file, returns 1.
rds_get() {
    local path="$1"
    local out_file="$2"
    local base
    base="$(rds_base_url)"

    # Prefix with /v1 unless caller passed an already-prefixed path or an
    # unversioned health probe.
    case "$path" in
        /healthz|/v[0-9]*) ;;
        /*) path="${RDS_API_PREFIX%/}${path}" ;;
    esac

    local url="${base%/}${path}"

    # Build auth args without forcing the caller to handle empty arrays
    # under `set -u`.
    local auth_args=()
    if [ -n "${RDS_AUTH_TOKEN:-}" ]; then
        auth_args=(-H "Authorization: Bearer $RDS_AUTH_TOKEN")
    fi

    local http_code
    http_code=$(curl -sS -o "$out_file" -w "%{http_code}" \
        "${auth_args[@]}" \
        "$url" 2>/dev/null || echo "000")

    case "$http_code" in
        2*)
            return 0
            ;;
        000)
            echo "❌ Remote Design Service unreachable at $url" >&2
            echo "   Set RDS_BASE_URL or start the Docker container." >&2
            rm -f "$out_file"
            return 1
            ;;
        *)
            echo "❌ Remote Design Service returned HTTP $http_code for $url" >&2
            if [ -s "$out_file" ]; then
                # Pretty-print if it parses as JSON, raw otherwise.
                if jq -e . "$out_file" >/dev/null 2>&1; then
                    jq . "$out_file" >&2
                else
                    cat "$out_file" >&2
                fi
            fi
            rm -f "$out_file"
            return 1
            ;;
    esac
}
