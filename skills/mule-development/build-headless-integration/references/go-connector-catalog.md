# Go-connector catalog (Demo 2)

Inventory of Go-connector bundles shipped with this skill at
[fixtures/go-connectors/](../fixtures/go-connectors/). Each bundle directory holds:

- `extension-model.json` — JSON-serialized `ExtensionModel` describing the connector
- `dsl.json` — DSL element syntax (XML element names, namespaces, schemas)
- `extension.xsd` — XSD for editor schema-aware features

The skill reads these directly — there is no service call to look them up.

## Inventory

| Bundle | Connector | Version | Vendor | Prefix | Config element | Providers |
| --- | --- | --- | --- | --- | --- | --- |
| `salesforce` | Salesforce | 11.4.0 | Mulesoft | `salesforce` | `salesforce:sfdc-config` | `basic`, `jwt`, `saml` |

When more bundles land, add a row above and copy the bundle into `fixtures/go-connectors/<name>/`. The agent's `search_connectors.sh` discovers them automatically — this table is just for human reference.

## Adding a new bundle

1. Drop the three files under `fixtures/go-connectors/<bundle-name>/`.
2. Confirm `bash scripts/search_connectors.sh <name-or-prefix>` lists it.
3. Confirm `bash scripts/pick_connector.sh test-nick <bundle-name>` and `bash scripts/describe_connector.sh test-nick` produce a sensible digest.
4. Add a row to the table above.

## Drift watch

The bundle layout is governed by [DefaultJsonExtensionModelSource.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/internal/extension/json/DefaultJsonExtensionModelSource.java). If the Java side changes its expected file names, `.go-connectors.json` schema, or per-bundle structure, this skill must follow.

If `extension-model.json`'s top-level shape changes (e.g. operations move out of `.configurations[0].operationModels`), update [helpers/digest_extension_model.mjs](../helpers/digest_extension_model.mjs).
