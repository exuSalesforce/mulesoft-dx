#!/usr/bin/env node
// Render a Mule flow XML file to an SVG diagram (and optionally PNG).
//
// Usage:
//   node visualize.mjs <flow.xml>                      # SVG to stdout
//   node visualize.mjs <flow.xml> --png <out.png>      # also writes PNG
//   node visualize.mjs <flow.xml> --ascii              # ASCII tree to stdout instead
//
// Layout: one row per <flow>/<sub-flow>; left-to-right boxes for each direct child
// element, labelled `prefix:localName`. The first child is the source/trigger,
// the rest are processors. Connections drawn as horizontal arrows.
//
// PNG rasterization uses @resvg/resvg-js if present; falls back to "svg only"
// with a warning if the optional dep isn't installed.
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const argv = process.argv.slice(2);
const flowXmlPath = argv[0];
if (!flowXmlPath) {
  console.error('Usage: visualize.mjs <flow.xml> [--png <out.png>] [--ascii]');
  process.exit(2);
}
const wantAscii = argv.includes('--ascii');
const pngIdx = argv.indexOf('--png');
const pngPath = pngIdx >= 0 ? argv[pngIdx + 1] : null;

const xml = readFileSync(resolve(flowXmlPath), 'utf8');

// Tiny XML parse: we only need element names + nesting under <flow>/<sub-flow>.
// Avoid pulling fast-xml-parser as a runtime dep — a minimal regex+stack walk is enough.
function tokenise(src) {
  // Element names allow `:` (XML namespace prefixes like `salesforce:create`).
  // Attribute names allow `:` too (`xmlns:salesforce`, `xsi:schemaLocation`).
  // Attribute values may span lines (xsi:schemaLocation often does).
  const re = /<\?[^?]*\?>|<!--[\s\S]*?-->|<(\/?)([A-Za-z_][\w.\-:]*)((?:\s+[A-Za-z_:][\w.\-:]*\s*=\s*"[^"]*")*)\s*(\/?)>|([^<]+)/g;
  const tokens = [];
  let m;
  while ((m = re.exec(src))) {
    if (m[0].startsWith('<?') || m[0].startsWith('<!--')) continue;
    if (m[5] !== undefined) {
      if (m[5].trim()) tokens.push({ kind: 'text', text: m[5] });
      continue;
    }
    const closing = m[1] === '/';
    const selfClose = m[4] === '/';
    if (closing) {
      tokens.push({ kind: 'close', name: m[2] });
    } else {
      tokens.push({ kind: 'open', name: m[2], selfClose });
      if (selfClose) tokens.push({ kind: 'close', name: m[2] });
    }
  }
  return tokens;
}

function buildTree(tokens) {
  const root = { name: 'root', children: [] };
  const stack = [root];
  for (const t of tokens) {
    if (t.kind === 'open') {
      // Always push: tokenise() emits a paired close for self-closing elements,
      // so the stack stays balanced without a per-token short-circuit here.
      const node = { name: t.name, children: [] };
      stack[stack.length - 1].children.push(node);
      stack.push(node);
    } else if (t.kind === 'close') {
      if (stack.length > 1) stack.pop();
    }
  }
  return root;
}

function findFlows(node, out = []) {
  if (node.name === 'flow' || node.name === 'sub-flow') {
    out.push(node);
    return out;
  }
  for (const c of node.children) findFlows(c, out);
  return out;
}

function isProcessable(name) {
  // Skip XML noise; everything else (including unknown prefixes) is a real node.
  return name && name !== 'doc:name' && !name.startsWith('xmlns');
}

function shortLabel(name) {
  return name.length > 22 ? name.slice(0, 21) + '…' : name;
}

const tokens = tokenise(xml);
const root = buildTree(tokens);
const flows = findFlows(root);

if (flows.length === 0) {
  console.error('no <flow> or <sub-flow> elements found in', flowXmlPath);
  process.exit(1);
}

if (wantAscii) {
  for (const f of flows) {
    const kids = f.children.filter((c) => isProcessable(c.name));
    process.stdout.write(`\n${f.name}\n`);
    kids.forEach((c, i) => {
      const prefix = i === kids.length - 1 ? '  └─' : '  ├─';
      process.stdout.write(`${prefix} ${c.name}\n`);
    });
  }
  process.exit(0);
}

// SVG layout.
const BOX_W = 160;
const BOX_H = 56;
const GAP_X = 36;
const GAP_Y = 28;
const PAD = 24;
const FONT = 'system-ui, -apple-system, "Segoe UI", sans-serif';

const rows = flows.map((f) => f.children.filter((c) => isProcessable(c.name)));
const maxCols = Math.max(...rows.map((r) => r.length || 1));
const width = PAD * 2 + maxCols * BOX_W + (maxCols - 1) * GAP_X + 100;
const height = PAD * 2 + flows.length * (BOX_H + GAP_Y) - GAP_Y + 24;

const parts = [
  `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`,
  `<style>
    .flow-label { font: 600 13px ${FONT}; fill: #1f2937; }
    .box { fill: #fff; stroke: #2563eb; stroke-width: 1.5; rx: 6; ry: 6; }
    .box.source { fill: #dbeafe; stroke: #1d4ed8; }
    .label { font: 500 12px ${FONT}; fill: #1f2937; text-anchor: middle; }
    .arrow { stroke: #6b7280; stroke-width: 1.5; fill: none; marker-end: url(#a); }
  </style>`,
  `<defs><marker id="a" markerWidth="9" markerHeight="9" refX="8" refY="4" orient="auto">
     <path d="M0,0 L8,4 L0,8 z" fill="#6b7280"/></marker></defs>`,
];

flows.forEach((f, ri) => {
  const y = PAD + ri * (BOX_H + GAP_Y);
  parts.push(`<text class="flow-label" x="${PAD}" y="${y - 6}">${escapeXml(f.name)}</text>`);
  const kids = rows[ri];
  if (kids.length === 0) {
    parts.push(`<text class="label" x="${PAD + 80}" y="${y + BOX_H / 2 + 4}">(empty flow)</text>`);
    return;
  }
  let prevCx = 0;
  let prevCy = 0;
  kids.forEach((c, ci) => {
    const x = PAD + ci * (BOX_W + GAP_X);
    const cls = ci === 0 ? 'box source' : 'box';
    parts.push(`<rect class="${cls}" x="${x}" y="${y}" width="${BOX_W}" height="${BOX_H}"/>`);
    const cx = x + BOX_W / 2;
    const cy = y + BOX_H / 2;
    parts.push(`<text class="label" x="${cx}" y="${cy + 4}">${escapeXml(shortLabel(c.name))}</text>`);
    if (ci > 0) {
      // Arrow runs from the prior box's right edge to this box's left edge.
      const fromX = prevCx + BOX_W;
      parts.push(`<path class="arrow" d="M${fromX},${prevCy} L${x - 2},${cy}"/>`);
    }
    prevCx = x;
    prevCy = cy;
  });
});

parts.push('</svg>');
const svg = parts.join('\n');

if (pngPath) {
  let resvg;
  try {
    ({ Resvg: resvg } = await import('@resvg/resvg-js'));
  } catch {
    console.error('warning: @resvg/resvg-js not installed; writing SVG only (no PNG)');
    writeFileSync(pngPath.replace(/\.png$/, '.svg'), svg);
    process.stdout.write(svg);
    process.exit(0);
  }
  const png = new resvg(svg).render().asPng();
  writeFileSync(pngPath, png);
}

process.stdout.write(svg);

function escapeXml(s) {
  return String(s).replace(/[<>&"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]));
}
