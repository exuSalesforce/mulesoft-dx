"""Parse Mule flow XML into a flat graph for React Flow rendering.

The graph is intentionally simple for v1:
  - One node per top-level processor inside each <flow> or <sub-flow>.
  - Containers (<choice>, <try>, <scatter-gather>, <error-handler>) collapse
    to a single node summarising their branch count. Their children are not
    visualised; the canvas is for orientation, not deep inspection.
  - Top-level config elements (<*:*-config>, <configuration-properties>)
    are NOT nodes — they appear in the flow XML but represent setup, not
    runtime steps. Click a node and use the chat to ask about its config.
  - Edges connect each processor to the next in document order, plus a
    final edge from the last processor to the error-handler summary node.

Shape returned by `parse_flow_xml`:

    {
      "flows": [
        {
          "id": "<flow-name>",
          "name": "<flow-name>",
          "kind": "flow" | "sub-flow",
          "doc": {"name": "...", "description": "..."},
          "nodes": [
            {
              "id": "<flow-name>::<index>",
              "kind": "trigger" | "processor" | "container" | "error-handler",
              "label": "<short label>",
              "elementName": "salesforce:query",  // namespaced XML tag
              "attributes": {"soql": "...", "config-ref": "...", ...},
              "doc": {"name": "...", "description": "..."},
              "branches": 3,        // only for containers
            },
            ...
          ],
          "edges": [
            {"id": "<a>-><b>", "source": "<a>", "target": "<b>"},
            ...
          ]
        },
        ...
      ],
      "diagnostics": ["..."]   // non-fatal parse notes for the agent
    }

Containers like <try> are not expanded in v1: a real nested visualisation
adds significant scope (see vscode canvas's CreateLayout.tsx). The flat
shape is what the 2026-05-18 design spec calls for. Nesting is a v2 task.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from lxml import etree

# Element names that appear at the top level of <mule> but are NOT runtime
# flow steps. Encountering these inside a <flow> would be unusual but we'd
# still skip them. The set is intentionally small — anything else gets
# rendered as a generic processor.
_NON_FLOW_TOPLEVEL = frozenset(
    {
        "configuration-properties",
        "global-property",
        "import",
        "object",
    }
)

# Container elements whose children we collapse to a "(N branches)" summary
# rather than recursing into. Order matters only for label readability.
_CONTAINER_ELEMENTS = frozenset(
    {
        "choice",
        "scatter-gather",
        "try",
        "until-successful",
        "foreach",
        "parallel-foreach",
        "first-successful",
        "round-robin",
        "async",
    }
)


# Map a flow element's namespaced name to a stable icon lookup key.
# The server resolves this key against ui/icons/<key>.svg at render time and
# embeds the SVG content into the node JSON so the iframe needs no extra
# resource fetches (and so the icon pack is shippable as static assets).
#
# Order matters: connector-prefix matches win over generic mappings so that,
# e.g., http:request lands on `http-request` (not the generic `http-listener`)
# even when the prefix is `http`.
_ICON_KEY_OVERRIDES: dict[str, str] = {
    "http:listener": "http-listener",
    "http:request": "http-request",
    "ee:transform": "transform",
    "set-variable": "set-variable",
    "set-payload": "set-variable",
    "logger": "logger",
    "scheduler": "scheduler",
    "flow-ref": "flow-ref",
    "sub-flow": "sub-flow",
    "choice": "choice",
    "scatter-gather": "scatter-gather",
    "try": "try",
    "foreach": "foreach",
    "parallel-foreach": "foreach",
    "until-successful": "until-successful",
    "round-robin": "round-robin",
    "first-successful": "first-successful",
    "async": "async",
    "error-handler": "error-handler",
    "on-error-propagate": "on-error-propagate",
    "on-error-continue": "on-error-continue",
}


def _icon_key_for(element_name: str, prefix: str, local: str) -> str:
    """Pick a stable icon key for a node.

    Resolution order:
      1. Exact element-name override (e.g. `http:listener`).
      2. Connector prefix (e.g. `salesforce` for `salesforce:query`).
         Falls through to step 3 if no icon ships for that prefix.
      3. Local element name as-is (covers most core processors).
      4. `generic` fallback.

    The actual SVG bytes are loaded server-side before sending the graph
    to the iframe, so an unknown key resolves to `generic` at that layer
    rather than failing here.
    """
    if element_name in _ICON_KEY_OVERRIDES:
        return _ICON_KEY_OVERRIDES[element_name]
    if local in _ICON_KEY_OVERRIDES:
        return _ICON_KEY_OVERRIDES[local]
    if prefix:
        # Connector-namespaced ops (salesforce:query, twilio:sendMessage) get
        # the connector's icon (salesforce.svg) rather than the per-op name.
        return prefix
    return local or "generic"


@dataclass
class _Node:
    id: str
    kind: str
    label: str
    elementName: str
    iconKey: str
    attributes: dict[str, str] = field(default_factory=dict)
    doc: dict[str, str] = field(default_factory=dict)
    branches: int | None = None


@dataclass
class _Edge:
    id: str
    source: str
    target: str


def parse_flow_xml(xml_path: str | Path) -> dict[str, Any]:
    """Parse the Mule flow XML at `xml_path` into a graph dict.

    Raises:
        FileNotFoundError: if the path doesn't exist.
        ValueError: if the document is not a Mule XML file.
    """
    path = Path(xml_path)
    if not path.is_file():
        msg = f"flow XML not found: {xml_path}"
        raise FileNotFoundError(msg)

    parser = etree.XMLParser(remove_comments=True, remove_blank_text=False)
    tree = etree.parse(str(path), parser)
    root = tree.getroot()

    if _localname(root.tag) != "mule":
        msg = f"expected <mule> root, got <{_localname(root.tag)}>"
        raise ValueError(msg)

    diagnostics: list[str] = []
    flows: list[dict[str, Any]] = []

    for child in root:
        local = _localname(child.tag)
        if local in {"flow", "sub-flow"}:
            flows.append(_parse_flow(child, kind=local, diagnostics=diagnostics))
        elif local in _NON_FLOW_TOPLEVEL or "-config" in local:
            # Skip configs and properties — they're not flow steps.
            continue
        else:
            # Top-level element we don't recognise. Note it but don't fail.
            diagnostics.append(f"top-level <{local}> ignored (not a flow)")

    if not flows:
        diagnostics.append("no <flow> or <sub-flow> elements found in document")

    return {"flows": flows, "diagnostics": diagnostics}


def _parse_flow(
    flow_el: etree._Element,
    *,
    kind: str,
    diagnostics: list[str],
) -> dict[str, Any]:
    """Walk one <flow> or <sub-flow> and emit its node + edge lists."""
    flow_name = flow_el.get("name") or f"<unnamed-{kind}>"
    nodes: list[_Node] = []
    edges: list[_Edge] = []

    # Index counts only nodes we emit, so node ids stay sequential even when
    # we skip oddities like <flow-ref> attribute-only refs (we still emit
    # them; this is a placeholder for any future skips).
    idx = 0

    def _next_id() -> str:
        nonlocal idx
        node_id = f"{flow_name}::{idx}"
        idx += 1
        return node_id

    children = [c for c in flow_el if isinstance(c.tag, str)]
    if not children:
        diagnostics.append(f"flow '{flow_name}' has no processors")

    last_processor_id: str | None = None
    error_handler_node: _Node | None = None

    for i, child in enumerate(children):
        local = _localname(child.tag)
        prefix = _prefix(child.tag)
        element_name = f"{prefix}:{local}" if prefix else local

        if local == "error-handler":
            # Collapse the error-handler block to a single node. Its on-error-*
            # children become the branch count.
            branch_count = sum(
                1
                for sub in child
                if isinstance(sub.tag, str) and _localname(sub.tag).startswith("on-error-")
            )
            error_handler_node = _Node(
                id=_next_id(),
                kind="error-handler",
                label=f"Error Handler ({branch_count} branch{'es' if branch_count != 1 else ''})"
                if branch_count
                else "Error Handler",
                elementName=element_name,
                iconKey=_icon_key_for(element_name, prefix, local),
                attributes=_attrs(child),
                doc=_doc(child),
                branches=branch_count or None,
            )
            continue

        is_trigger = i == 0 and _is_trigger(local, prefix, child)
        is_container = local in _CONTAINER_ELEMENTS

        icon_key = _icon_key_for(element_name, prefix, local)

        if is_container:
            branch_count = sum(1 for sub in child if isinstance(sub.tag, str))
            label = _container_label(local, branch_count, child)
            node = _Node(
                id=_next_id(),
                kind="container",
                label=label,
                elementName=element_name,
                iconKey=icon_key,
                attributes=_attrs(child),
                doc=_doc(child),
                branches=branch_count,
            )
        elif is_trigger:
            node = _Node(
                id=_next_id(),
                kind="trigger",
                label=_label_for(child, element_name),
                elementName=element_name,
                iconKey=icon_key,
                attributes=_attrs(child),
                doc=_doc(child),
            )
        else:
            node = _Node(
                id=_next_id(),
                kind="processor",
                label=_label_for(child, element_name),
                elementName=element_name,
                iconKey=icon_key,
                attributes=_attrs(child),
                doc=_doc(child),
            )

        nodes.append(node)
        if last_processor_id is not None:
            edges.append(_make_edge(last_processor_id, node.id))
        last_processor_id = node.id

    if error_handler_node is not None:
        nodes.append(error_handler_node)
        if last_processor_id is not None:
            edges.append(_make_edge(last_processor_id, error_handler_node.id))

    return {
        "id": flow_name,
        "name": flow_name,
        "kind": kind,
        "doc": _doc(flow_el),
        "nodes": [_serialise_node(n) for n in nodes],
        "edges": [_serialise_edge(e) for e in edges],
    }


def _is_trigger(local: str, prefix: str, _el: etree._Element) -> bool:
    """Heuristic: the first child of a flow is a trigger if it's a known source."""
    # Core triggers.
    if local == "scheduler":
        return True
    # http:listener as trigger (vs http:request as processor).
    if prefix == "http" and local == "listener":
        return True
    # Connector sources are conventionally named <prefix>:on-* or end in
    # -listener / -source. Very approximate — refine when we see real sources
    # from the connector catalog.
    if prefix and (local.startswith("on-") or local.endswith("-listener") or local.endswith("-source")):
        return True
    return False


