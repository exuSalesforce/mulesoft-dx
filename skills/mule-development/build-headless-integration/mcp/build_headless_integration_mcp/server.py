"""FastMCP server entry point.

Exposes one tool, `render_mule_flow`, that takes a Mule project directory,
parses the flow XML inside, and returns a UI resource Claude Desktop renders
inline as a React Flow canvas.

Mirrors the conventions in mulesoft-omni-app/server_py/mcp_apps/.
"""

from __future__ import annotations

import re
from pathlib import Path

from mcp.server.fastmcp import FastMCP
from mcp.server.lowlevel.helper_types import ReadResourceContents
from mcp.types import AnyUrl, CallToolResult, TextContent, ToolAnnotations

from . import __version__
from .parse import parse_flow_xml

# Match the mcp-app MIME profile used by the omni-app shared composer.
RESOURCE_URI = "ui://mule-flow-canvas/app.html"
RESOURCE_MIME_TYPE = "text/html;profile=mcp-app"

# CSP whitelist for the iframe sandbox. Without this, the secure default
# blocks all external script/style/font loads, which means the CDN-hosted
# React/ReactFlow/dagre UMD bundles never execute and the iframe stays blank.
# - resourceDomains covers <script>, <style>, <link rel=stylesheet>, fonts, images
# - connectDomains covers fetch/XHR/WebSocket — empty here because the iframe
#   only consumes the tool-result via postMessage and never makes its own
#   network calls.
_UI_CSP = {
    "resourceDomains": [
        "https://unpkg.com",
        "https://cdn.jsdelivr.net",
    ],
    "connectDomains": [],
}

_UI_DIR = Path(__file__).parent / "ui"
_ICONS_DIR = _UI_DIR / "icons"


def _load_icon(icon_key: str) -> str:
    """Resolve an iconKey (from parse.py) to inline SVG markup.

    Falls back to `generic.svg` for any key without a bundled icon. The
    SVG content is embedded into each node's JSON sent to the iframe so
    no extra resource fetches are needed for icon rendering.

    Normalisation: the bundled icons declare width/height (64×64) but most
    omit a viewBox, which means CSS-driven downscaling crops instead of
    scales. We inject `viewBox="0 0 64 64"` and strip the explicit
    width/height so the iframe's CSS `.flow-node-icon svg { width:32px; ... }`
    produces a properly scaled icon.
    """
    candidate = _ICONS_DIR / f"{icon_key}.svg"
    if not candidate.is_file():
        candidate = _ICONS_DIR / "generic.svg"
    raw = candidate.read_text(encoding="utf-8")
    return _normalise_svg(raw)


def _normalise_svg(svg: str) -> str:
    """Add viewBox="0 0 64 64" if missing; drop hardcoded width/height attrs."""
    # Only touch the opening <svg ...> tag.
    match = re.search(r"<svg\b[^>]*>", svg, flags=re.IGNORECASE)
    if not match:
        return svg
    open_tag = match.group(0)

    new_tag = open_tag
    if "viewBox" not in new_tag:
        # Use width/height if present; default to 64×64 (the bundled size).
        w = re.search(r'width="(\d+)"', new_tag)
        h = re.search(r'height="(\d+)"', new_tag)
        vw = w.group(1) if w else "64"
        vh = h.group(1) if h else "64"
        new_tag = new_tag[:-1] + f' viewBox="0 0 {vw} {vh}">'

    # Strip explicit width/height — let CSS control the rendered size.
    new_tag = re.sub(r'\s+width="\d+"', "", new_tag)
    new_tag = re.sub(r'\s+height="\d+"', "", new_tag)

    return svg.replace(open_tag, new_tag, 1)


def _enrich_with_icons(graph: dict) -> None:
    """Mutate `graph` in place: each flow node gains an `icon` field."""
    for flow in graph.get("flows", []):
        for node in flow.get("nodes", []):
            key = node.get("iconKey") or "generic"
            node["icon"] = _load_icon(key)


def _serve_app_html() -> str:
    """Compose and return the bundled HTML.

    Read the body from ui/app.html and inject ui/app.css and ui/app.js into
    the served document. Doing the assembly at request-time means edits to
    ui/* files take effect on the next tool call without restarting the
    server (helpful while iterating).
    """
    html = (_UI_DIR / "app.html").read_text(encoding="utf-8")
    css = (_UI_DIR / "app.css").read_text(encoding="utf-8")
    js = (_UI_DIR / "app.js").read_text(encoding="utf-8")
    return (
        html.replace("/*__APP_CSS__*/", css)
        .replace("/*__APP_JS__*/", js)
    )


def _resolve_flow_xml(project_dir: str) -> Path:
    """Find the project's flow XML.

    The skill's `create_versionless_project.sh` always emits exactly one
    file under `<projectDir>/src/main/mule/<projectName>.xml`; we pick that
    deterministically. If a user has multiple flow files we render the
    first (alphabetical) and surface a diagnostic — multi-file rendering
    is a v2 task.
    """
    project = Path(project_dir).expanduser().resolve()
    if not project.is_dir():
        msg = f"project_dir is not a directory: {project_dir}"
        raise NotADirectoryError(msg)

    mule_dir = project / "src" / "main" / "mule"
    if not mule_dir.is_dir():
        msg = f"no src/main/mule/ under {project} — is this a Mule project?"
        raise FileNotFoundError(msg)

    xml_files = sorted(mule_dir.glob("*.xml"))
    if not xml_files:
        msg = f"no flow XML files in {mule_dir}"
        raise FileNotFoundError(msg)

    return xml_files[0]


