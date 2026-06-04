#!/usr/bin/env node
// Validate a generated Mule flow XML against the connector digests cached in
// tmp/connector-metadata/. Catches the failure modes that the build-mule-integration
// skill's validate_before_build.sh used to catch at mvn time — but cheaper, since
// we don't run mvn here.
//
// Checks performed:
//   1. Every xmlns:<prefix> declared in <mule> is paired with a schemaLocation entry.
//   2. Every <prefix:elementName> used appears in the digest's dslElementNames OR
//      is one of the well-known core/ee/http/doc elements.
//   3. Every <on-error-propagate type="..."> uses a type listed in some digest's
//      flat errorTypes union (or starts with MULE: which is always available).
//   4. Every config-ref="..." references a top-level config element by name.
//   5. Every ${dotted.key} placeholder has a matching entry in config.yaml.
//
// Exits 0 on success; non-zero on first violation found, with a clear message.
//
// Usage: node validate_flow.mjs <projectDir>
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, basename } from 'node:path';

const projectDir = process.argv[2];
if (!projectDir) {
  console.error('Usage: validate_flow.mjs <projectDir>');
  process.exit(2);
}

// ---- inputs -------------------------------------------------------------

const flowDir = join(projectDir, 'src', 'main', 'mule');
if (!existsSync(flowDir)) {
  console.error(`no flow dir at ${flowDir}`);
  process.exit(1);
}
const flowFiles = readdirSync(flowDir).filter((f) => f.endsWith('.xml')).map((f) => join(flowDir, f));
if (flowFiles.length === 0) {
  console.error(`no flow XML found under ${flowDir}`);
  process.exit(1);
}

const configYamlPath = join(projectDir, 'src', 'main', 'resources', 'config.yaml');
const configYaml = existsSync(configYamlPath) ? readFileSync(configYamlPath, 'utf8') : '';

// Collect every connector digest under <projectDir>/../tmp/connector-metadata/<nick>-digest.json
// (WS_DIR/tmp is the sibling, not the project's child).
const wsDir = join(projectDir, '..');
const metaDir = join(wsDir, 'tmp', 'connector-metadata');
const digests = [];
if (existsSync(metaDir)) {
  for (const f of readdirSync(metaDir)) {
    if (f.endsWith('-digest.json')) {
      const path = join(metaDir, f);
      try {
        digests.push({ path, ...JSON.parse(readFileSync(path, 'utf8')) });
      } catch {
        /* skip unreadable */
      }
    }
  }
}

// ---- collect facts from digests ----------------------------------------

// prefix -> { namespace, schemaLocation, elementNames: Set, errorTypes: Set }
const byPrefix = new Map();
for (const d of digests) {
  const p = d.prefix;
  if (!p) continue;
  let bucket = byPrefix.get(p);
  if (!bucket) {
    bucket = {
      namespace: d.namespace,
      schemaLocation: d.schemaLocation,
      elementNames: new Set(d.dslElementNames || []),
      errorTypes: new Set(),
    };
    byPrefix.set(p, bucket);
  }
  for (const cfg of d.configurations || []) {
    if (cfg.element) bucket.elementNames.add(cfg.element);
    for (const op of [...(cfg.operations || []), ...(cfg.sources || [])]) {
      if (op.element) bucket.elementNames.add(op.element);
      for (const e of op.errorTypes || []) bucket.errorTypes.add(e);
    }
    for (const prov of cfg.connectionProviders || []) {
      if (prov.element) bucket.elementNames.add(prov.element);
    }
  }
}

// Well-known core/ee/http/doc element names (not exhaustive; just the common ones the
// reference flows use). Anything else under these prefixes is allowed to pass — we don't
// have a catalog for them.
const coreElements = new Set([
  'mule',
  'flow',
  'sub-flow',
  'configuration-properties',
  'scheduler',
  'scheduling-strategy',
  'fixed-frequency',
  'cron',
  'set-variable',
  'set-payload',
  'logger',
  'choice',
  'when',
  'otherwise',
  'foreach',
  'try',
  'error-handler',
  'on-error-propagate',
  'on-error-continue',
  'parse-template',
  'flow-ref',
  'until-successful',
  'async',
  'first-successful',
  'scatter-gather',
  'route',
  'global-property',
]);

// Allow any element under these well-known prefixes (we don't ship digests for them).
const trustedPrefixes = new Set(['http', 'ee', 'doc', 'tls', 'oauth', 'reconnection', 'munit']);

// ---- parse the flow XML -------------------------------------------------

let allErrors = [];

const collectXmlnsDecls = (rootTag) => {
  const map = new Map(); // prefix -> namespace
  const re = /xmlns(?::([\w.-]+))?\s*=\s*"([^"]+)"/g;
  let m;
  while ((m = re.exec(rootTag))) {
    map.set(m[1] || '', m[2]); // empty string = default namespace
  }
  return map;
};

const collectSchemaLocationPairs = (rootTag) => {
  const m = rootTag.match(/xsi:schemaLocation\s*=\s*"([\s\S]*?)"/);
  if (!m) return new Set();
  const tokens = m[1].split(/\s+/).filter(Boolean);
  const pairs = new Set();
  for (let i = 0; i + 1 < tokens.length; i += 2) {
    pairs.add(tokens[i]); // namespace half of each pair
  }
  return pairs;
};

const collectAttrUses = (xml, attrName) => {
  const re = new RegExp(`\\b${attrName}\\s*=\\s*"([^"]+)"`, 'g');
  const out = [];
  let m;
  while ((m = re.exec(xml))) out.push(m[1]);
  return out;
};

