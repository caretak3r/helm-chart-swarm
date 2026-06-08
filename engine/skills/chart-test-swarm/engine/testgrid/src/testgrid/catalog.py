"""Generate a deterministic catalog artifact from the scenarios tree.

The catalog maps ``category → integration/capability → [scenario entries]``.
Each entry references the scenario's canonical YAML path and an
applied-overrides locator.  Ordering is lexicographically stable;
regeneration yields byte-identical output (modulo a single timestamp line).

Reads:
  <scenarios_dir>/<category>/<scenario>.yaml   (scenario YAML files)

Optionally reads:
  <reports_dir>/run-*/scenario-*/artifacts/applied-overrides.yaml
  (to resolve the overrides reference for scenarios that have been run)

Emits:
  A plain dict representing the catalog, suitable for ``catalog_to_yaml()``.
"""

from __future__ import annotations

import sys
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import yaml

# Sentinel value for scenarios that have never been run.
NOT_YET_RUN: str = "not-yet-run"

# Special key used for scenarios that have a category but lack both
# integration and capability fields.
_UNCATEGORIZED_INTEGRATION: str = "_uncategorized"


def _load_yaml(path: Path) -> dict[str, Any] | None:
    """Safely load a YAML file, returning None on parse errors."""
    try:
        with path.open(encoding="utf-8") as f:
            doc = yaml.safe_load(f)
        if isinstance(doc, dict):
            return doc
    except yaml.YAMLError as exc:
        print(f"warn: skipping malformed {path}: {exc}", file=sys.stderr)
    return None


def _discover_scenario_files(scenarios_dir: Path) -> list[Path]:
    """Recursively discover all ``*.yaml`` files under *scenarios_dir*.

    Returns paths sorted lexicographically for deterministic ordering.
    Only files inside subdirectories (category dirs) are discovered;
    stray files at the top level are ignored.
    """
    files: list[Path] = []
    for p in sorted(scenarios_dir.rglob("*.yaml")):
        if p.is_file() and p.parent != scenarios_dir:
            files.append(p)
    return files


def _infer_category(scenario_path: Path, scenarios_dir: Path, doc: dict[str, Any]) -> str:
    """Determine the category for a scenario.

    Priority:
      1. Explicit ``category`` field in the YAML.
      2. Parent directory name (category subdir convention).
    """
    explicit = doc.get("category")
    if isinstance(explicit, str) and explicit:
        return explicit
    # Fall back to the parent directory name
    try:
        rel = scenario_path.relative_to(scenarios_dir)
        # rel = category/file.yaml  →  parts[0] = category
        return rel.parts[0]
    except ValueError:
        return "unknown"


def _infer_integration_key(doc: dict[str, Any]) -> str:
    """Determine the integration/capability grouping key.

    Priority:
      1. ``integration`` field (for integration scenarios).
      2. ``capability`` field (for capability scenarios).
      3. ``_UNCATEGORIZED_INTEGRATION`` sentinel.
    """
    integration = doc.get("integration")
    if isinstance(integration, str) and integration:
        return integration
    capability = doc.get("capability")
    if isinstance(capability, str) and capability:
        return capability
    return _UNCATEGORIZED_INTEGRATION


def _find_overrides_ref(
    scenario_id: str,
    reports_dir: Path | None,
) -> str | None:
    """Resolve the applied-overrides reference for a scenario.

    Walks ``reports/run-*`` directories looking for an ``artifacts/``
    bundle containing ``applied-overrides.yaml`` for the given scenario id.

    Returns the relative path from *reports_dir* to the overrides file,
    or ``None`` (which is serialized as ``not-yet-run``) when no run
    artifacts exist.
    """
    if reports_dir is None or not reports_dir.is_dir():
        return None

    # Search for the latest run that contains overrides for this scenario.
    # Walk runs in reverse chronological order (sorted by name, newest first).
    run_dirs = sorted(
        (p for p in reports_dir.iterdir() if p.is_dir() and p.name.startswith("run-")),
        key=lambda p: p.name,
        reverse=True,
    )

    for run_dir in run_dirs:
        # Layout 1: reports/run-X/scenario-<id>/artifacts/applied-overrides.yaml
        overrides = run_dir / f"scenario-{scenario_id}" / "artifacts" / "applied-overrides.yaml"
        if overrides.is_file():
            return str(overrides.relative_to(reports_dir))

        # Layout 2: reports/run-X/agent-N/artifacts/applied-overrides.yaml
        # (multi-agent dispatch format)
        for agent_dir in sorted(run_dir.glob("agent-*")):
            overrides = agent_dir / "artifacts" / "applied-overrides.yaml"
            if overrides.is_file():
                # Verify this agent's artifacts correspond to our scenario
                scenario_yaml = agent_dir / "artifacts" / "scenario.yaml"
                if scenario_yaml.is_file():
                    doc = _load_yaml(scenario_yaml)
                    if doc and doc.get("id") == scenario_id:
                        return str(overrides.relative_to(reports_dir))

    return None


