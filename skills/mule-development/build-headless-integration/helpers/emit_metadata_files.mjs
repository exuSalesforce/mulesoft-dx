#!/usr/bin/env node
// Split the rich digest emitted by digest_extension_model.mjs into the family of
// per-shape files the build-mule-integration skill produces under tmp/connector-metadata/
// and tmp/connector-errors/.
//
// Output (all under <outDir>/):
//   connector-metadata/<nick>.json              — flat name lists (operations[], sources[], configs[]) + namespace + connector-wide errorTypes
//   connector-metadata/<nick>-<op>.json         — per-operation: attributes[], errorTypes[]
//   connector-metadata/<nick>-config.json       — per-config: attributes[], connectionProviders[].attributes[]
//   connector-errors/<nick>.json                — { errorTypes: [...] } (connector-wide)
//   connector-errors/<nick>.<op>.json           — { errorTypes: [...] } per-operation (matches sfdc.query.json shape)
//
// Usage: emit_metadata_files.mjs <nick> <digest.json> <outDir>
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';

const [, , nick, digestPath, outDir] = process.argv;
if (!nick || !digestPath || !outDir) {
  console.error('Usage: emit_metadata_files.mjs <nick> <digest.json> <outDir>');
  process.exit(2);
}

const digest = JSON.parse(readFileSync(digestPath, 'utf8'));
const metaDir = join(outDir, 'connector-metadata');
const errDir = join(outDir, 'connector-errors');
mkdirSync(metaDir, { recursive: true });
mkdirSync(errDir, { recursive: true });

const writeJson = (path, obj) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(obj, null, 2));
};

const namespaceBlock = {
  prefix: digest.prefix,
  namespace: digest.namespace,
  schemaLocation: digest.schemaLocation,
};

// Walk every operation+source across configurations once to collect the connector-wide
// error type set. The Java side emits `errors[]` per op; some types only show up on
// specific ops (e.g. `SALESFORCE:NOT_FOUND` on retrieve, not on describeGlobal).
const allErrorTypes = new Set();
const flattenAttributes = (groups) =>
  (groups || [])
    .flatMap((g) => g.parameters || [])
    .map((p) => ({
      attributeName: p.name,
      required: p.required,
      ...(p.description ? { description: p.description } : {}),
      ...(p.defaultValue !== null && p.defaultValue !== undefined ? { defaultValue: p.defaultValue } : {}),
      ...(p.allowedValues ? { allowedValues: p.allowedValues } : {}),
    }));

for (const cfg of digest.configurations || []) {
  for (const op of [...(cfg.operations || []), ...(cfg.sources || [])]) {
    const opErrors = op.errorTypes || [];
    opErrors.forEach((e) => allErrorTypes.add(e));

    // <nick>-<op>.json — per-operation deep metadata
    writeJson(join(metaDir, `${nick}-${op.name}.json`), {
      name: op.name,
      prefix: digest.prefix,
      elementName: op.element,
      errorTypes: opErrors,
      attributes: flattenAttributes(op.parameterGroups),
    });

    // connector-errors/<nick>.<op>.json — separate error file (sfdc.query.json shape)
    writeJson(join(errDir, `${nick}.${op.name}.json`), {
      errorTypes: opErrors,
    });
  }

  // <nick>-config.json — per-config deep metadata, including connection providers
  writeJson(join(metaDir, `${nick}-config.json`), {
    name: cfg.name,
    prefix: digest.prefix,
    elementName: cfg.element,
    attributes: [],
    connectionProviders: (cfg.connectionProviders || []).map((p) => ({
      name: p.name,
      elementName: p.element,
      ...(p.description ? { description: p.description } : {}),
      attributes: flattenAttributes(p.parameterGroups),
    })),
  });
}

// <nick>.json — flat connector-wide reference (matches sfdc.json shape)
const flatConfigs = (digest.configurations || []).map((c) => ({
  name: c.name,
  connectionProviders: (c.connectionProviders || []).map((p) => p.name),
}));
const flatOps = (digest.configurations || []).flatMap((c) => (c.operations || []).map((o) => o.name));
const flatSources = (digest.configurations || []).flatMap((c) => (c.sources || []).map((s) => s.name));

writeJson(join(metaDir, `${nick}.json`), {
  namespace: namespaceBlock,
  operations: flatOps,
  sources: flatSources,
  configs: flatConfigs,
  constructs: [],
  errorTypes: [...allErrorTypes].sort(),
});

// connector-errors/<nick>.json — connector-wide whitelist
writeJson(join(errDir, `${nick}.json`), {
  errorTypes: [...allErrorTypes].sort(),
});

process.stdout.write(`${metaDir}\n${errDir}\n`);
