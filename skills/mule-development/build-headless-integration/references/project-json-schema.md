# Versionless project descriptors

The headless skill writes two descriptor files at the project root, matching the shape produced by the [upgrade-to-versionless flow](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/internal/project/DefaultProjectPropertiesService.java) on the ACB plugin side. A project the skill creates and a project the user upgrades from Maven are byte-for-byte the same shape; both render and test-connect through the same code path.

## `project-manifest.json` (sibling of `pom.xml`)

The connector list lives here, name-only. This is the file the plugin's [`ProjectManifest.readConnectorNames`](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/internal/project/ProjectManifest.java) reads to drive [`ManifestRdsExtensionModelSource`](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/internal/extension/json/ManifestRdsExtensionModelSource.java).

```json
{
  "version": 1,
  "connectors": [
    { "name": "salesforce" },
    { "name": "twilio" }
  ]
}
```

- The connector `name` is the **single key across the chain** — XML prefix in the flow, `go:<name>` registry key in the plugin, connector name on the wire to RDS, name registered in [`connector-service/config.yaml`](file:///Users/tzeree/Salesforce/workspace/go-runtime/services/connector-service/config.yaml).
- No `path`, no version. Projects are versionless — RDS always serves the latest descriptor.
- Names accepted: `[A-Za-z0-9._-]+` (`ProjectManifest.VALID_NAME`). Anything else is rejected at parse to keep RDS URL paths and cache directory names safe.
- Schema design + degradation rules: [`go-connector-headless-descriptors.md`](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/docs/go-connector-headless-descriptors.md) §8.

## `.mule/project.json` (workspace descriptor)

Workspace-level metadata. **Does not list connectors** — that moved to `project-manifest.json`.

```json
{
  "modelVersion": "1.1.0",
  "name": "demo-sf-poller",
  "version": "1.0.0-SNAPSHOT",
  "natures": ["mule"],
  "components": [],
  "muleVersion": "4.11.2",
  "javaVersion": "17",
  "dependencies": [],
  "sharedLibraries": []
}
```

Reader (today): [`DefaultProjectDescriptor.java`](file:///Users/tzeree/Salesforce/workspace/mule-dx-vscode/mule-dx-platform/src/main/java/org/mule/dx/platform/internal/api/impl/DefaultProjectDescriptor.java) — currently expects a `source` URI pointing at an existing `pom.xml`. The skill emits a stub `pom.xml` to satisfy this until the platform changes below land.

## Why two files

`project-manifest.json` predates the headless work — it exists because the upgrade flow needed an additive way to list versionless connectors without rewriting `.mule/project.json`. The skill follows that contract verbatim. When the platform-level no-pom support lands ([STATUS.md → Java platform](../STATUS.md)), `.mule/project.json` becomes self-sufficient and the stub `pom.xml` goes away. `project-manifest.json` stays — that's the contract the plugin's registry source reads.

## Connector descriptors are NOT in the project

In `.go-connectors.json`-era setups, projects shipped each connector's `extension-model.json` + `dsl.json` + `extension.xsd` under `go-connectors/<name>/`. That's retired. Now:

- The plugin reads the manifest, gets connector names, and resolves descriptors from `~/AnypointCodeBuilder/.cache/go/<name>/`.
- Cache miss → `GET /v1/connectors/{name}/descriptor` on RDS → write-through to the cache.
- Skill `create_versionless_project.sh` pre-warms the cache during project generation so the canvas renders on first project-open without a network round-trip.
- Full design: [`go-connector-headless-descriptors.md`](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/docs/go-connector-headless-descriptors.md).

## Java platform follow-up (not blocking the skill)

Today the skill emits a stub `pom.xml` because [`WorkspaceManagerImpl.java`](file:///Users/tzeree/Salesforce/workspace/mule-dx-vscode/mule-dx-platform/src/main/java/org/mule/dx/platform/internal/WorkspaceManagerImpl.java) requires `source` to point at an existing `pom.xml`. To drop the stub:

1. Add `muleVersion`, `javaVersion`, `dependencies`, `sharedLibraries` to [`DefaultProjectDescriptor.java`](file:///Users/tzeree/Salesforce/workspace/mule-dx-vscode/mule-dx-platform/src/main/java/org/mule/dx/platform/internal/api/impl/DefaultProjectDescriptor.java); make `source` nullable.
2. In `WorkspaceManagerImpl`: skip the `pom.xml` requirement when a sibling `project-manifest.json` is present.

The skill's output won't change — only the stub `pom.xml` emit goes away.
