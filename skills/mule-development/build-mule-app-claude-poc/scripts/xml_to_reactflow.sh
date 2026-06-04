#!/usr/bin/env bash
#
# Copyright (c) 2026, Salesforce, Inc.
# All rights reserved.
# For full license text, see the LICENSE.txt file
#
# Part of build-mule-app-claude-poc skill.
#
# Step 10 helper — translate the scaffolded Mule XML into the
# `{ nodes, edges }` JSON shape that React Flow consumes. The output is
# what the canvas renders in the user's response after Step 9.
#
# Usage:
#   scripts/xml_to_reactflow.sh <project-dir>
#
# Where:
#   <project-dir> — the directory the scaffolder created (contains
#                   src/main/mule/<project-name>.xml).
#
# Output:
#   tmp/reactflow/<project-name>.json
#   stdout — same JSON, pretty-printed
#
# Translation rules (kept in sync with SKILL.md Step 10):
#   - One node per element under <flow> that carries a `doc:name`.
#   - data.label = doc:name, data.doc = doc:description, type = element kind.
#   - <choice> / <error-handler> emit a parent node plus one child per
#     <when> / <otherwise> / <on-error-*> branch with edges fanning out
#     and back into the next sequential node.
#   - Layout is left-to-right at 200px increments per top-level step;
#     branches stack vertically at ±150px on the y axis.
#
# Implementation note: XML parsing is done in python3 via an embedded
# heredoc. Bash + sed handles flat XML acceptably; nested elements with
# namespaces (which Mule XML always has) are reliable only with a real
# XML parser, and python's xml.etree.ElementTree is in the standard
# library on every platform we target.
#
# Exit code:
#   0  success
#   1  no project dir / no XML file / XML parse error
set -euo pipefail

usage() {
    echo "Usage: $0 <project-dir>" >&2
    echo "  e.g. $0 ./salesforce-accounts-to-twilio" >&2
}

PROJECT_DIR="${1:-}"
if [ -z "$PROJECT_DIR" ]; then
    usage
    exit 1
fi
if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ project directory not found: $PROJECT_DIR" >&2
    exit 1
fi

# Locate the flow XML — the scaffolder writes exactly one file under
# src/main/mule/, named <project>.xml.
XML_FILE=$(find "$PROJECT_DIR/src/main/mule" -maxdepth 1 -name '*.xml' -type f 2>/dev/null | head -n 1 || true)
if [ -z "$XML_FILE" ] || [ ! -f "$XML_FILE" ]; then
    echo "❌ no Mule XML found under $PROJECT_DIR/src/main/mule/" >&2
    exit 1
fi

PROJECT_NAME=$(basename "$XML_FILE" .xml)
OUT_DIR="${REACTFLOW_OUT_DIR:-tmp/reactflow}"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/${PROJECT_NAME}.json"

python3 - "$XML_FILE" "$OUT_FILE" <<'PYEOF'
import json
import re
import sys
import xml.etree.ElementTree as ET

xml_path, out_path = sys.argv[1], sys.argv[2]

DOC_NS = "http://www.mulesoft.org/schema/mule/documentation"
CORE_NS = "http://www.mulesoft.org/schema/mule/core"

def localname(tag: str) -> str:
    """{namespace}local -> local"""
    return tag.split("}", 1)[1] if "}" in tag else tag

def ns_uri(tag: str) -> str:
    return tag.split("}", 1)[0][1:] if tag.startswith("{") else ""

def ns_prefix_from_uri(uri: str) -> str:
    """Recover the connector prefix from the namespace URI.
    'http://www.mulesoft.org/schema/mule/salesforce' -> 'salesforce'"""
    m = re.search(r"/mule/([^/]+)$", uri or "")
    return m.group(1) if m else ""

def doc_name(el):
    return el.attrib.get(f"{{{DOC_NS}}}name", "")

def doc_desc(el):
    return el.attrib.get(f"{{{DOC_NS}}}description", "")

def classify(el) -> str:
    """Map an element to a React Flow node `type` string.

    Mule XML uses the connector's namespace as a prefix for operations
    (salesforce:query, twilio:create...), so anything in a non-core
    namespace defaults to 'operation' unless it is one of the EE
    transform / http listener tags we know about.
    """
    local = localname(el.tag)
    uri = ns_uri(el.tag)

    if local == "listener" and uri.endswith("/http"):
        return "trigger"
    if local == "transform" and uri.endswith("/ee/core"):
        return "transform"
    if local in ("logger", "set-variable", "set-payload", "flow-ref",
                 "choice", "error-handler", "raise-error"):
        return local
    if local in ("when", "otherwise"):
        return "branch"
    if local.startswith("on-error"):
        return "error-branch"
    # Anything else in a non-core namespace is a connector operation.
    if uri and uri != CORE_NS and not uri.endswith("/ee/core") and \
       not uri.endswith("/documentation") and not uri.endswith("/http"):
        return "operation"
    return local

