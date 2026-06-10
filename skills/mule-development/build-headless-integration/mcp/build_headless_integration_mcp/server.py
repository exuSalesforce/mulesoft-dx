"""FastMCP server entry point.

Exposes one tool, `render_mule_flow`, that takes a Mule project directory,
parses the flow XML inside, and returns a UI resource Claude Desktop renders
inline as a React Flow canvas.

Mirrors the conventions in mulesoft-omni-app/server_py/mcp_apps/.
"""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

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


# ---- test-connection helpers --------------------------------------------------
#
# The canvas's "Test Connection" button calls a tool that resolves the config's
# ${...} placeholders against the project's config.yaml + the user's
# environment, then POSTs to RDS. Mirrors what ACB does at design time —
# hits the same /v1/test-connection endpoint via the same MULE_DX_RDS_URL.

# Mule's placeholder syntax inside attribute values: ${expr}, where `expr`
# can be a dotted property path (resolved against config.yaml) or a bare
# environment variable name. Captures the inner expression.
_PLACEHOLDER_RE = re.compile(r"\$\{([^}]+)\}")


def _load_config_yaml(project_dir: Path) -> dict[str, Any]:
    """Read src/main/resources/config.yaml as a dict.

    Returns an empty dict if the file is absent — flows can run with all
    values supplied via env vars only. lxml is already a dep; PyYAML isn't,
    so we parse with the stdlib's small YAML-subset reader. The skill's
    config.yaml uses `key: "value"` and nested mapping shapes — both fit
    the subset.
    """
    cfg_path = project_dir / "src" / "main" / "resources" / "config.yaml"
    if not cfg_path.is_file():
        return {}

    try:
        # PyYAML is widely available but optional; import lazily so a fresh
        # `pip install` of just FastMCP works for users who never test
        # connections from the canvas.
        import yaml  # type: ignore

        with cfg_path.open(encoding="utf-8") as f:
            data = yaml.safe_load(f)
        return data or {}
    except ImportError:
        return _yaml_fallback(cfg_path)


def _yaml_fallback(path: Path) -> dict[str, Any]:
    """Minimal YAML parser for the skill's config.yaml shape only.

    Handles the indented `key: "value"` / nested mapping form that
    `create_versionless_project.sh` writes. Not a general YAML parser —
    arrays, anchors, multi-line strings are out of scope. PyYAML is the
    preferred path; this fallback exists so the tool doesn't error out
    on a system without it.
    """
    root: dict[str, Any] = {}
    stack: list[tuple[int, dict[str, Any]]] = [(0, root)]

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        content = line.strip()
        if ":" not in content:
            continue
        key, _, value = content.partition(":")
        key = key.strip()
        value = value.strip()

        while stack and indent < stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]

        if not value:
            child: dict[str, Any] = {}
            parent[key] = child
            stack.append((indent + 2, child))
        else:
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            elif value.startswith("'") and value.endswith("'"):
                value = value[1:-1]
            parent[key] = value

    return root


def _resolve_dotted(data: dict[str, Any], dotted: str) -> str | None:
    """Walk `data` along a dot-separated key path. Returns None if missing."""
    cur: Any = data
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    if isinstance(cur, str):
        return cur
    if cur is None:
        return None
    return str(cur)


def _resolve_placeholders(value: str, cfg: dict[str, Any]) -> tuple[str, list[str]]:
    """Replace ${...} occurrences in `value`. Returns (resolved, missing-keys).

    Resolution order per placeholder:
      1. `cfg` (config.yaml) — dotted lookup mirroring how Mule's
         configuration-properties resolves ${twilio.from-number}.
      2. The current process environment (each value cascaded through
         config.yaml first; if config.yaml itself contains `${ENV_VAR}`,
         that's also resolved against `os.environ`).
    """
    missing: list[str] = []

    def resolve_one(key: str) -> str:
        v = _resolve_dotted(cfg, key)
        if v is not None:
            # Recurse: config.yaml values may themselves carry ${...} (env refs).
            inner, inner_missing = _resolve_placeholders(v, cfg)
            missing.extend(inner_missing)
            return inner
        env = os.environ.get(key)
        if env is not None:
            return env
        # Try uppercased / underscore-converted env var: twilio.from-number
        # → TWILIO_FROM_NUMBER. Mirrors how the skill's create script
        # generates default placeholders.
        env_alt = os.environ.get(key.replace(".", "_").replace("-", "_").upper())
        if env_alt is not None:
            return env_alt
        missing.append(key)
        return ""

    resolved = _PLACEHOLDER_RE.sub(lambda m: resolve_one(m.group(1)), value)
    return resolved, missing


