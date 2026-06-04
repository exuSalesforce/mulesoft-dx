# Flow templates

Three trigger-shaped starting points for `src/main/mule/<projectName>.xml`. Pick one based on the user's stated trigger, then substitute placeholders against the connector digest and design spec.

| Template | When to use |
| --- | --- |
| [`scheduler.xml`](scheduler.xml) | "every N seconds/minutes", polling, scheduled jobs, no inbound HTTP |
| [`http-listener.xml`](http-listener.xml) | "on incoming POST/GET", "expose a webhook", "trigger on request" |
| [`connector-source.xml`](connector-source.xml) | The picked connector exposes a source that fits (e.g. `salesforce:on-modified-object-listener`, `kafka:listener`). Read the digest's `sources:` line. |

All three follow the canonical pattern from [`reference-flow-pattern.md`](../reference-flow-pattern.md) and are modeled on [`testdata/apps/salesforce-accounts-to-twilio/src/main/mule/salesforce-accounts-to-twilio.xml`](file:///Users/tzeree/Salesforce/workspace/go-runtime/testdata/apps/salesforce-accounts-to-twilio/src/main/mule/salesforce-accounts-to-twilio.xml).

## Placeholders

Each template uses these patterns. Substitute against the design spec + connector digest:

- `__PREFIX__` → connector prefix from `tmp/connector-choices/<nick>.json` (e.g. `salesforce`, `twilio`)
- `__NAMESPACE__` → connector namespace (e.g. `http://www.mulesoft.org/schema/mule/salesforce`)
- `__SCHEMA_LOCATION__` → connector schemaLocation
- `__CONFIG_ELEMENT__` → e.g. `sfdc-config`, `config` — from `tmp/connector-metadata/<nick>-config.json:.elementName`
- `__CONFIG_NAME__` → from design spec `connections[].configName` (e.g. `salesforceConfig`)
- `__PROVIDER_ELEMENT__` → e.g. `basic`, `account-sid-auth-token` — from `tmp/connector-metadata/<nick>-config.json:.connectionProviders[].elementName`
- `__PROVIDER_NAME__` → matches `connections[].providerName`
- `__OP_ELEMENT__` → e.g. `query`, `create`, `create20100401AccountsMessagesjsonByAccountSid`
- `__FLOW_NAME__` → from project name (e.g. `salesforce-accounts-notify`)

## Multi-connector flows

For flows that touch more than one connector (the Salesforce → Twilio reference is the canonical case): start from one template, then for each additional connector add (a) its `xmlns:` declaration, (b) its `xsi:schemaLocation` pair, (c) its `<__PREFIX__:__CONFIG_ELEMENT__>` block, (d) the operation calls inside the flow. The `error-handler` stays at the bottom — one per flow, regardless of connector count.
