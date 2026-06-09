/* Mule Flow Canvas — app-specific logic.
 *
 * The host (Claude Desktop) loads this file inside a sandboxed iframe.
 * On a successful render_mule_flow tool call, the host sends the tool
 * result via a postMessage notification; we extract the JSON graph from
 * the text content block and feed it into ReactFlow + dagre.
 *
 * Self-contained: this file does not depend on the omni-app shared
 * mcp_app_client.js — we inline a minimal subset of that client below
 * so the skill ships standalone.
 *
 * Dependencies expected on `window` (loaded via UMD in app.html):
 *   React, ReactDOM, ReactFlow, dagre
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
  if (typeof window.ReactFlow === "undefined") {
    return _bootError("ReactFlow did not load (window.ReactFlow undefined). Check the CDN URL in app.html.");
  }
  if (typeof window.dagre === "undefined") {
    return _bootError("dagre did not load (window.dagre undefined).");
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

  // ---- Layout ------------------------------------------------------------
  //
  // Vertical top-to-bottom layout via dagre. ReactFlow doesn't ship a
  // layout engine; dagre is the canonical choice (matches what the
  // 2026-05-18 design spec calls out for the omni-app canvas page).

  // Sized to match the .flow-node CSS (240×60 + a bit of breathing room) so
  // React Flow's hit-testing and dagre's layout stay in sync with what's
  // actually rendered. RANK_SEP echoes readable-ui's --readable-layout-gap (16px)
  // padded with edge-routing room.
  const NODE_WIDTH = 240;
  const NODE_HEIGHT = 60;
  const RANK_SEP = 48;
  const NODE_SEP = 32;

  function layoutGraph(nodes, edges) {
    const dagre = window.dagre;
    if (!dagre) {
      // Fall back to a stacked layout if dagre failed to load.
      return nodes.map((n, i) => ({
        ...n,
        position: { x: 0, y: i * (NODE_HEIGHT + RANK_SEP) },
      }));
    }
    const g = new dagre.graphlib.Graph();
    g.setGraph({ rankdir: "TB", ranksep: RANK_SEP, nodesep: NODE_SEP });
    g.setDefaultEdgeLabel(() => ({}));

    for (const n of nodes) g.setNode(n.id, { width: NODE_WIDTH, height: NODE_HEIGHT });
    for (const e of edges) g.setEdge(e.source, e.target);

    dagre.layout(g);

    return nodes.map((n) => {
      const pos = g.node(n.id);
      return {
        ...n,
        position: { x: pos.x - NODE_WIDTH / 2, y: pos.y - NODE_HEIGHT / 2 },
      };
    });
  }

  // ---- React components --------------------------------------------------

  const { useEffect, useMemo, useState, useCallback } = window.React;
  const e = window.React.createElement;
  // window.ReactFlow is set by the reactflow@11 UMD bundle in app.html.
  // Boot guards above already verified its presence — this is just a local alias.
  const RF = window.ReactFlow;

  const { ReactFlow, Background, Controls } = RF;

  /** Inline SVG renderer — server enriches each node with raw SVG markup. */
  function NodeIcon({ svgMarkup }) {
    if (!svgMarkup) {
      return e("div", { className: "flow-node-icon" });
    }
    return e("div", {
      className: "flow-node-icon",
      dangerouslySetInnerHTML: { __html: svgMarkup },
    });
  }

  /** Card per Mule processor. Visual port of readable-ui ReadableNode. */
  function FlowNode({ data, selected }) {
    const { node, onSelect } = data;
    return e(
      "div",
      {
        className: "flow-node" + (selected ? " selected" : ""),
        onClick: () => onSelect(node),
      },
      e(NodeIcon, { svgMarkup: node.icon }),
      e(
        "div",
        { className: "flow-node-body" },
        e("div", { className: "flow-node-type" }, node.elementName),
        e("div", { className: "flow-node-label" }, node.label),
      ),
      // Handles drive React Flow edge routing. isConnectable=false because
      // the canvas is read-only in v1.
      e(RF.Handle, {
        type: "target",
        position: RF.Position.Top,
        isConnectable: false,
      }),
      e(RF.Handle, {
        type: "source",
        position: RF.Position.Bottom,
        isConnectable: false,
      }),
    );
  }

  const nodeTypes = { flowNode: FlowNode };

  function FlowCanvas({ flow, selectedId, onSelectNode, displayMode, onToggleFullscreen, fullscreenAvailable }) {
    const laidOut = useMemo(() => {
      return layoutGraph(flow.nodes, flow.edges);
    }, [flow]);

    const rfNodes = useMemo(
      () =>
        laidOut.map((n) => ({
          id: n.id,
          type: "flowNode",
          position: n.position,
          data: { node: n, onSelect: onSelectNode },
          selected: n.id === selectedId,
        })),
      [laidOut, selectedId, onSelectNode],
    );

    const rfEdges = useMemo(
      () =>
        flow.edges.map((edge) => ({
          id: edge.id,
          source: edge.source,
          target: edge.target,
          type: "smoothstep",
        })),
      [flow.edges],
    );

    const flowHeaderName = (flow.doc && flow.doc.name) || flow.name;
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
        { className: "flow-header-card" },
        e(
          "div",
          { className: "flow-header-icon" },
          // Inline SVG: a stylised flow chevron mirroring vscode's flow.svg
          // without bundling another file. Matches the mule-blue palette.
          e("svg", {
            width: 24,
            height: 24,
            viewBox: "0 0 24 24",
            fill: "none",
            dangerouslySetInnerHTML: {
              __html:
                '<rect x="3" y="3" width="18" height="18" rx="6" fill="#0176D3" opacity="0.12"/>' +
                '<path d="M8 7l5 5-5 5M11 7l5 5-5 5" stroke="#0176D3" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" fill="none"/>',
            },
          }),
        ),
        e(
          "div",
          { className: "flow-header-text" },
          e("div", { className: "flow-header-name" }, flowHeaderName),
          e("div", { className: "flow-header-meta" }, flowHeaderMeta),
        ),
        fullscreenAvailable
          ? e(
              "div",
              { className: "flow-header-actions" },
              e(
                "button",
                {
                  type: "button",
                  className:
                    "flow-header-button" +
                    (displayMode === "fullscreen" ? " active" : ""),
                  onClick: onToggleFullscreen,
                  title:
                    displayMode === "fullscreen"
                      ? "Exit fullscreen"
                      : "Expand to fullscreen",
                },
                displayMode === "fullscreen" ? "Exit fullscreen" : "Fullscreen",
              ),
            )
          : null,
      ),
      e(
        ReactFlow,
        {
          nodes: rfNodes,
          edges: rfEdges,
          nodeTypes,
          fitView: true,
          // Generous top padding leaves room for the floating flow-header card.
          fitViewOptions: { padding: 0.25, minZoom: 0.5, maxZoom: 1.2 },
          nodesDraggable: false,
          nodesConnectable: false,
          elementsSelectable: true,
          panOnDrag: true,
          zoomOnScroll: true,
          proOptions: { hideAttribution: true },
        },
        e(Background, { color: "#e5e7eb", gap: 16 }),
        e(Controls, { showInteractive: false }),
      ),
    );
  }

  function SidePanel({ node, onClose }) {
    if (!node) {
      return e(
        "aside",
        { className: "side-panel" },
        e(
          "div",
          { className: "side-panel-empty" },
          "Click a node to inspect its attributes.",
        ),
      );
    }

    const attributeRows = Object.entries(node.attributes || {}).filter(
      ([, v]) => v !== null && v !== undefined && v !== "",
    );

    return e(
      "aside",
      { className: "side-panel" },
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
      { className: "canvas-shell" },
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
      e(SidePanel, { node: selectedNode, onClose: () => setSelectedNode(null) }),
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