def _post_rds_test_connection(
    base_url: str,
    *,
    connector: str,
    provider_name: str,
    config_fields: dict[str, str],
    timeout_s: float = 30.0,
) -> dict[str, Any]:
    """POST /v1/test-connection. Returns the JSON body or an error envelope."""
    url = base_url.rstrip("/") + "/v1/test-connection"
    body = json.dumps(
        {
            "connector": connector,
            "providerName": provider_name,
            "config": config_fields,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:  # noqa: S310
            raw = resp.read()
            try:
                return json.loads(raw.decode("utf-8"))
            except json.JSONDecodeError:
                return {
                    "success": False,
                    "message": (
                        f"RDS returned non-JSON response (HTTP {resp.status}): "
                        + raw.decode("utf-8", errors="replace")[:200]
                    ),
                }
    except urllib.error.HTTPError as e:
        # 4xx/5xx with a body — surface what RDS actually said.
        try:
            err_body = e.read().decode("utf-8", errors="replace")
            return {"success": False, "message": f"HTTP {e.code}: {err_body[:200]}"}
        except Exception:
            return {"success": False, "message": f"HTTP {e.code}: {e.reason}"}
    except urllib.error.URLError as e:
        return {"success": False, "message": f"Cannot reach RDS at {url}: {e.reason}"}


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

    async def test_connection(
        project_dir: str,
        config_ref: str,
        overrides: dict[str, str] | None = None,
        rds_url: str | None = None,
    ) -> CallToolResult:
        """Test a named config's connection by calling RDS /v1/test-connection.

        Args:
            project_dir: Absolute path to the Mule project. The tool re-parses
                the flow XML to look up the config by name and reads the
                project's config.yaml to resolve ${...} placeholders.
            config_ref: The `name` attribute of the connector config to test
                (e.g. `Salesforce_Config`). Matches the `config-ref` value on
                processor nodes.
            overrides: Optional per-field credential overrides typed in the
                canvas's side panel. Each non-empty value replaces the
                config.yaml/env-resolved value for that field. Empty/missing
                keys fall back to placeholder resolution. Values are sent
                straight to RDS and never echoed back to the iframe.
            rds_url: Optional override. Defaults to MULE_DX_RDS_URL or
                http://localhost:8090 — the same env the ACB plugin reads.

        Returns:
            CallToolResult with structuredContent shaped as
            `{success, message, configRef, connector, providerName,
              rdsUrl, fieldsSent, fieldsOverridden}`. The iframe reads
            structuredContent to update the side panel; the LLM in the
            chat gets the same data via the text content block.

            **No credential values appear in the response** — only field
            *names*. This avoids leaking secrets into the chat transcript
            (which screenshots, logs, and the model context all see).
        """
        project = Path(project_dir).expanduser().resolve()
        if not project.is_dir():
            msg = f"project_dir is not a directory: {project_dir}"
            raise NotADirectoryError(msg)

        xml_path = _resolve_flow_xml(str(project))
        graph = parse_flow_xml(xml_path)

        configs = graph.get("configs") or {}
        config_entry = configs.get(config_ref)
        if config_entry is None:
            available = ", ".join(sorted(configs.keys())) or "(none)"
            return _test_connection_result(
                success=False,
                message=(
                    f"No config named '{config_ref}' in {xml_path.name}. "
                    f"Available configs: {available}."
                ),
                config_ref=config_ref,
                rds_url=rds_url or "",
                connector="",
                provider_name="",
                fields_sent=[],
                fields_overridden=[],
            )

        connector = config_entry.get("connector") or ""
        provider_name = config_entry.get("providerName") or ""
        provider_attrs = dict(config_entry.get("providerAttributes") or {})

        # Normalise overrides: drop empty / whitespace-only values so the
        # iframe can pre-fill the form without forcing the user to clear
        # untouched fields back to placeholder resolution.
        clean_overrides: dict[str, str] = {}
        if overrides:
            for k, v in overrides.items():
                if isinstance(v, str) and v.strip():
                    clean_overrides[k] = v

        # Read config.yaml once and resolve every provider attribute.
        cfg = _load_config_yaml(project)

        resolved_fields: dict[str, str] = {}
        missing_for_unoverridden: list[str] = []
        # Non-credential attributes Mule injects/uses internally — not part
        # of the test-connection request body.
        _skip_attrs = {"reconnection", "config-ref"}
        for key, val in provider_attrs.items():
            if key in _skip_attrs:
                continue
            if key in clean_overrides:
                # User-typed override wins. Values pass through verbatim.
                resolved_fields[key] = clean_overrides[key]
                continue
            if isinstance(val, str):
                resolved, missing = _resolve_placeholders(val, cfg)
                resolved_fields[key] = resolved
                missing_for_unoverridden.extend(missing)
            else:
                resolved_fields[key] = str(val)

        # Allow overrides to introduce fields the XML doesn't declare —
        # uncommon, but lets a user test e.g. `securityToken` without
        # touching the project files. Skip empty values defensively.
        for k, v in clean_overrides.items():
            if k not in resolved_fields:
                resolved_fields[k] = v

        fields_sent = sorted(resolved_fields.keys())
        fields_overridden = sorted(clean_overrides.keys())

        if missing_for_unoverridden:
            return _test_connection_result(
                success=False,
                message=(
                    "Cannot resolve config placeholders: missing "
                    + ", ".join(sorted(set(missing_for_unoverridden)))
                    + ". Set them in config.yaml, as environment variables, "
                    + "or type values into the side panel form."
                ),
                config_ref=config_ref,
                rds_url=rds_url or os.environ.get(
                    "MULE_DX_RDS_URL", "http://localhost:8090"
                ),
                connector=connector,
                provider_name=provider_name,
                fields_sent=fields_sent,
                fields_overridden=fields_overridden,
            )

        base_url = (
            rds_url
            or os.environ.get("MULE_DX_RDS_URL")
            or "http://localhost:8090"
        )
        rds_response = _post_rds_test_connection(
            base_url,
            connector=connector,
            provider_name=provider_name,
            config_fields=resolved_fields,
        )

        return _test_connection_result(
            success=bool(rds_response.get("success")),
            message=str(rds_response.get("message") or "(no message)"),
            config_ref=config_ref,
            rds_url=base_url,
            connector=connector,
            provider_name=provider_name,
            fields_sent=fields_sent,
            fields_overridden=fields_overridden,
        )

    server.tool(
        name="test_connection",
        title="Test Connection",
        description=(
            "Test a connector config's credentials against the Remote Design "
            "Service (RDS). Resolves the config's ${...} placeholders against "
            "config.yaml + env vars, then POSTs to "
            "MULE_DX_RDS_URL/v1/test-connection. The same path ACB uses when "
            "you click 'Test Connection' on a config in the canvas."
        ),
        annotations=ToolAnnotations(
            readOnlyHint=True,
            destructiveHint=False,
            openWorldHint=True,
        ),
    )(test_connection)

    return server


def _test_connection_result(
    *,
    success: bool,
    message: str,
    config_ref: str,
    rds_url: str,
    connector: str,
    provider_name: str,
    fields_sent: list[str],
    fields_overridden: list[str],
) -> CallToolResult:
    """Pack the test-connection outcome into a CallToolResult.

    The text content block carries a one-line summary the chat LLM reads;
    structuredContent holds the full record the iframe consumes to update
    the side panel.

    No credential values are included anywhere — only field NAMES. This
    keeps secrets from leaking into the chat transcript via the model
    context, screenshots, or logs.
    """
    summary = (
        f"{'✅' if success else '❌'} Test Connection [{config_ref}]: {message}"
    )
    return CallToolResult(
        content=[TextContent(type="text", text=summary)],
        structuredContent={
            "success": success,
            "message": message,
            "configRef": config_ref,
            "connector": connector,
            "providerName": provider_name,
            "rdsUrl": rds_url,
            "fieldsSent": fields_sent,
            "fieldsOverridden": fields_overridden,
        },
    )


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