def _container_label(local: str, branches: int, el: etree._Element) -> str:
    """Human-readable label for a container node."""
    if local == "choice":
        whens = sum(1 for c in el if isinstance(c.tag, str) and _localname(c.tag) == "when")
        otherwise = sum(1 for c in el if isinstance(c.tag, str) and _localname(c.tag) == "otherwise")
        suffix = f"{whens} when{'s' if whens != 1 else ''}"
        if otherwise:
            suffix += " + otherwise"
        return f"Choice ({suffix})"
    if local == "scatter-gather":
        return f"Scatter-Gather ({branches} routes)"
    if local == "try":
        return "Try"
    if local == "foreach":
        return "For Each"
    if local == "until-successful":
        return "Until Successful"
    if local == "parallel-foreach":
        return "Parallel For Each"
    if local == "round-robin":
        return f"Round Robin ({branches} routes)"
    if local == "first-successful":
        return f"First Successful ({branches} routes)"
    if local == "async":
        return "Async"
    return local.replace("-", " ").title()


def _label_for(el: etree._Element, element_name: str) -> str:
    """Prefer doc:name for a node label; fall back to the element name."""
    doc_name = _ns_attr(el, "documentation", "name")
    if doc_name:
        return doc_name
    return element_name


def _doc(el: etree._Element) -> dict[str, str]:
    """Extract doc:name and doc:description into a dict (omit if absent)."""
    out: dict[str, str] = {}
    name = _ns_attr(el, "documentation", "name")
    if name:
        out["name"] = name
    desc = _ns_attr(el, "documentation", "description")
    if desc:
        out["description"] = desc
    return out


