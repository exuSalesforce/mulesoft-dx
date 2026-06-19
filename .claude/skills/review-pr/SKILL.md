---
name: review-pr
description: Use when reviewing, validating, or approving a PR in this repo — runs deterministic validators (OAS governance, x-origin, JTBD) then a structured AI code review across 7 angles (correctness, removed behavior, cross-refs, duplication, consistency). Accepts a single PR number or reviews all open non-approved PRs. Can filter by author or date.
---

# Review PR(s) — mulesoft/mulesoft-dx

## Inputs (provided by caller or inferred)

| Parameter | How to supply | Default |
|-----------|--------------|---------|
| `PR_NUMBER` | "review PR #123" | — reviews all open PRs |
| `SINCE` | "since 2026-06-18T09:00:00Z" | no date filter |
| `SKIP_AUTHOR` | "skip PRs by leandrogilcarrano" | none |

## Step 1 — Discover PRs

**Single PR:** skip discovery, go to Step 2 with that number.

**Bulk review:** fetch open, non-approved PRs:

```bash
gh pr list \
  --repo mulesoft/mulesoft-dx \
  --state open \
  --json number,title,author,updatedAt,reviewDecision \
  --jq "[.[] | select(.reviewDecision != \"APPROVED\")]"
```

Apply filters if provided:
- `SKIP_AUTHOR`: exclude `.author.login == SKIP_AUTHOR`
- `SINCE`: keep only `.updatedAt > SINCE` (exclude PRs with no changes since that timestamp)

If no PRs remain: report "No PRs to review." and exit.

## Step 2 — Checkout and identify changes

```bash
gh pr checkout <PR_NUMBER>
git diff master...HEAD --name-only
```

Categorize changed files:
- `apis/**` → API spec changes
- `skills/**` → JTBD/prose skill changes
- `mcps/**` → MCP server changes
- `scripts/**` → portal generator changes

## Step 3 — Deterministic validators (before any AI analysis)

Run in parallel:

### OAS governance
```bash
make validate-all-governed 2>&1 | tail -20
# Or targeted if only specific APIs changed:
make validate-api API=apis/<changed-api-dir>
```

### x-origin annotations
```bash
python3 scripts/build/validate_xorigin.py 2>&1
```

### JTBD skills
```bash
for job in skills/*/SKILL.md skills/*/*/SKILL.md; do
  [ -f "$job" ] && python3 scripts/build/validate_jtbd.py "$job" . 2>&1
done
```

### Skill quality (when `skills/**` files changed)

For every `skills/**/SKILL.md` modified in the PR, run the `skill-quality-review` skill. This covers content quality (token efficiency, discoverability, calibration) — the JTBD validator only covers structure.

Notes:
- If Anypoint CLI is not installed, skip OAS validation and note it.
- Prose-type skills (`type: prose`) skip JTBD validation but still run `skill-quality-review`.

## Step 4 — AI review (7 angles)

**A — Line-by-line diff scan**
Read every hunk. For API specs: operationId uniqueness, missing descriptions, broken `$ref` links, missing examples, schema issues. For skills: step numbering, YAML block structure, broken `urn:api:` references, stale cross-skill references.

**B — Removed behavior**
For every deleted line, identify the invariant it enforced. Check if re-established elsewhere. Flag dropped validations, removed steps, deleted required fields.

**C — Cross-file tracer**
For skills referencing APIs via `urn:api:` or file links, verify those targets exist and operationIds are valid. Check `x-origin` references point to real operations.

**D — Reuse**
Flag duplication — skills that replicate steps already in another skill, API schemas defined inline when they could `$ref` a shared schema.

**E — Simplification**
Unnecessary complexity — redundant YAML blocks, over-nested structures, dead steps left behind.

**F — Consistency**
Does the change follow repo patterns? (camelCase operationIds, semver in `exchange.json`, imperative voice in descriptions, `urn:api:` format for cross-references)

**G — Altitude**
Is the fix at the right level? A skill patching around a missing API operation should instead add the operation.

## Step 5 — Verify findings (1-vote, 3-state)

- **CONFIRMED** — can reproduce with specific inputs/state
- **PLAUSIBLE** — mechanism real, trigger uncertain
- **REFUTED** — guarded elsewhere or factually wrong

Drop REFUTED findings.

## Step 6 — Output

**Never post to GitHub.** Do NOT call `gh pr review`, `gh pr comment`, or any GitHub write command.

```
## PR #<number> — <title>
**Author:** <author> | https://github.com/mulesoft/mulesoft-dx/pull/<number>

### Validators
- OAS: ✅ / ❌ <error summary> / ⏭️ skipped (Anypoint CLI not installed)
- x-origin: ✅ / ❌
- JTBD: ✅ / ❌ / ⏭️ skipped (prose-type skill)

### Findings
**Must fix:**
- `<file>:<line>` — <description>

**Nice to fix:**
- `<file>:<line>` — <description>

### Your action
- ✅ Approve — no blockers. Ready to approve.
- 🔄 Request changes — paste as PR comment:
  > <ready-to-paste comment text>
- ⏭️ Skip — already approved or no changes needed.
```

After all PRs reviewed, restore repo:
```bash
git checkout master
```
