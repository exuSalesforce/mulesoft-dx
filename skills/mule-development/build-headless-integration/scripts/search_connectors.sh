#!/usr/bin/env bash
# Phase 1 Step 4: list available Go-connector bundles matching a search term.
#
# Demo 2 ships a static catalog rooted at fixtures/go-connectors/<name>/. This
# script reads each bundle's extension-model.json and prints lines of:
#
#   <bundle-name>\t<connector-name>\t<version>\t<vendor>\t<dsl-prefix>
#
# Filtered case-insensitively against the search term across name and bundle dir.
# The agent picks one of the printed bundle-names and feeds it to pick_connector.sh.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERM_ARG="${1:-}"

if [[ -z "$TERM_ARG" ]]; then
  echo "Usage: search_connectors.sh <term>" >&2
  exit 2
fi

term_lc="$(printf '%s' "$TERM_ARG" | tr '[:upper:]' '[:lower:]')"

CATALOG_DIR="$SKILL_DIR/fixtures/go-connectors"
if [[ ! -d "$CATALOG_DIR" ]]; then
  echo "no catalog at $CATALOG_DIR" >&2
  exit 1
fi

shopt -s nullglob
matched=0
for bundle in "$CATALOG_DIR"/*/; do
  name="$(basename "$bundle")"
  em="$bundle/extension-model.json"
  if [[ ! -f "$em" ]]; then continue; fi

  cname="$(jq -r '.name // ""' "$em")"
  cver="$(jq -r '.version // ""' "$em")"
  cvendor="$(jq -r '.vendor // ""' "$em")"
  cprefix="$(jq -r '.xmlDsl.prefix // ""' "$em")"

  hay="$(printf '%s %s %s' "$name" "$cname" "$cprefix" | tr '[:upper:]' '[:lower:]')"
  if [[ "$hay" == *"$term_lc"* ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$cname" "$cver" "$cvendor" "$cprefix"
    matched=$((matched + 1))
  fi
done

if (( matched == 0 )); then
  echo "no Go connector bundles match '$TERM_ARG'" >&2
  exit 1
fi