# Parse the XML.
try:
    tree = ET.parse(xml_path)
except ET.ParseError as exc:
    print(f"❌ failed to parse XML: {exc}", file=sys.stderr)
    sys.exit(1)
root = tree.getroot()

# Find the <flow> element. There is exactly one in this POC.
flow = None
for child in root:
    if localname(child.tag) == "flow":
        flow = child
        break
if flow is None:
    print("❌ no <flow> element found in XML", file=sys.stderr)
    sys.exit(1)

nodes, edges = [], []
node_counter = [0]

def new_id():
    node_counter[0] += 1
    return f"n{node_counter[0]}"

def add_node(el, *, x, y, type_override=None):
    """Add one React Flow node for an XML element. Returns the node id."""
    nid = new_id()
    label = doc_name(el)
    if not label:
        # Fall back to the element's local name so the canvas never has
        # an empty label — the scaffolder is supposed to set doc:name on
        # everything, but this keeps the visualization useful even if
        # one slips through.
        prefix = ns_prefix_from_uri(ns_uri(el.tag))
        label = f"{prefix}:{localname(el.tag)}" if prefix else localname(el.tag)
    nodes.append({
        "id": nid,
        "type": type_override or classify(el),
        "data": {
            "label": label,
            "doc":   doc_desc(el),
        },
        "position": {"x": x, "y": y},
    })
    return nid

def add_edge(src, tgt):
    edges.append({
        "id":     f"e{src}-{tgt}",
        "source": src,
        "target": tgt,
    })

# Walk top-level children of <flow>. Each one becomes either a single
# node (linear step) or a parent + branch nodes (choice / error-handler).
X_STEP = 200
Y_BRANCH = 150
prev_id = None
x_cursor = 0

# Error-handler is rendered as a side-branch off the flow node itself,
# not as a sequential step — the runtime invokes it on error, not on
# success — so we collect it separately and render after the main path.
error_handler_el = None

for child in flow:
    kind = classify(child)
    if kind == "error-handler":
        error_handler_el = child
        continue

    if kind == "choice":
        # Parent node + one branch per <when>/<otherwise>. Each branch
        # gets one node (the first element with doc:name inside it).
        parent_id = add_node(child, x=x_cursor, y=0)
        if prev_id is not None:
            add_edge(prev_id, parent_id)

        branch_ids = []
        branches = [b for b in child if classify(b) in ("branch",)]
        x_branch = x_cursor + X_STEP
        for i, branch_el in enumerate(branches):
            # Stack branches vertically around y=0
            y = (i - (len(branches) - 1) / 2) * Y_BRANCH
            bid = add_node(branch_el, x=x_branch, y=int(y))
            add_edge(parent_id, bid)
            branch_ids.append(bid)

        # Subsequent siblings join all branches via fan-in. We track
        # "previous ids" as a list for the next sibling's edge creation.
        x_cursor = x_branch + X_STEP
        # Use a sentinel: prev_id holds either a single id or a tuple of
        # ids. Convert to tuple to signal fan-in to the next iteration.
        prev_id = tuple(branch_ids) if branch_ids else parent_id
        continue

    # Plain sequential step.
    nid = add_node(child, x=x_cursor, y=0)
    if prev_id is not None:
        if isinstance(prev_id, tuple):
            for src in prev_id:
                add_edge(src, nid)
        else:
            add_edge(prev_id, nid)
    prev_id = nid
    x_cursor += X_STEP

# Render the error-handler off to the side, below the main flow.
if error_handler_el is not None:
    eh_id = add_node(error_handler_el, x=0, y=Y_BRANCH * 2)
    eh_branches = [b for b in error_handler_el if classify(b) == "error-branch"]
    x_eh = X_STEP
    for i, branch_el in enumerate(eh_branches):
        y = Y_BRANCH * 2 + (i * Y_BRANCH)
        bid = add_node(branch_el, x=x_eh, y=y)
        add_edge(eh_id, bid)

result = {"nodes": nodes, "edges": edges}
with open(out_path, "w") as f:
    json.dump(result, f, indent=2)
    f.write("\n")
PYEOF

echo "✅ wrote $OUT_FILE"
echo ""
echo "--- $OUT_FILE ---"
cat "$OUT_FILE"