def _build_server() -> FastMCP:
    """Build and return the configured FastMCP server.

    Factored out so tests can introspect the server without invoking main().
    """
    server = FastMCP(
        "build-headless-integration-mcp",
        instructions=(
            "Renders Mule flow XML inline as an interactive React Flow canvas. "
            "Companion to the build-headless-integration skill: after the skill "
            "writes src/main/mule/<name>.xml, call render_mule_flow(project_dir) "
            "to display the flow."
        ),
    )

    # Register the UI resource via the low-level read_resource handler so we
    # can attach `_meta.ui.csp` to the content item. FastMCP's high-level
    # `server.resource(...)` decorator only allows str/bytes return values
    # and doesn't expose per-content-item _meta, but the MCP UI extension
    # needs the CSP allowlist on the resource read result for the iframe
    # sandbox to permit our CDN-hosted React/ReactFlow/dagre bundles.
    #
    # We still register a high-level resource (no callback meta) so it shows
    # up in `resources/list` for discoverability; the low-level handler
    # below is what actually serves `resources/read` requests.
    server.resource(
        RESOURCE_URI,
        name="mule-flow-canvas-ui",
        title="Mule Flow Canvas",
        description="Interactive React Flow canvas for a Mule application's flows",
        mime_type=RESOURCE_MIME_TYPE,
    )(_serve_app_html)

    @server._mcp_server.read_resource()
    async def _read_resource(uri: AnyUrl):
        if str(uri) == RESOURCE_URI:
            return [
                ReadResourceContents(
                    content=_serve_app_html(),
                    mime_type=RESOURCE_MIME_TYPE,
                    meta={"ui": {"csp": _UI_CSP}},
                ),
            ]
        msg = f"unknown resource: {uri}"
        raise ValueError(msg)

    ui_meta = {
        "ui": {"resourceUri": RESOURCE_URI},
        "ui/resourceUri": RESOURCE_URI,
    }

    async def render_mule_flow(project_dir: str) -> CallToolResult:
        """Render the Mule project's flow XML as a React Flow canvas.

        Args:
            project_dir: Absolute path to a Mule project directory. The tool
                reads `<project_dir>/src/main/mule/<name>.xml` (the file
                emitted by the build-headless-integration skill) and returns
                a graph the canvas iframe consumes.

        Returns:
            A CallToolResult with:
              - `content`: a short status TextContent block. Visible-chat
                rendering depends on host implementation: hosts with the
                MCP UI extension (Claude Desktop) iframe ui://mule-flow-canvas/app.html
                inline; hosts without it just show this status string.
              - `structuredContent`: the full flow graph the iframe renders
                AND the LLM reasons about. The iframe's app.js reads it
                from `params.result.structuredContent` on tool-result.
        """
        xml_path = _resolve_flow_xml(project_dir)
        graph = parse_flow_xml(xml_path)
        _enrich_with_icons(graph)

        # Surface where the data came from so a developer reading the chat
        # transcript can trace back to disk.
        graph["source"] = {
            "projectDir": str(Path(project_dir).expanduser().resolve()),
            "xmlPath": str(xml_path),
        }

        flow_count = len(graph.get("flows", []))
        node_count = sum(len(f.get("nodes", [])) for f in graph.get("flows", []))
        status = (
            f"Rendered {flow_count} flow"
            + ("" if flow_count == 1 else "s")
            + f" ({node_count} node" + ("" if node_count == 1 else "s") + ") "
            + f"from {xml_path.name}."
        )

        # The MCP UI extension (io.modelcontextprotocol/ui) lets hosts iframe a
        # registered ui://… resource inline when the *tool result* envelope
        # carries `_meta.ui.resourceUri`. The same hint on the tool definition
        # alone is treated as a discoverability default by some hosts but not
        # all — the per-call _meta is what Claude Desktop actually keys on.
        # Setting both `_meta.ui.resourceUri` (preferred per @modelcontextprotocol/
        # ext-apps SDK) and the legacy `_meta["ui/resourceUri"]` covers every
        # documented host shape.
        return CallToolResult(
            content=[TextContent(type="text", text=status)],
            structuredContent=graph,
            _meta={
                "ui": {"resourceUri": RESOURCE_URI},
                "ui/resourceUri": RESOURCE_URI,
            },
        )

    server.tool(
        name="render_mule_flow",
        title="Render Mule Flow",
        description=(
            "Render a Mule project's flow XML as an interactive React Flow "
            "canvas inline in the chat. Pass the absolute path to a Mule "
            "project directory; the tool reads src/main/mule/<name>.xml and "
            "returns a graph the canvas displays. Click a node in the canvas "
            "to see its XML attributes."
        ),
        annotations=ToolAnnotations(
            readOnlyHint=True,
            openWorldHint=False,
        ),
        meta=ui_meta,
    )(render_mule_flow)

    return server


def main() -> None:
    """Entry point referenced by pyproject.toml's [project.scripts].

    Runs the FastMCP server over stdio — the transport Claude Desktop uses
    for locally-installed MCP servers.
    """
    server = _build_server()
    server.run(transport="stdio")


if __name__ == "__main__":
    main()


__all__ = ["RESOURCE_URI", "RESOURCE_MIME_TYPE", "main", "_build_server", "__version__"]