const collectTopLevelConfigNames = (xml) => {
  // <prefix:something name="..." ...> at the top level (children of <mule>).
  // Conservative: any element with a name="..." attribute that isn't <flow>/<sub-flow>.
  const re = /<([A-Za-z_][\w.\-:]*)\s+([^>]*?)name\s*=\s*"([^"]+)"([^>]*)\/?>/g;
  const out = new Set();
  let m;
  while ((m = re.exec(xml))) {
    const tag = m[1];
    if (tag === 'flow' || tag === 'sub-flow') continue;
    out.add(m[3]);
  }
  return out;
};

for (const flowPath of flowFiles) {
  const xml = readFileSync(flowPath, 'utf8');
  const fileLabel = basename(flowPath);
  const errors = [];

  // 1. Parse <mule ...> root tag.
  const rootM = xml.match(/<mule\b[^>]*>/);
  if (!rootM) {
    errors.push(`${fileLabel}: no <mule> root element`);
    allErrors.push(...errors);
    continue;
  }
  const rootTag = rootM[0];
  const xmlnsMap = collectXmlnsDecls(rootTag);
  const schemaPairs = collectSchemaLocationPairs(rootTag);

  // Check 1: every xmlns:<prefix> has a matching schemaLocation pair (excluding doc, xsi, the default).
  for (const [prefix, ns] of xmlnsMap.entries()) {
    if (prefix === '' || prefix === 'doc' || prefix === 'xsi') continue;
    if (!schemaPairs.has(ns)) {
      errors.push(`${fileLabel}: xmlns:${prefix}="${ns}" declared but no matching pair in xsi:schemaLocation`);
    }
  }

  // Check 2: every <prefix:element> used is known. Skip if prefix is trusted or unknown to us.
  const elementUses = new Set();
  const elemRe = /<\/?([A-Za-z_][\w.\-]*):([A-Za-z_][\w.\-]*)\b/g;
  let em;
  while ((em = elemRe.exec(xml))) {
    elementUses.add(`${em[1]}:${em[2]}`);
  }
  for (const qualified of elementUses) {
    const [prefix, element] = qualified.split(':');
    if (trustedPrefixes.has(prefix)) continue;
    const bucket = byPrefix.get(prefix);
    if (!bucket) continue; // we have no digest for this prefix; can't say
    if (!bucket.elementNames.has(element)) {
      errors.push(`${fileLabel}: <${qualified}> not in digest for prefix "${prefix}" (known: ${[...bucket.elementNames].sort().slice(0, 6).join(', ')}...)`);
    }
  }

  // Check 3: <on-error-propagate type="..."> uses a known error type.
  // Pull the union of every digest's errorTypes plus a small core set always available.
  const allErrorTypes = new Set(['MULE:ANY', 'MULE:CRITICAL']);
  for (const bucket of byPrefix.values()) {
    for (const e of bucket.errorTypes) allErrorTypes.add(e);
  }
  for (const t of collectAttrUses(xml, 'type')) {
    // type="..." appears on many elements; only enforce on the ones inside error-handler.
    // Scope: only within <error-handler>...</error-handler>.
  }
  // Restricted check: only warn if the value is clearly an error-type (uppercase NS:NAME)
  // and we have at least one digest whose errorTypes look related.
  const onErrRe = /<on-error-(?:propagate|continue)\b[^>]*\btype\s*=\s*"([^"]+)"/g;
  let onErrM;
  while ((onErrM = onErrRe.exec(xml))) {
    const t = onErrM[1].trim();
    if (!t) continue;
    if (t === 'ANY' || t.startsWith('MULE:') || t.startsWith('CORE:')) continue;
    if (allErrorTypes.has(t)) continue;
    // Tolerate prefixed types (FOO:BAR) when we have no digest for FOO.
    const ns = t.split(':')[0];
    const matched = [...byPrefix.values()].some((b) => b.errorTypes.size > 0 && [...b.errorTypes].some((e) => e.startsWith(`${ns.toUpperCase()}:`)));
    if (matched) {
      errors.push(`${fileLabel}: <on-error-...> type="${t}" not in any connector digest's errorTypes (closest match: ${ns}:*)`);
    }
  }

  // Check 4: every config-ref="..." references a top-level element with that name.
  const configNames = collectTopLevelConfigNames(xml);
  for (const ref of collectAttrUses(xml, 'config-ref')) {
    if (!configNames.has(ref)) {
      errors.push(`${fileLabel}: config-ref="${ref}" but no top-level element has name="${ref}"`);
    }
  }

  // Check 5: ${dotted.key} placeholders have matching config.yaml entries (best-effort).
  if (configYaml) {
    const placeholderRe = /\$\{([a-zA-Z][a-zA-Z0-9._-]*)\}/g;
    let pm;
    const seen = new Set();
    while ((pm = placeholderRe.exec(xml))) seen.add(pm[1]);
    for (const key of seen) {
      // Try to find the leaf (after the last dot) anywhere as a YAML key.
      const leaf = key.split('.').pop();
      const re = new RegExp(`(^|\\n)\\s*"?${leaf}"?\\s*:`);
      if (!re.test(configYaml)) {
        errors.push(`${fileLabel}: \${${key}} not found as a key in config.yaml`);
      }
    }
  }

  allErrors.push(...errors);
}

// ---- output -------------------------------------------------------------

if (allErrors.length === 0) {
  process.stdout.write(`flow XML validation passed (${flowFiles.length} file(s))\n`);
  process.exit(0);
}

process.stderr.write(`flow XML validation FAILED (${allErrors.length} issue(s))\n`);
for (const e of allErrors) process.stderr.write(`  - ${e}\n`);
process.exit(1);
