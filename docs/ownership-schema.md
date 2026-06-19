# Ownership Schema

Every asset in this repository (API specs, skills, and Terraform providers) must declare ownership via an `owner.yaml` file. Ownership data drives automated bug routing: when a GitHub Issue is opened against a spec, the system reads `owner.yaml` to notify the responsible team.

## Schema

**Source of truth:** `docs/schemas/owner.schema.json`

| Field | Required | Type | Description |
|---|---|---|---|
| `team` | yes | string | Human-readable team name |
| `slack` | yes | string | Slack channel for bug notifications (must start with `#`) |
| `gus_team` | no | string | GUS team name for auto-creating work items |

## File placement

### APIs

One `owner.yaml` per API directory:

```
apis/
└── api-manager/
    ├── api.yaml
    ├── exchange.json
    └── owner.yaml        ← required
```

### Terraform providers

One `owner.yaml` per provider (not per version):

```
terraform/
└── anypoint-provider/
    ├── owner.yaml        ← required, covers all versions
    └── 1.0.0/
        └── ...
```

### Skills

Skills use hierarchical resolution — the validator walks up the directory tree and uses the nearest `owner.yaml` found. This allows a single `skills/owner.yaml` to cover all skills, with per-skill overrides where needed:

```
skills/
├── owner.yaml                        ← default for all skills
├── platform-assistant/
│   ├── SKILL.md
│   └── owner.yaml                    ← overrides the default for this skill only
└── secure-api/
    └── SKILL.md                      ← inherits from skills/owner.yaml
```

## Examples

### Minimal (required fields only)

```yaml
team: "API Community Manager"
slack: "#api-cm-bugs"
```

### With GUS team

```yaml
team: "API Community Manager"
slack: "#api-cm-bugs"
gus_team: "API Community Manager"
```

## Validation

The validator runs automatically on every commit:

```bash
# Run manually
python3 scripts/build/validate_ownership.py

# Or via make
make validate-ownership
```

The validator uses a gradual-adoption model:
- **WARN** (exit 0) if `owner.yaml` is missing — contributors are not blocked
- **FAIL** (exit 1) if `owner.yaml` exists but is schema-invalid — malformed files are never silently accepted
- For skills, resolves ownership hierarchically (nearest `owner.yaml` wins)

## Bug routing pipeline

When a GitHub Issue is opened:

1. A scheduled CU workflow reads the issue and identifies affected asset paths
2. For each path, the workflow resolves the `owner.yaml`
3. If the asset belongs to an external team → posts a Slack message to `slack` channel
4. If the asset belongs to the portal team → creates a GUS work item under `gus_team`