def _attrs(el: etree._Element) -> dict[str, str]:
    """All XML attributes EXCEPT doc:* (those land in `doc`)."""
    out: dict[str, str] = {}
    for raw_key, val in el.attrib.items():
        # `raw_key` is in Clark notation when namespaced: "{uri}local"
        if raw_key.startswith("{"):
            uri, _, local = raw_key[1:].partition("}")
            if uri.endswith("/documentation"):
                continue
            # Render namespaced attrs as "<prefix>:<local>" if we can guess the
            # prefix from the element's nsmap; fall back to the local name.
            prefix = _prefix_for_uri(el, uri)
            key = f"{prefix}:{local}" if prefix else local
        else:
            key = raw_key
        out[key] = val
    return out


def _serialise_node(n: _Node) -> dict[str, Any]:
    out: dict[str, Any] = {
        "id": n.id,
        "kind": n.kind,
        "label": n.label,
        "elementName": n.elementName,
        "iconKey": n.iconKey,
        "attributes": n.attributes,
    }
    if n.doc:
        out["doc"] = n.doc
    if n.branches is not None:
        out["branches"] = n.branches
    return out


def _serialise_edge(e: _Edge) -> dict[str, str]:
    return {"id": e.id, "source": e.source, "target": e.target}


def _make_edge(source: str, target: str) -> _Edge:
    return _Edge(id=f"{source}->{target}", source=source, target=target)