def generate_catalog(
    scenarios_dir: Path,
    reports_dir: Path | None = None,
) -> dict[str, dict[str, list[dict[str, Any]]]]:
    """Walk the scenarios tree and build a catalog dict.

    Returns a mapping::

        {
            category: {
                integration_or_capability: [
                    {
                        "id": str,
                        "path": str,          # relative path from scenarios_dir
                        "name": str,
                        "tier": str | None,
                        "overrides": str | None,  # relative path from reports_dir or None
                    },
                    ...
                ],
            },
        }

    All keys and lists are lexicographically sorted for determinism.
    """
    if not scenarios_dir.is_dir():
        return {}

    scenario_files = _discover_scenario_files(scenarios_dir)

    # Bucket: (category, integration_key) → list of entries
    buckets: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)

    for scenario_path in scenario_files:
        doc = _load_yaml(scenario_path)
        if doc is None:
            continue

        # Require an id field — skip files that aren't valid scenarios.
        scenario_id = doc.get("id")
        if not isinstance(scenario_id, str) or not scenario_id:
            continue

        category = _infer_category(scenario_path, scenarios_dir, doc)
        integration_key = _infer_integration_key(doc)

        # Relative path from scenarios_dir to the scenario file.
        rel_path = str(scenario_path.relative_to(scenarios_dir))

        # Resolve overrides reference.
        overrides_ref = _find_overrides_ref(scenario_id, reports_dir)

        entry: dict[str, Any] = {
            "id": scenario_id,
            "path": rel_path,
            "name": doc.get("name", ""),
            "tier": doc.get("tier"),
            "overrides": overrides_ref,
        }

        buckets[(category, integration_key)].append(entry)

    # Build the output dict with lexicographic sorting at all levels.
    catalog: dict[str, dict[str, list[dict[str, Any]]]] = {}
    for cat, integ in sorted(buckets.keys()):
        entries = sorted(buckets[(cat, integ)], key=lambda e: e["id"])
        catalog.setdefault(cat, {})[integ] = entries

    # Sort each category's integration keys.
    for cat in catalog:
        catalog[cat] = dict(sorted(catalog[cat].items()))

    return dict(sorted(catalog.items()))


def catalog_to_yaml(
    catalog: dict[str, dict[str, list[dict[str, Any]]]],
) -> str:
    """Serialize the catalog dict to a deterministic YAML string.

    The first line is a ``# Generated at <ISO-8601>`` comment that
    changes on every invocation.  All subsequent lines are stable
    (lexicographically ordered, no dict-iteration-dependent output).
    """
    timestamp = datetime.now(tz=UTC).isoformat()
    header = f"# Generated at {timestamp}\n"

    # Build the YAML-serializable structure, replacing None overrides
    # with the sentinel string for clarity.
    serializable: dict[str, dict[str, list[dict[str, Any]]]] = {}
    for cat, integrations in catalog.items():
        serializable[cat] = {}
        for integ, entries in integrations.items():
            serializable[cat][integ] = []
            for entry in entries:
                flat_entry: dict[str, Any] = {
                    "id": entry["id"],
                    "path": entry["path"],
                    "name": entry.get("name", ""),
                    "tier": entry.get("tier"),
                    "overrides": (
                        entry.get("overrides")
                        if entry.get("overrides") is not None
                        else NOT_YET_RUN
                    ),
                }
                serializable[cat][integ].append(flat_entry)

    body = yaml.dump(
        serializable,
        default_flow_style=False,
        sort_keys=True,
        allow_unicode=True,
        explicit_start=False,
    )
    return header + body
