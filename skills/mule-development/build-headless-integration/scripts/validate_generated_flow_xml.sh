#!/usr/bin/env bash
# Phase 2 sanity check: validate the generated flow XML against the connector digests
# cached in tmp/connector-metadata/. Cheaper analogue of the build-mule-integration
# skill's validate_before_build.sh — we don't run mvn, but we still want to catch
# the bad-XML failure modes that mvn used to surface.
#
# Checks:
#   1. Every xmlns:<prefix> in <mule> has a matching xsi:schemaLocation pair
#   2. Every <prefix:elementName> appears in the digest's known DSL element set
#      (or in a small set of trusted core/ee/http names)
#   3. Every <on-error-propagate type="X:Y"> uses a type the digest declares
#   4. Every config-ref="name" resolves to a top-level element by that name
#   5. Every ${dotted.key} placeholder has a matching key in config.yaml
#
# Usage: bash scripts/validate_generated_flow_xml.sh <projectDir>
#   exit 0 on success, non-zero on first batch of issues with a clear stderr report
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"

PROJECT_DIR="${1:-}"
if [[ -z "$PROJECT_DIR" ]]; then
  echo "Usage: validate_generated_flow_xml.sh <projectDir>" >&2
  exit 2
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "no project dir at $PROJECT_DIR" >&2
  exit 1
fi

node "$SKILL_DIR/helpers/validate_flow.mjs" "$PROJECT_DIR"
