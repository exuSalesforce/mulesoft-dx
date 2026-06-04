#!/usr/bin/env node
// Digest a Go-connector extension-model.json bundle (+ dsl.json) into a
// Claude-readable summary suitable for flow-XML generation.
//
// Usage: node digest_extension_model.mjs <bundle-dir>
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const bundleDir = process.argv[2];
if (!bundleDir) {
  console.error('Usage: digest_extension_model.mjs <bundle-dir>');
  process.exit(2);
}

const em = JSON.parse(readFileSync(join(bundleDir, 'extension-model.json'), 'utf8'));
const dsl = JSON.parse(readFileSync(join(bundleDir, 'dsl.json'), 'utf8'));

const typeOf = (t) => {
  if (!t) return 'unknown';
  if (t.format === 'java' && typeof t.type === 'string') return t.type;
  return t['@type'] ?? t.type ?? t.format ?? 'unknown';
};

// Pull enum values from the (Java-emitted) `type.annotations.enum.values` if present.
const enumValuesOf = (t) => {
  const v = t?.annotations?.enum?.values;
  return Array.isArray(v) ? v : null;
};

const paramSummary = (p) => ({
  name: p.name,
  display: p.displayModel?.displayName ?? p.name,
  description: p.description ?? '',
  required: !!p.required,
  type: typeOf(p.type),
  defaultValue: p.defaultValue ?? null,
  allowedValues: enumValuesOf(p.type),
  expressionSupport: p.expressionSupport ?? null,
});

const groupSummary = (g) => ({
  name: g.name,
  showInDsl: g.showInDsl !== false,
  parameters: (g.parameterModels || g.parameters || []).map(paramSummary),
});

// `errors` on operations / sources are nested {type, namespace, parent} structures;
// we want a flat "<NAMESPACE>:<TYPE>" list for <on-error-propagate type="..."> selection.
// Walk the parent chain too so the caller gets the full set this op can throw.
const flattenErrors = (errs = []) => {
  const out = new Set();
  const walk = (e) => {
    if (!e || typeof e !== 'object') return;
    if (e.type && e.namespace) out.add(`${e.namespace}:${e.type}`);
    if (e.parent) walk(e.parent);
  };
  errs.forEach(walk);
  return [...out].sort();
};

// `dsl.json` keys operations/configurations/connectionProviders by their element name —
// look up the authoritative XML element so Claude writes the correct tag.
// (Java connectors and Go connectors can differ here, e.g. `basic` vs `basic-connection`.)
const dslEntry = (kind, name) => {
  const root = dsl[kind] || {};
  return root[name] || null;
};

const elementOf = (kind, name) => {
  const e = dslEntry(kind, name);
  return e?.elementName ?? name;
};

const opSummary = (o, kind = 'operations') => ({
  name: o.name,
  element: elementOf(kind, o.name),
  display: o.displayModel?.displayName ?? o.name,
  description: o.description ?? '',
  requiresConnection: !!o.requiresConnection,
  parameterGroups: (o.parameterGroupModels || []).map(groupSummary),
  errorTypes: flattenErrors(o.errors),
});

const providerSummary = (p) => ({
  name: p.name,
  element: elementOf('connectionProviders', p.name),
  display: p.displayModel?.displayName ?? p.name,
  description: p.description ?? '',
  parameterGroups: (p.parameterGroupModels || []).map(groupSummary),
});

const configSummary = (c) => ({
  name: c.name,
  element: elementOf('configurations', c.name),
  description: c.description ?? '',
  connectionProviders: (c.connectionProviders || []).map(providerSummary),
  operations: (c.operationModels || []).map((o) => opSummary(o, 'operations')),
  sources: (c.sourceModels || []).map((s) => opSummary(s, 'sources')),
});

// Pull all DSL element names (`prefix:foo`) so Claude knows exactly what to write in XML.
const dslElementNames = (() => {
  const names = new Set();
  const walk = (node) => {
    if (Array.isArray(node)) return node.forEach(walk);
    if (!node || typeof node !== 'object') return;
    if (typeof node.elementName === 'string' && node.elementName !== '') names.add(node.elementName);
    for (const v of Object.values(node)) walk(v);
  };
  walk(dsl);
  return [...names].sort();
})();

const digest = {
  name: em.name,
  version: em.version,
  vendor: em.vendor,
  prefix: em.xmlDsl?.prefix,
  namespace: em.xmlDsl?.namespace,
  schemaLocation: em.xmlDsl?.schemaLocation,
  minMuleVersion: em.minMuleVersion,
  configurations: (em.configurations || []).map(configSummary),
  errorCount: (em.errors || []).length,
  dslElementNames,
};

process.stdout.write(JSON.stringify(digest, null, 2));
