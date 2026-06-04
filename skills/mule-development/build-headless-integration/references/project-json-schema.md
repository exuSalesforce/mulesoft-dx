# `.mule/project.json` schema (versionless / Demo 2)

The headless skill writes a `.mule/project.json` that extends today's metadata-only descriptor with `dependencies[]`, `goConnectors[]`, and explicit `muleVersion` / `javaVersion`.

## Today's shape (master, no deps)

```json
{
  "modelVersion": "1.0.0",
  "name": "...",
  "version": "...",
  "source": "file:///path/to/pom.xml",
  "natures": ["mule"],
  "components": []
}
```

Reader: [DefaultProjectDescriptor.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-vscode/mule-dx-platform/src/main/java/org/mule/dx/platform/internal/api/impl/DefaultProjectDescriptor.java). Today's loader requires `source` to point at an existing `pom.xml` (see [WorkspaceManagerImpl.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-vscode/mule-dx-platform/src/main/java/org/mule/dx/platform/internal/WorkspaceManagerImpl.java)).

## Skill output (Demo 2)

```json
{
  "modelVersion": "1.1.0",
  "name": "demo-sf-poller",
  "version": "1.0.0-SNAPSHOT",
  "natures": ["mule"],
  "components": [],
  "muleVersion": "4.11.0",
  "javaVersion": "17",
  "dependencies": [],
  "sharedLibraries": [],
  "goConnectors": [
    { "name": "salesforce", "path": "./go-connectors/salesforce" }
  ]
}
```

Notes:

- `source` is omitted. The skill emits a stub `pom.xml` at the project root so today's `WorkspaceManagerImpl` can still load the project; the stub carries no connector deps because Go connectors are not Maven artifacts.
- `goConnectors[]` mirrors the top-level `.go-connectors.json` ([DefaultJsonExtensionModelSource.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/internal/extension/json/DefaultJsonExtensionModelSource.java)). Both files exist for now — the platform looks at `.go-connectors.json`; `.mule/project.json` is the future SoT.
- `dependencies[]` is reserved for Maven-resolved deps (none today; Go-only).
- `modelVersion: "1.1.0"` flags the new shape; readers ignoring unknown fields stay compatible.

## Java platform follow-up (not blocking Demo 2)

To make the skill's `.mule/project.json` self-sufficient (no stub `pom.xml`):

1. Add `muleVersion`, `javaVersion`, `dependencies`, `goConnectors`, `sharedLibraries` fields to [DefaultProjectDescriptor.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-vscode/mule-dx-platform/src/main/java/org/mule/dx/platform/internal/api/impl/DefaultProjectDescriptor.java) and its builder.
2. Make `source` nullable.
3. In [WorkspaceManagerImpl.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-vscode/mule-dx-platform/src/main/java/org/mule/dx/platform/internal/WorkspaceManagerImpl.java), branch on versionless: skip the pom.xml requirement when `descriptor.dependencies != null` or `descriptor.goConnectors != null`.

Until that lands, the skill's stub-pom path is the only way ACB can open these projects.