def _localname(tag: str) -> str:
    """Strip the namespace from a Clark-notation tag name."""
    if "}" in tag:
        return tag.split("}", 1)[1]
    return tag


def _prefix(tag: str) -> str:
    """Best-effort prefix lookup; returns '' for the default namespace."""
    if not tag.startswith("{"):
        return ""
    uri = tag[1:].split("}", 1)[0]
    # Map well-known Mule namespace URIs back to their canonical prefix.
    return _PREFIX_FOR_URI.get(uri, "")


def _prefix_for_uri(el: etree._Element, uri: str) -> str:
    """Resolve a URI back to a prefix using the element's nsmap."""
    for prefix, ns_uri in (el.nsmap or {}).items():
        if ns_uri == uri and prefix:
            return prefix
    return _PREFIX_FOR_URI.get(uri, "")


def _ns_attr(el: etree._Element, prefix_match: str, local: str) -> str | None:
    """Look up an attribute by namespace-prefix tail + local name.

    The Mule documentation namespace is matched by suffix so the lookup works
    regardless of which prefix the document uses.
    """
    for raw_key, val in el.attrib.items():
        if not raw_key.startswith("{"):
            continue
        uri, _, lname = raw_key[1:].partition("}")
        if uri.endswith("/" + prefix_match) and lname == local:
            return val
    return None


# Canonical prefix for well-known Mule namespace URIs. Used when an element's
# nsmap doesn't provide a prefix (rare but possible). The skill never emits
# the default-namespace form for connector elements, but we still cover it.
_PREFIX_FOR_URI: dict[str, str] = {
    "http://www.mulesoft.org/schema/mule/core": "",
    "http://www.mulesoft.org/schema/mule/documentation": "doc",
    "http://www.mulesoft.org/schema/mule/ee/core": "ee",
    "http://www.mulesoft.org/schema/mule/http": "http",
    "http://www.mulesoft.org/schema/mule/salesforce": "salesforce",
    "http://www.mulesoft.org/schema/mule/twilio": "twilio",
}
