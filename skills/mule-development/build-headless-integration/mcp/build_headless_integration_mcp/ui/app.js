/* Mule Flow Canvas — app-specific logic.
 *
 * The host (Claude Desktop) loads this file inside a sandboxed iframe.
 * On a successful render_mule_flow tool call, the host sends the tool
 * result via a postMessage notification; we render the graph as a
 * vertical readable-ui chain inside a rounded container card.
 *
 * Visual port of mule-dx-mule-dev-vscode/src/views/xml-editor/app/readable-ui/
 * scoped to the v1 case (single linear flow, no branches expanded).
 *
 * Self-contained: this file does not depend on the omni-app shared
 * mcp_app_client.js — we inline a minimal subset of that client below
 * so the skill ships standalone.
 *
 * Dependencies expected on `window` (loaded via UMD in app.html):
 *   React, ReactDOM
 */

(() => {
  // Visible boot diagnostic. If any UMD failed to load, show what we have
  // and don't pretend everything is fine — silent-blank-canvas was the
  // failure mode that took the longest to diagnose during development.
  const _bootRoot = document.getElementById("root");
  const _bootError = (msg) => {
    if (_bootRoot) {
      _bootRoot.innerHTML =
        '<div style="padding:24px;font-family:-apple-system,sans-serif;color:#c53030;background:white;min-height:100vh">' +
        '<strong>Mule Flow Canvas — boot error</strong><br/><br/>' +
        '<code style="font-family:Menlo,monospace;font-size:12px;display:block;background:#f3f4f6;padding:8px;border-radius:4px">' + msg + '</code></div>';
    }
    console.error("[Mule Flow Canvas]", msg);
  };

  if (typeof window.React === "undefined") {
    return _bootError("React did not load (window.React undefined). Check CSP allows https://unpkg.com.");
  }
  if (typeof window.ReactDOM === "undefined") {
    return _bootError("ReactDOM did not load (window.ReactDOM undefined).");
  }

  // ---- Minimal MCP App postMessage client ---------------------------------
  //
  // Mirrors the shape of mulesoft-omni-app/server_py/mcp_apps/shared/
  // mcp_app_client.js, scoped to just what this app needs:
  //   - ui/initialize handshake on startup
  //   - listen for ui/notifications/tool-result and call onToolResult
  //
  // Everything else (callServerTool, sendMessage, updateModelContext) is
  // omitted because v1 is read-only.

  class McpApp {
    constructor({ name, version }) {
      this.appInfo = { name, version };
      this._nextId = 1;
      this._pending = new Map();
      this.onToolResult = null;
      this.hostContext = null;
      window.addEventListener("message", (event) => this._handleMessage(event));
    }

    connect() {
      return this._request("ui/initialize", {
        appInfo: this.appInfo,
        appCapabilities: {},
        protocolVersion: "2025-03-26",
      }).then((result) => {
        this.hostContext = result?.hostContext || null;
        this._notify("ui/notifications/initialized", {});
        this._setupAutoResize();
      });
    }

    /** Ask the host to switch display mode (inline | fullscreen | pip).
     *
     * Returns the host's actual chosen mode — hosts can refuse a request
     * (e.g. fullscreen is unavailable) and respond with the mode they
     * actually used. Caller should drive UI off the response, not the
     * requested mode.
     */
    requestDisplayMode(mode) {
      return this._request("ui/request-display-mode", { mode });
    }

    /** Ask the host to call a tool on the MCP server. Resolves with the
     * tool's CallToolResult (the host re-posts the same envelope it would
     * deliver via ui/notifications/tool-result, but with a matching id).
     *
     * Mirrors mulesoft-omni-app's mcp_app_client.callServerTool. Used by
     * the side panel's "Test Connection" button to invoke
     * `test_connection(project_dir, config_ref)`.
     */
    callServerTool(name, args = {}) {
      return this._request("tools/call", { name, arguments: args });
    }

    /** True when the host advertises support for the requested mode. */
    canUseDisplayMode(mode) {
      const modes = this.hostContext && this.hostContext.availableDisplayModes;
      return Array.isArray(modes) && modes.includes(mode);
    }

    _request(method, params) {
      const id = this._nextId++;
      return new Promise((resolve, reject) => {
        this._pending.set(id, { resolve, reject });
        this._post({ jsonrpc: "2.0", id, method, params });
      });
    }

    _notify(method, params) {
      this._post({ jsonrpc: "2.0", method, params });
    }

    _post(msg) {
      window.parent.postMessage(msg, window.location.origin);
    }

    _handleMessage(event) {
      const msg =
        typeof event.data === "string"
          ? safeJsonParse(event.data)
          : event.data;
      if (!msg || typeof msg !== "object") return;

      if (msg.id != null && this._pending.has(msg.id)) {
        const { resolve, reject } = this._pending.get(msg.id);
        this._pending.delete(msg.id);
        if (msg.error) {
          reject(new Error(msg.error.message || "host error"));
        } else {
          resolve(msg.result);
        }
        return;
      }

      if (msg.method === "ui/notifications/tool-result" && this.onToolResult) {
        this.onToolResult(msg.params);
      }
    }

    _setupAutoResize() {
      let lastW = 0;
      let lastH = 0;
      let scheduled = false;
      const send = () => {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(() => {
          scheduled = false;
          const w = Math.ceil(document.documentElement.scrollWidth);
          const h = Math.ceil(document.documentElement.scrollHeight);
          if (w !== lastW || h !== lastH) {
            lastW = w;
            lastH = h;
            this._notify("ui/notifications/size-changed", { width: w, height: h });
          }
        });
      };
      send();
      if (typeof ResizeObserver !== "undefined") {
        const ro = new ResizeObserver(send);
        ro.observe(document.documentElement);
        ro.observe(document.body);
      }
    }
  }

  function safeJsonParse(s) {
    try {
      return JSON.parse(s);
    } catch {
      return null;
    }
  }

  // ---- React components --------------------------------------------------

  const { useEffect, useState, useCallback } = window.React;
  const e = window.React.createElement;

  /** Inline SVG renderer — server enriches each node with raw SVG markup.
   * Wraps in a fixed-size container so the .icon's CSS-driven downscaling
   * stays predictable across icon shapes. */
  function NodeIcon({ svgMarkup, className }) {
    if (!svgMarkup) {
      return e("div", { className: className || "flow-node-icon" });
    }
    return e("div", {
      className: className || "flow-node-icon",
      dangerouslySetInnerHTML: { __html: svgMarkup },
    });
  }

  /** Visual port of readable-ui ReadableNode.tsx (v1 scope: no kebab,
   * no breakpoints, no decorators). The two-line label format
   * (type → docName) matches the screenshot. */
  function FlowNode({ node, selected, onSelect }) {
    const docName = (node.doc && node.doc.name) || "";
    const description = (node.doc && node.doc.description) || "";

    // Two display tiers matching readable-ui:
    //   nodeType row  — small grey label (the doc:name when present, else
    //                    the namespaced element name)
    //   customText row — the doc:description (when present)
    // Falls back to elementName + label when no doc:* attributes exist.
    const topLabel = docName || node.elementName;
    const bottomLabel = description || (docName ? null : node.label);

    return e(
      "div",
      {
        className:
          "readable readable-node" +
          (selected ? " selected" : "") +
          (bottomLabel ? " readable-has-description" : "") +
          (node.kind === "error-handler" ? " readable-error-tinted" : "") +
          (node.kind === "trigger" ? " readable-trigger" : ""),
        onClick: () => onSelect(node),
        tabIndex: 0,
        "data-testid": "readable-node-" + node.id,
      },
      e(
        "div",
        { className: "readableLeft" },
        e(NodeIcon, { svgMarkup: node.icon, className: "readableNodeIcon" }),
        e(
          "div",
          { className: "readableLabelCont" },
          topLabel
            ? e("div", { className: "nodeType", title: topLabel }, topLabel)
            : null,
          bottomLabel
            ? e(
                "div",
                { className: "customText", title: bottomLabel },
                bottomLabel,
              )
            : null,
        ),
      ),
    );
  }

  /** Vertical line between two consecutive nodes — replaces the `+` glyph
   * for the zoomed-out canvas read. Pure CSS rule (height + border) inside
   * a centered cell so it lines up with the icon column above it. */
  function LineConnector() {
    return e("div", {
      className: "readable-line-connector",
      "aria-hidden": "true",
    });
  }

  /** Header pill that crowns the flow container — visual port of
   * ReadableTopContainer's caption. Renders the flow's display name +
   * description, plus an inline-svg flow icon that mirrors the chevron
   * shape used in the vscode canvas. */
  function FlowHeaderCard({ flow, selected, onSelect }) {
    const docName = (flow.doc && flow.doc.name) || flow.name;
    const description = (flow.doc && flow.doc.description) || "";
    return e(
      "div",
      {
        className:
          "readable readable-container readable-flow-header" +
          (selected ? " selected" : ""),
        onClick: () => onSelect && onSelect({ id: "__flow_header__", flow }),
      },
      e(
        "div",
        { className: "readableLeft" },
        e(
          "div",
          { className: "readableNodeIcon flow-header-svg" },
          e(
            "svg",
            { width: 64, height: 64, viewBox: "0 0 64 64" },
            e("circle", { cx: 32, cy: 32, r: 29, fill: "#0176D3" }),
            e(
              "g",
              { className: "icon", fill: "#FFFFFF" },
              e("path", {
                d: "M22 22h20v4H22zM22 30h20v4H22zM22 38h14v4H22z",
                fill: "#FFFFFF",
              }),
            ),
          ),
        ),
        e(
          "div",
          { className: "readableLabelCont" },
          e("div", { className: "nodeType" }, docName),
          description
            ? e(
                "div",
                { className: "customText", title: description },
                description,
              )
            : null,
        ),
      ),
    );
  }

  // Default zoom — slightly under 1.0 so the chain reads as a "summary"
  // rather than a step-by-step inspector. Min/max bracket the useful range.
  const ZOOM_DEFAULT = 0.85;
  const ZOOM_MIN = 0.5;
  const ZOOM_MAX = 1.5;
  const ZOOM_STEP = 0.1;

  function FlowCanvas({
    flow,
    selectedId,
    onSelectNode,
    displayMode,
    onToggleFullscreen,
    fullscreenAvailable,
  }) {
    // readable-ui groups the chain into two visual sections: the main
    // processor chain and an error-handler block tucked below. The parser
    // already marks the error-handler with kind="error-handler" — we just
    // need to split the lists.
    const mainNodes = flow.nodes.filter((n) => n.kind !== "error-handler");
    const errorNodes = flow.nodes.filter((n) => n.kind === "error-handler");

    const [zoom, setZoom] = useState(ZOOM_DEFAULT);

    const clampZoom = (z) => Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, z));
    const zoomIn = useCallback(
      () => setZoom((z) => clampZoom(Math.round((z + ZOOM_STEP) * 100) / 100)),
      [],
    );
    const zoomOut = useCallback(
      () => setZoom((z) => clampZoom(Math.round((z - ZOOM_STEP) * 100) / 100)),
      [],
    );
    const zoomReset = useCallback(() => setZoom(ZOOM_DEFAULT), []);

    const flowHeaderMeta =
      flow.kind +
      " · " +
      flow.nodes.length +
      " node" +
      (flow.nodes.length === 1 ? "" : "s");

    return e(
      "div",
      { className: "canvas-pane" },
      e(
        "div",
        { className: "canvas-pane-toolbar" },
        e("div", { className: "canvas-pane-meta" }, flowHeaderMeta),
        fullscreenAvailable
          ? e(
              "button",
              {
                type: "button",
                className:
                  "canvas-pane-button" +
                  (displayMode === "fullscreen" ? " active" : ""),
                onClick: onToggleFullscreen,
                title:
                  displayMode === "fullscreen"
                    ? "Exit fullscreen"
                    : "Expand to fullscreen",
              },
              displayMode === "fullscreen" ? "Exit fullscreen" : "Fullscreen",
            )
          : null,
      ),
      e(
        "div",
        { className: "readable-flow-scroll" },
        // Zoom transform sits on a wrapper inside the scroll surface, so
        // scaling never resizes the scroll viewport itself — the user can
        // still scroll the un-scaled column when content overflows. The
        // transform-origin keeps the wrapper anchored at top-centre as it
        // shrinks/grows so the chain stays where it is.
        e(
          "div",
          {
            className: "readable-flow-zoom",
            style: { transform: "scale(" + zoom + ")" },
          },
          e(
            "div",
            { className: "readable-flow-container" },
            e(FlowHeaderCard, {
              flow,
              selected: selectedId === "__flow_header__",
              onSelect: onSelectNode,
            }),
            // Connect the flow-header card visually to the first processor
            // when one exists — same line shape that wires consecutive
            // processors below.
            mainNodes.length ? e(LineConnector, { key: "header:line" }) : null,
            // Main chain — each node followed by a vertical line except the
            // last. The line is the connector handle that visually wires
            // consecutive processors together (replaces the `+` insertion
            // glyph from the editor since this canvas is read-only).
            mainNodes.map((node, idx) =>
              e(
                window.React.Fragment,
                { key: node.id },
                e(FlowNode, {
                  node,
                  selected: node.id === selectedId,
                  onSelect: onSelectNode,
                }),
                idx < mainNodes.length - 1
                  ? e(LineConnector, { key: node.id + ":line" })
                  : null,
              ),
            ),
          ),
          errorNodes.length
            ? e(
                "div",
                { className: "readable-flow-container readable-flow-error" },
                e(
                  "div",
                  { className: "readable-error-header" },
                  e(
                    "svg",
                    {
                      width: 14,
                      height: 14,
                      viewBox: "0 0 14 14",
                      fill: "#EA001E",
                      "aria-hidden": "true",
                    },
                    e("circle", { cx: 7, cy: 7, r: 6, fill: "#FBE9E9" }),
                    e("path", {
                      d: "M7 3v4M7 9.5v.5",
                      stroke: "#EA001E",
                      strokeWidth: 1.5,
                      strokeLinecap: "round",
                    }),
                  ),
                  "Error handler",
                ),
                errorNodes.map((node) =>
                  e(FlowNode, {
                    key: node.id,
                    node,
                    selected: node.id === selectedId,
                    onSelect: onSelectNode,
                  }),
                ),
              )
            : null,
        ),
      ),
      // Zoom controls float bottom-left of the canvas pane, mirroring the
      // ACB canvas (and most diagram tools). They're absolute-positioned
      // over the scroll surface so they don't reflow with the chain.
      e(ZoomControls, {
        zoom,
        onZoomIn: zoomIn,
        onZoomOut: zoomOut,
        onReset: zoomReset,
      }),
    );
  }

  /** Fixed cluster of three buttons: zoom-out · reset · zoom-in.
   * Disabled state on the +/- buttons when at the bracket limits so users
   * get visual feedback that more clicks won't do anything. */
  function ZoomControls({ zoom, onZoomIn, onZoomOut, onReset }) {
    const atMin = zoom <= ZOOM_MIN + 1e-6;
    const atMax = zoom >= ZOOM_MAX - 1e-6;
    return e(
      "div",
      { className: "canvas-zoom-controls", "aria-label": "Zoom controls" },
      e(
        "button",
        {
          type: "button",
          className: "canvas-zoom-button",
          onClick: onZoomOut,
          disabled: atMin,
          title: "Zoom out",
          "aria-label": "Zoom out",
        },
        // Use HTML entity for em-dash via createElement is fine — kept
        // ASCII here so the bundled HTML stays mid-codepoint-clean.
        e("span", { "aria-hidden": "true" }, "−"),
      ),
      e(
        "button",
        {
          type: "button",
          className: "canvas-zoom-button canvas-zoom-reset",
          onClick: onReset,
          title: "Reset zoom (" + Math.round(ZOOM_DEFAULT * 100) + "%)",
          "aria-label": "Reset zoom",
        },
        Math.round(zoom * 100) + "%",
      ),
      e(
        "button",
        {
          type: "button",
          className: "canvas-zoom-button",
          onClick: onZoomIn,
          disabled: atMax,
          title: "Zoom in",
          "aria-label": "Zoom in",
        },
        e("span", { "aria-hidden": "true" }, "+"),
      ),
    );
  }

  // Field-name heuristics for the credential form. Names matching any
  // pattern in SECRET_KEYS render as <input type="password">; everything
  // else renders as <input type="text">.
  const SECRET_KEY_HINTS = [
    "password",
    "secret",
    "token",
    "key",
    "credential",
  ];

  function isSecretField(name) {
    const lower = name.toLowerCase();
    return SECRET_KEY_HINTS.some((h) => lower.includes(h));
  }

  function TestConnectionSection({ node, configs, projectDir, mcpApp }) {
    const configRef = node.attributes && node.attributes["config-ref"];
    const config = configRef && configs ? configs[configRef] : null;
    const [status, setStatus] = useState("idle"); // idle | running | success | error
    const [result, setResult] = useState(null);
    // Per-field credential overrides. Empty string ⇒ fall back to placeholder
    // resolution (config.yaml + env vars) on the server. Re-keyed when the
    // user clicks a different config-ref so values from one config don't
    // bleed into another.
    const [overrides, setOverrides] = useState({});
    const [showCredEditor, setShowCredEditor] = useState(false);

    // Reset state when the user clicks a different config so the form,
    // result, and overrides all follow the selection. Keying on configRef
    // (not node.id) keeps the form populated when clicking between two
    // different processors that share a config-ref.
    useEffect(() => {
      setStatus("idle");
      setResult(null);
      setOverrides({});
      setShowCredEditor(false);
    }, [configRef]);

    if (!configRef || !config) {
      return null;
    }

    // Build the field list off the parsed flow XML — these are the
    // attributes Mule will resolve when it spins the connection up.
    // Skip non-credential book-keeping attrs (`reconnection`, `config-ref`)
    // to match the server's filter; they aren't part of the wire body.
    const formFields = Object.entries(config.providerAttributes || {})
      .filter(([k]) => k !== "reconnection" && k !== "config-ref")
      .map(([k, v]) => ({
        name: k,
        placeholder: typeof v === "string" ? v : "",
        secret: isSecretField(k),
      }));

    const onClick = () => {
      if (!mcpApp || !projectDir) {
        setStatus("error");
        setResult({
          message:
            "Iframe is not connected to the host yet — wait for initial render to settle and try again.",
        });
        return;
      }
      setStatus("running");
      setResult(null);
      mcpApp
        .callServerTool("test_connection", {
          project_dir: projectDir,
          config_ref: configRef,
          overrides,
        })
        .then((res) => {
          // The host returns the full CallToolResult envelope — same shape
          // app.js already parses for ui/notifications/tool-result.
          const structured = res?.structuredContent;
          const text = (res?.content || [])
            .filter((c) => c.type === "text")
            .map((c) => c.text)
            .join("\n");
          if (structured) {
            setStatus(structured.success ? "success" : "error");
            setResult(structured);
          } else if (text) {
            const looksOk = text.includes("✅");
            setStatus(looksOk ? "success" : "error");
            setResult({ message: text });
          } else {
            setStatus("error");
            setResult({ message: "Tool returned no content." });
          }
        })
        .catch((err) => {
          setStatus("error");
          setResult({ message: err.message || String(err) });
        });
    };

    const onFieldChange = (name, value) => {
      // Empty strings stay in the map so the input remains controlled —
      // the server normalises whitespace-only/blank values to "no override".
      setOverrides((prev) => ({ ...prev, [name]: value }));
    };

    const onClearOverrides = () => {
      setOverrides({});
    };

    const buttonLabel =
      status === "running"
        ? "Testing…"
        : status === "success"
          ? "Test Connection"
          : status === "error"
            ? "Retry Test Connection"
            : "Test Connection";

    return e(
      "section",
      { className: "side-panel-section side-panel-test-section" },
      e("h3", { className: "side-panel-section-title" }, "Test Connection"),
      e(
        "div",
        { className: "test-connection-row" },
        e(
          "button",
          {
            type: "button",
            className:
              "test-connection-button" +
              (status === "running" ? " is-running" : "") +
              (status === "success" ? " is-success" : "") +
              (status === "error" ? " is-error" : ""),
            disabled: status === "running",
            onClick,
          },
          buttonLabel,
        ),
        e(
          "div",
          { className: "test-connection-meta" },
          e("span", null, "config: " + configRef),
          e(
            "span",
            null,
            "connector: " +
              (config.connector || "?") +
              " · provider: " +
              (config.providerName || "?"),
          ),
        ),
      ),
      // Credentials editor — collapsed by default. The default round-trip
      // uses the project's config.yaml; users only expand to override.
      formFields.length
        ? e(
            "div",
            { className: "test-credentials-block" },
            e(
              "button",
              {
                type: "button",
                className: "test-credentials-toggle",
                onClick: () => setShowCredEditor((v) => !v),
              },
              (showCredEditor ? "▾ " : "▸ ") +
                "Override credentials (" +
                formFields.length +
                " field" +
                (formFields.length === 1 ? "" : "s") +
                ")",
            ),
            showCredEditor
              ? e(
                  "div",
                  { className: "test-credentials-form" },
                  e(
                    "p",
                    { className: "test-credentials-hint" },
                    "Leave blank to use config.yaml + env vars. Typed values are sent only to RDS — never echoed in this panel or the chat.",
                  ),
                  formFields.map((f) =>
                    e(
                      "label",
                      { key: f.name, className: "test-credentials-field" },
                      e("span", { className: "test-credentials-label" }, f.name),
                      e("input", {
                        type: f.secret ? "password" : "text",
                        className: "test-credentials-input",
                        value: overrides[f.name] || "",
                        placeholder:
                          f.placeholder.includes("${")
                            ? f.placeholder
                            : "(default from config.yaml)",
                        autoComplete: "off",
                        spellCheck: false,
                        onChange: (ev) =>
                          onFieldChange(f.name, ev.target.value),
                      }),
                    ),
                  ),
                  Object.values(overrides).some((v) => v && v.trim())
                    ? e(
                        "button",
                        {
                          type: "button",
                          className: "test-credentials-clear",
                          onClick: onClearOverrides,
                        },
                        "Clear overrides",
                      )
                    : null,
                )
              : null,
          )
        : null,
      status !== "idle"
        ? e(
            "div",
            {
              className:
                "test-connection-result" +
                (status === "success"
                  ? " is-success"
                  : status === "error"
                    ? " is-error"
                    : ""),
            },
            status === "running"
              ? "Calling RDS at " +
                  (result?.rdsUrl || "MULE_DX_RDS_URL") +
                  "…"
              : (status === "success" ? "✅ " : "❌ ") +
                  (result?.message || "(no message)"),
            result?.fieldsSent && result.fieldsSent.length
              ? e(
                  "div",
                  { className: "test-connection-summary" },
                  e(
                    "span",
                    null,
                    "fields sent: " + result.fieldsSent.join(", "),
                  ),
                  result.fieldsOverridden && result.fieldsOverridden.length
                    ? e(
                        "span",
                        null,
                        "overridden: " + result.fieldsOverridden.join(", "),
                      )
                    : null,
                )
              : null,
          )
        : null,
    );
  }

  function SidePanel({ node, configs, projectDir, mcpApp, onClose }) {
    // The aside is always mounted so the width transition works in BOTH
    // directions: closed→open (a freshly mounted aside snaps to width 360px
    // with no animation otherwise) and open→closed. When `node` is null we
    // collapse the width to 0; the inner content stays unrendered so closed
    // panels don't hold focusable elements or hover targets.
    const isOpen = Boolean(node);

    if (!isOpen) {
      return e(
        "aside",
        {
          className: "side-panel",
          "aria-hidden": "true",
        },
      );
    }

    const attributeRows = Object.entries(node.attributes || {}).filter(
      ([, v]) => v !== null && v !== undefined && v !== "",
    );

    return e(
      "aside",
      { className: "side-panel is-open" },
      e(
        "header",
        { className: "side-panel-header" },
        e(
          "div",
          { className: "side-panel-header-content" },
          e("div", {
            className: "side-panel-icon",
            dangerouslySetInnerHTML: { __html: node.icon || "" },
          }),
          e(
            "div",
            { className: "side-panel-titles" },
            e("h2", { className: "side-panel-title" }, node.label),
            e("div", { className: "side-panel-element" }, node.elementName),
          ),
        ),
        e(
          "button",
          { className: "side-panel-close", onClick: onClose, "aria-label": "Close" },
          "×",
        ),
      ),
      e(
        "div",
        { className: "side-panel-body" },
        node.doc && node.doc.description
          ? e(
              "section",
              { className: "side-panel-section" },
              e("h3", { className: "side-panel-section-title" }, "Description"),
              e("p", { className: "side-panel-doc" }, node.doc.description),
            )
          : null,
        e(TestConnectionSection, {
          node,
          configs,
          projectDir,
          mcpApp,
        }),
        attributeRows.length
          ? e(
              "section",
              { className: "side-panel-section" },
              e("h3", { className: "side-panel-section-title" }, "Attributes"),
              e(
                "div",
                { className: "attr-list" },
                attributeRows.map(([k, v]) =>
                  e(
                    "div",
                    { key: k, className: "attr-row" },
                    e("span", { className: "attr-key" }, k),
                    e("span", { className: "attr-value" }, String(v)),
                  ),
                ),
              ),
            )
          : e(
              "section",
              { className: "side-panel-section" },
              e("h3", { className: "side-panel-section-title" }, "Attributes"),
              e("p", { className: "side-panel-doc" }, "(none)"),
            ),
        node.kind === "container" && node.branches
          ? e(
              "section",
              { className: "side-panel-section" },
              e("h3", { className: "side-panel-section-title" }, "Branches"),
              e(
                "p",
                { className: "side-panel-doc" },
                node.branches +
                  " branch" +
                  (node.branches === 1 ? "" : "es") +
                  " (collapsed; ask Claude in chat to inspect them)",
              ),
            )
          : null,
      ),
    );
  }

  function App() {
    const [graph, setGraph] = useState(null);
    const [selectedNode, setSelectedNode] = useState(null);
    const [activeFlowIdx, setActiveFlowIdx] = useState(0);
    const [error, setError] = useState(null);
    const [displayMode, setDisplayMode] = useState("inline");
    // McpApp instance is held in a ref so click handlers below can reach it
    // without retriggering useEffect (mounting twice would post a duplicate
    // ui/initialize handshake).
    const mcpAppRef = window.React.useRef(null);

    useEffect(() => {
      const app = new McpApp({
        name: "Mule Flow Canvas",
        version: "0.1.0",
      });
      mcpAppRef.current = app;
      app.onToolResult = (params) => {
        try {
          // Preferred path: server returns CallToolResult with structuredContent
          // carrying the graph object directly.
          const result = params?.result || params || {};
          let parsed = result.structuredContent;

          if (!parsed) {
            // Backward compat: if structuredContent is absent, fall back to
            // the first text content block being a JSON-encoded graph.
            const content = result.content || [];
            const textItem = content.find((c) => c.type === "text");
            if (textItem) {
              try {
                parsed = JSON.parse(textItem.text);
              } catch {
                // Not JSON — short status text from the new envelope shape;
                // ignore and let the UI keep waiting for structuredContent.
                return;
              }
            }
          }

          if (!parsed || !parsed.flows) return;
          setGraph(parsed);
          setSelectedNode(null);
          setActiveFlowIdx(0);
        } catch (err) {
          setError("Failed to parse tool result: " + err.message);
        }
      };
      app.connect()
        .then(() => {
          // After the handshake, hostContext.displayMode tells us where we
          // started. Capture it so the toggle's initial state matches.
          const initial = app.hostContext && app.hostContext.displayMode;
          if (initial) setDisplayMode(initial);
        })
        .catch((err) => {
          // Initialize failure isn't fatal — Claude Desktop still delivers
          // tool-result notifications. Log for debugging only.
          console.warn("MCP App connect() failed:", err);
        });
    }, []);

    const handleSelectNode = useCallback((node) => {
      setSelectedNode(node);
    }, []);

    const handleToggleFullscreen = useCallback(() => {
      const app = mcpAppRef.current;
      if (!app) return;
      const next = displayMode === "fullscreen" ? "inline" : "fullscreen";
      // Don't call if the host doesn't advertise the mode — saves a noisy
      // round-trip on hosts that only support inline.
      if (!app.canUseDisplayMode(next)) return;
      app.requestDisplayMode(next).then((res) => {
        if (res && res.mode) setDisplayMode(res.mode);
      }).catch((err) => {
        console.warn("requestDisplayMode failed:", err);
      });
    }, [displayMode]);

    const fullscreenAvailable =
      mcpAppRef.current &&
      (mcpAppRef.current.canUseDisplayMode("fullscreen") ||
        displayMode === "fullscreen");

    if (error) {
      return e("div", { className: "error" }, error);
    }
    if (!graph) {
      return e("div", { className: "loading" }, "Waiting for flow data…");
    }
    if (!graph.flows || graph.flows.length === 0) {
      return e(
        "div",
        { className: "loading" },
        "No flows found in this Mule project.",
      );
    }

    const flow = graph.flows[activeFlowIdx] || graph.flows[0];

    return e(
      "div",
      {
        className:
          "canvas-shell" +
          (displayMode === "fullscreen" ? " is-fullscreen" : ""),
      },
      // Multi-flow tabs (only when more than one flow exists; v1 typical
      // case is single-flow projects).
      graph.flows.length > 1
        ? e(
            "div",
            { className: "flow-tabs" },
            graph.flows.map((f, idx) =>
              e(
                "button",
                {
                  key: f.id,
                  className: "flow-tab" + (idx === activeFlowIdx ? " active" : ""),
                  onClick: () => {
                    setActiveFlowIdx(idx);
                    setSelectedNode(null);
                  },
                },
                f.name,
              ),
            ),
          )
        : null,
      e(FlowCanvas, {
        flow,
        selectedId: selectedNode?.id,
        onSelectNode: handleSelectNode,
        displayMode,
        onToggleFullscreen: handleToggleFullscreen,
        fullscreenAvailable,
      }),
      e(SidePanel, {
        node: selectedNode,
        configs: graph.configs || {},
        projectDir: (graph.source && graph.source.projectDir) || null,
        mcpApp: mcpAppRef.current,
        onClose: () => setSelectedNode(null),
      }),
    );
  }

  // Boot.
  try {
    const root = window.ReactDOM.createRoot(document.getElementById("root"));
    root.render(e(App));
  } catch (err) {
    _bootError("React root failed to mount: " + (err && err.message ? err.message : String(err)));
  }
})();
