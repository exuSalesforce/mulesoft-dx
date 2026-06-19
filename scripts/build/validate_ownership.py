#!/usr/bin/env python3
"""
Ownership validator.

Validates owner.yaml files in this repository against docs/schemas/owner.schema.json.

Behavior:
  - WARN (exit 0) when owner.yaml is missing — adoption is gradual
  - FAIL (exit 1) when owner.yaml exists but is schema-invalid

Asset types and resolution rules:
  - apis/<name>/          — owner.yaml directly in the directory
  - terraform/<provider>/ — one per provider (not per version)
  - skills/<name>/        — hierarchical: walks up to skills/ root, uses nearest owner.yaml

Usage:
    python3 scripts/build/validate_ownership.py [repo_root]
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import List, Optional, Tuple

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: PyYAML is required. Install with: pip install pyyaml")
    sys.exit(2)

try:
    from jsonschema import Draft7Validator
except ImportError:  # pragma: no cover
    print("ERROR: jsonschema is required. Install with: pip install jsonschema")
    sys.exit(2)


def _repo_root_from_script(script: Path) -> Path:
    return script.resolve().parents[2]


def _load_schema(repo_root: Path) -> Draft7Validator:
    schema_path = repo_root / 'docs' / 'schemas' / 'owner.schema.json'
    if not schema_path.exists():
        print(f"ERROR: Schema not found at {schema_path}")
        sys.exit(2)
    import json
    with schema_path.open('r', encoding='utf-8') as f:
        schema = json.load(f)
    return Draft7Validator(schema)


def _validate_owner_yaml(path: Path, validator: Draft7Validator) -> List[str]:
    try:
        data = yaml.safe_load(path.read_text(encoding='utf-8'))
    except yaml.YAMLError as e:
        return [f"YAML parse error: {e}"]
    except OSError as e:
        return [f"Read error: {e}"]

    if data is None:
        return ["File is empty."]
    if not isinstance(data, dict):
        return [f"Top-level value must be a mapping, got {type(data).__name__}."]

    errors: List[str] = []
    for err in validator.iter_errors(data):
        pointer = '/'.join(str(p) for p in err.absolute_path) or '<root>'
        errors.append(f"{pointer}: {err.message}")
    return errors


def _resolve_skill_owner(skill_dir: Path, skills_root: Path) -> Optional[Path]:
    """Walk up from skill_dir to skills_root, return nearest owner.yaml."""
    current = skill_dir
    while True:
        candidate = current / 'owner.yaml'
        if candidate.exists():
            return candidate
        if current == skills_root:
            return None
        current = current.parent


def _discover_assets(repo_root: Path) -> List[Tuple[str, Path, Optional[Path]]]:
    """
    Returns list of (asset_label, asset_dir, owner_yaml_path_or_None).
    owner_yaml_path is None when the file is missing (violation).
    """
    assets: List[Tuple[str, Path, Optional[Path]]] = []

    # APIs
    apis_dir = repo_root / 'apis'
    if apis_dir.exists():
        for api_dir in sorted(apis_dir.iterdir()):
            if not api_dir.is_dir() or api_dir.name.startswith('.'):
                continue
            owner = api_dir / 'owner.yaml'
            assets.append((f"apis/{api_dir.name}", api_dir, owner if owner.exists() else None))

    # Terraform providers (one level only — provider dirs, not version subdirs)
    terraform_dir = repo_root / 'terraform'
    if terraform_dir.exists():
        for provider_dir in sorted(terraform_dir.iterdir()):
            if not provider_dir.is_dir() or provider_dir.name.startswith('.'):
                continue
            owner = provider_dir / 'owner.yaml'
            assets.append((f"terraform/{provider_dir.name}", provider_dir, owner if owner.exists() else None))

    # Skills — hierarchical resolution
    skills_dir = repo_root / 'skills'
    if skills_dir.exists():
        for skill_dir in sorted(skills_dir.iterdir()):
            if not skill_dir.is_dir() or skill_dir.name.startswith('.'):
                continue
            # Skip non-skill directories (e.g. files at top level)
            skill_md = skill_dir / 'SKILL.md'
            if not skill_md.exists():
                continue
            owner = _resolve_skill_owner(skill_dir, skills_dir)
            assets.append((f"skills/{skill_dir.name}", skill_dir, owner))

    return assets


def main(argv: List[str]) -> int:
    repo_root = Path(argv[1]).resolve() if len(argv) > 1 else _repo_root_from_script(Path(__file__))

    validator = _load_schema(repo_root)
    assets = _discover_assets(repo_root)

    if not assets:
        print("No assets found — nothing to validate.")
        return 0

    print(f"Validating ownership for {len(assets)} asset(s)...")
    print("=" * 60)

    # (label, errors, is_warning)
    results: List[Tuple[str, List[str], bool]] = []

    for label, _asset_dir, owner_path in assets:
        if owner_path is None:
            # Missing = warn only (gradual adoption)
            results.append((label, ["missing owner.yaml"], True))
        else:
            errors = _validate_owner_yaml(owner_path, validator)
            if errors:
                rel = owner_path.relative_to(repo_root)
                errors = [f"{rel}: {e}" for e in errors]
            results.append((label, errors, False))

    warnings = [(l, e) for l, e, warn in results if warn]
    schema_errors = [(l, e) for l, e, warn in results if not warn and e]

    for label, errors in schema_errors:
        print(f"\n❌ {label}")
        for msg in errors:
            print(f"   • {msg}")

    if warnings:
        print(f"\n⚠️  {len(warnings)} asset(s) without owner.yaml (add to enable routing):")
        for label, _ in warnings:
            print(f"   • {label}")

    owned = sum(1 for _, e, warn in results if not warn and not e)
    print()
    print("=" * 60)
    if schema_errors:
        total_violations = sum(len(e) for _, e in schema_errors)
        print(f"❌ {total_violations} schema violation(s) across {len(schema_errors)} asset(s)")
        return 1

    print(f"✅ {owned} asset(s) with valid ownership", end="")
    if warnings:
        print(f", {len(warnings)} without owner.yaml (warnings only)")
    else:
        print()
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
