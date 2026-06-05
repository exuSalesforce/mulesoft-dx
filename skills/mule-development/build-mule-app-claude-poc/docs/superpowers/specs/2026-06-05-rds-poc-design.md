# build-mule-app-claude-poc — RDS Integration & Trigger Choice

**Date:** 2026-06-05
**Topic:** Make the POC skill work end-to-end against the live go-runtime RDS, install it as a user-level skill, and add a Scheduler-vs-HTTP trigger choice as a mandatory user input.

## Goal

Update `build-mule-app-claude-poc` so that:

1. Claude Code picks it up automatically (it currently isn't installed).
2. It always asks the user for a trigger type — Scheduler or HTTP — and persists the choice.
3. Its scripts call the actual RDS endpoints exposed by go-runtime at `http://localhost:8090` (the current scripts call endpoints that don't exist).
4. The scaffolder produces XML matching the structure of the reference sample at `~/Downloads/salesforce-accounts-to-twilio/src/main/mule/salesforce-accounts-to-twilio.xml`, derived from the RDS's `extensionModel` + `dsl` + `xsd` artifacts.

## Three core problems

### Problem 1 — Skill is not installed

The skill lives at `~/projects/mulesoft-dx/skills/mule-development/build-mule-app-claude-poc/`, but Claude Code only auto-loads skills under `~/.claude/skills/<name>/` (user) or `<project-root>/.claude/skills/<name>/` (project). Nothing currently makes Claude Code aware of this skill.

**Fix:** Symlink `~/.claude/skills/build-mule-app-claude-poc -> <repo-path>`. User-level install (per user choice) so the skill is available from any working directory. Edits to the canonical repo location are picked up immediately — no rebuild step.

The skill's `description:` frontmatter already includes strong trigger phrases ("create a mule application", "build a mule app", from-X-to-Y phrasings) plus a "call use_skill as your FIRST action" directive. No frontmatter change required. The only skill that would have overlapped is `build-mule-integration`, but that one is referenced only in prose inside SKILL.md; it isn't installed.

### Problem 2 — RDS contract is wrong

`references/rds-api.md` documents a contract the actual go-runtime RDS does not implement. Every script except `_rds_lib.sh` calls non-existent endpoints.

| Script's URL | Actual RDS URL | Response shape |
|---|---|---|
| `GET /healthz` | ✅ same | `{"ready": true}` (script expects `{"status": "ok"}`) |
| `GET /connectors?q=X` | `GET /v1/connectors` (no filter) | `{"connectors":[{name, operations[]}]}` (script expects flat array with id/name/namespace/description) |
| `GET /connectors/{id}` | `GET /v1/connectors/{name}/descriptor` | `{name, version, extensionModel, dsl, xsd}` (script expects flat operations/configs/connectionProviders blocks) |
| `GET /connectors/{id}/operations/{op}` | **does not exist** | extract from cached `extensionModel.operations[]` instead |

This means the scripts cannot run successfully against the real RDS today.

### Problem 3 — Trigger is hard-coded to HTTP

Steps 2 and 5 of SKILL.md state "Trigger is fixed for this POC" and explicitly redirect any Scheduler/cadence request to `build-mule-integration`. The user wants Scheduler as a first-class option.

## Section 1 — Skill installation

```
ln -s ~/projects/mulesoft-dx/skills/mule-development/build-mule-app-claude-poc \
      ~/.claude/skills/build-mule-app-claude-poc
```

Verification: open a new Claude Code session in any directory, type "create a mule application that posts the top 5 Salesforce accounts to Twilio", and confirm the skill activates.

## Section 2 — Trigger user input

Insert a mandatory `AskUserQuestion` at **Step 2** (between system identification and connector listing):

> **Question:** "Which trigger should this Mule app use?"
> **Options:** HTTP listener / Scheduler

For HTTP, follow up with: path (default `/ops/<project-name>`) + method (default POST).
For Scheduler, follow up with: frequency (number) + timeUnit (`SECONDS` | `MINUTES` | `HOURS`, default `MINUTES`) + startDelay (default 0).

The choice is merged into `tmp/spec-inputs.json` immediately:

**HTTP shape:**
```json
"trigger": {
  "type": "http-listener",
  "method": "POST",
  "path": "/ops/salesforce-accounts-to-twilio"
}
```

**Scheduler shape:**
```json
"trigger": {
  "type": "scheduler",
  "schedulingStrategy": "fixed-frequency",
  "frequency": 5,
  "timeUnit": "MINUTES",
  "startDelay": 0
}
```

The scaffolder branches its emitted XML on `trigger.type`. Two templates inside `scaffold_project.sh`:

- **HTTP** → `<http:listener-config>` global + `<http:listener>` as the flow's first child. Set-variables read from `payload.limit` / `payload.phoneNumber`. Final response payload is built by the closing `<ee:transform>`.
- **Scheduler** → no listener-config. Flow opens with `<scheduler doc:name="..."><scheduling-strategy><fixed-frequency frequency="5" timeUnit="MINUTES" startDelay="0"/></scheduling-strategy></scheduler>`. Set-variables read from config (`#[p('app.limit')]`, `#[p('app.phoneNumber')]`) since there's no inbound payload. The closing response transform is omitted; flow ends with the success logger.

The "Trigger is fixed for this POC" lines in Steps 2 and 5 of SKILL.md are removed. The redirect-to-`build-mule-integration` rule for Scheduler is removed. The redirect for OAuth/JWT auth stays (out of scope for the POC).

## Section 3 — Script rework against the real RDS

Six files change.

### `_rds_lib.sh`

`rds_get` mostly fine. Add a `RDS_API_PREFIX` env var (default `/v1`) so `rds_get` callers pass a path like `/connectors` and the function rewrites to `/v1/connectors`. Healthz stays unprefixed (call `rds_get_raw "/healthz"` or just inline the curl in `check_env.sh`).

### `check_env.sh`

Change the health expectation from `.status == "ok"` to `.ready == true`. Otherwise unchanged.

### `list_connectors.sh`

Call `GET /v1/connectors`. The RDS does not filter — drop the `?q=` query param. The optional CLI search term filters client-side via `jq` against `.connectors[].name`. The response shape is `{"connectors": [{"name": "salesforce", "operations": [...]}]}`, so the digest extracts `name` plus the operation count:

```
salesforce  6 operations
twilio      1 operation
```

The list response carries no `description` or `namespace` fields. The Phase-1 prose in SKILL.md that mentions "namespace column" gets updated.

### `describe_connector.sh`

Call `GET /v1/connectors/{name}/descriptor`. Persist the full response (which includes `extensionModel`, `dsl`, `xsd`) to `tmp/connector-metadata/<nickname>.json`. Also write `xsd` separately to `tmp/connector-metadata/<nickname>.xsd` so `xmllint` can use it later.

The digest changes to extract from `extensionModel`:

| Old digest field | New extraction path |
|---|---|
| `namespace_prefix` | `.extensionModel.xmlDsl.prefix` |
| `operations_count` | `.extensionModel.operations \| length` |
| `operations_sample` | `.extensionModel.operations[0:20] \| map(.name)` |
| `configs[].providers` | `.extensionModel.configurations[].connectionProviders[].name` |
| `error_types` | `.extensionModel.errorModels // []` (best-effort; may be absent) |

### `describe_operation.sh`

Becomes a **local** extraction step — no RDS call. It reads the cached `tmp/connector-metadata/<nickname>.json`, finds `.extensionModel.operations[] | select(.name == "<op>")`, and writes that slice plus the matching `.dsl.operations.<op>` block (when present) to `tmp/connector-metadata/<nickname>.<op>.json`.

If the connector hasn't been described yet, the script fails loudly: "No descriptor at `<path>` — run describe_connector.sh first."

### `write_spec.sh`

Reads spec inputs as before. The `connectionProvider` resolution updates to walk `extensionModel.configurations[]` instead of the flat `configs[]` it expects today. Output sidecar stays the same shape (downstream scaffolder consumes the same fields).

### `scaffold_project.sh`

Major rework — see Section 4.

## Section 4 — XML synthesis from extensionModel + dsl + xsd

### Strategy: extensionModel + dsl drive emission, xsd validates

Two slices per connector are read by the scaffolder:

- **`extensionModel.xmlDsl`** for namespace info → `xmlns:<prefix>` and `xsi:schemaLocation` on the root `<mule>` element. The current scaffolder builds these by string-concat of the prefix; the new scaffolder reads `.namespace` and `.schemaLocation` verbatim.
- **`extensionModel.operations[<op>]`** + **`dsl.operations.<op>`** (when present) for the operation element itself.

### Per-element emission rule

For a connector operation:

1. **Element name** — `dsl.operations.<op>.elementName` if present, else `extensionModel.operations[<op>].name`.
2. **Always emit `config-ref="<configName>"`** as the first attribute on the operation element.
3. **For each parameter** in `extensionModel.operations[<op>].parameterGroups[*].parameters[]`:
   - If the parameter type is a primitive (string, number, boolean) and `dsl` does not flag it as an inline element, emit as an XML attribute. Value source order: user-provided in `params`, then `${<prefix>.<paramName>}` placeholder, then default.
   - If `dsl` flags it as a child element (text content for SOQL queries, complex types) emit as a nested element wrapped in the `dsl` element name (e.g. `<salesforce:salesforce-query>...</salesforce:salesforce-query>`).
4. **`doc:name` and `doc:description`** are always emitted on the operation element so the React Flow canvas can label nodes (Step 10 stays optional).

For connection providers, the same rule applies against `extensionModel.configurations[].connectionProviders[]` and the matching `dsl` block.

### Validation step

After emitting, run `xmllint --noout --schema tmp/connector-metadata/<nick>.xsd <flow.xml>`. Validation is **warn-only** — POC iteration cannot afford a hard fail when `dsl` gaps produce minor schema mismatches.

If `xmllint` is not installed, skip validation with a warning instead of failing.

### Glue between connector elements — hand-written templates

Two templates baked into `scaffold_project.sh`, one per trigger type. They define the flow shell (everything that isn't a connector element) and call back into the per-element emission rule for the source/target connector slots.

**Common to both templates:**
- root `<mule>` with namespaces from extensionModel
- `<configuration-properties file="config.yaml" ...>`
- global config elements for source + target (rendered from connectionProvider)
- `<flow name="<project>" doc:name doc:description>`
- the trigger element (template-specific)
- set-variables for `limit` and `phoneNumber` (sourced differently per trigger)
- the source operation element (per emission rule)
- `<logger>` summarizing the source result
- `<ee:transform>` building the target's request payload — DataWeave body templated from `target.params.bodyTemplate`, with `vars.accounts`, `vars.phoneNumber`, `vars.limit` available
- the target operation element (per emission rule)
- `<logger>` summarizing the target response
- `<error-handler>` with `<on-error-propagate type="ANY">`

**HTTP-only:** http listener + http listener-config; closing `<ee:transform>` building the JSON response payload.

**Scheduler-only:** `<scheduler>` + `<scheduling-strategy><fixed-frequency .../></scheduling-strategy>`; no listener-config; no closing response transform.

The reference `salesforce-accounts-to-twilio.xml` is the visual target for the HTTP template. Matching it byte-for-byte is not required (e.g., the reference uses `${twilio.accountSid}` while the scaffolder will emit `${twilio.username}` because the connection provider's required attributes are named `username`/`password`). The scaffolder's output is correct as long as it parses and runs.

## Section 5 — Smaller cleanups

- **Default project dir.** `POC_PROJECT_DIR` default changes from `./<project-name>` to `~/projects/mule-poc-output/<project-name>`. `scaffold_project.sh` `mkdir -p`s the parent if needed. Override via env var still works.
- **React Flow Step 10.** `xml_to_reactflow.sh` keeps producing the JSON sidecar. The Pencil MCP rendering call is marked optional in SKILL.md. End-state validation focuses on the XML matching the reference sample, not on the canvas rendering.
- **`references/rds-api.md` rewrite.** Replaces the assumed contract with the actual go-runtime endpoints, the three-field descriptor response, and the "no operation endpoint — extract locally" note.
- **SKILL.md cleanup.** Lines mentioning "Trigger is fixed", redirect-on-Scheduler, and the old endpoint paths get rewritten. The scaffolder template description is updated to reflect the two trigger templates.

## Components & data flow

```
User prompt
   │
   ▼
Step 1: check_env.sh ──► tmp/poc-env.json   (RDS reachable, .ready == true)
Step 2: identify systems + ASK trigger ──► tmp/spec-inputs.json (with trigger block)
Step 3: list_connectors.sh ──► tmp/connectors-list.json    (calls /v1/connectors)
Step 4: describe_connector.sh ──► tmp/connector-metadata/<nick>.json
                                   tmp/connector-metadata/<nick>.xsd
                                   (calls /v1/connectors/<id>/descriptor)
Step 5: describe_operation.sh ──► tmp/connector-metadata/<nick>.<op>.json
                                   (LOCAL extract from cached descriptor)
Step 6: ASK params (SOQL, body template) ──► merge into tmp/spec-inputs.json
Step 7: write_spec.sh ──► tmp/spec/<project>.{md,json}
Step 8: USER APPROVAL GATE
Step 9: scaffold_project.sh
          │
          ├─► <PROJECT_DIR>/project-artifact.json
          ├─► <PROJECT_DIR>/src/main/mule/<project>.xml
          │     ├── trigger:
          │     │     http-listener template  (if trigger.type == "http-listener")
          │     │     scheduler template      (if trigger.type == "scheduler")
          │     ├── source connector element  (emitted from extensionModel + dsl)
          │     ├── target connector element  (emitted from extensionModel + dsl)
          │     └── glue (set-variable, ee:transform, logger, error-handler)
          ├─► <PROJECT_DIR>/src/main/resources/config.yaml
          ├─► <PROJECT_DIR>/yaml/{config,<project>-flow}.yaml
          └─► xmllint --schema <nick>.xsd → warn-only validation
Step 10: xml_to_reactflow.sh ──► tmp/reactflow/<project>.json (optional render)
Step 11: success message + ACB link
```

## Risks & open questions

1. **`dsl` field's actual shape is undocumented.** The go-runtime explorer report says it's a `json.RawMessage` shipped from `connectors/<name>/descriptor/dsl.json`, but its internal structure isn't documented. We may discover at implementation time that `dsl.operations.<op>.elementName` doesn't exist. Fallback: use `extensionModel.operations[<op>].name` as the element name and treat all primitive parameters as attributes, complex types as child elements named after the parameter.

2. **`xmllint` may not be installed.** If absent, skip validation with a warning instead of failing. Consistent with "warn, don't block" stance for POC iteration.

3. **The reference `salesforce-accounts-to-twilio.xml` was hand-written.** It's the visual target, but matching it exactly is not required. Specifically `${twilio.accountSid}` vs `${twilio.username}` is stylistic — the scaffolder emits whatever the connectionProvider's required attributes are named.

4. **Scheduler template has not been validated against the Go runtime.** The Mule 4 `<scheduler>` element shape is well-documented, but whether the Go runtime executes it correctly is a separate test. POC scope is "scaffold a project that opens correctly in ACB", not "executes correctly on the Go runtime".

## Out of scope

- OAuth / JWT / mTLS connection providers (Salesforce/Twilio basic auth only).
- Connectors other than Salesforce, Twilio, and HTTP for the canonical POC prompt. The scaffolder must be metadata-driven enough that swapping in another connector "just works", but verifying that across the whole RDS catalog is not required.
- Pencil MCP canvas rendering (defer; JSON sidecar is enough).
- A Go-runtime RDS change to add a `/v1/connectors/{name}/operations/{op}` endpoint (we extract locally from the cached descriptor).
- Adding a `?q=` query filter to `GET /v1/connectors` (we filter client-side).
