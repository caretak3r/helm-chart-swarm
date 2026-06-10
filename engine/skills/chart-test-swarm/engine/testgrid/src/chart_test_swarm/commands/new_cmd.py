"""``chart-test-swarm new`` subcommand — scaffold integration and capability tests.

``new <category>/<integration>`` scaffolds fixture values + scenario YAML +
executable smoke assert under the located chart-test/ tree without modifying
the chart's values.yaml.  Integration mode requires a primer file.

``new capability/<name>`` scaffolds fixture + scenario wired to an addon-less
capability assert with no preinstall.  Capability mode has no primer
requirement.

Enforces: taxonomy-correct category, schema-valid output, tier defaults
(integration→live, capability→capability, cloud→authored-only), no-primer
refusal listing available primers, no-clobber on existing ids, and --dry-run.
"""

from __future__ import annotations

import os
import stat
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import NoReturn

import yaml

# ── Constants ──────────────────────────────────────────────────────────────

# The canonical taxonomy of integration categories, derived from the
# references/integrations/ directory structure plus the pseudo-category
# "capability" which has no primer directory.
TAXONOMY_CATEGORIES: set[str] = {
    "certificates",
    "cloud-native",
    "gateway-api",
    "ingress-controllers",
    "networking",
    "policy",
    "service-mesh",
    "storage",
}

# Pseudo-category for addon-less capability/compliance tests.
CAPABILITY_PSEUDO_CATEGORY = "capability"

# Tier defaults per kind of test.
TIER_DEFAULTS: dict[str, str] = {
    "integration": "live",
    "capability": "capability",
    "cloud-native": "authored-only",
}

# The §10.4 capability assert types (for scaffolding capability scenarios).
CAPABILITY_ASSERT_TYPES: list[str] = [
    "labels-present",
    "annotations-present",
    "scheme-enforced",
    "rbac-objects",
    "security-context",
    "network-policy",
    "resources-present",
    "imagepullsecrets-present",
    "serviceaccount-annotations",
    "scheduling-present",
    "priority-class-present",
]

# The default capability assert type used when scaffolding.
DEFAULT_CAPABILITY_ASSERT_TYPE = "labels-present"


# ── Helpers ────────────────────────────────────────────────────────────────


def _die(msg: str, code: int = 1) -> NoReturn:
    """Print *msg* to stderr and exit with *code*."""
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def _debug(msg: str) -> None:
    """Print a debug trace line to stderr when ``CTS_DEBUG`` is set."""
    if os.environ.get("CTS_DEBUG", "").strip() in ("1", "true", "yes"):
        print(f"[cts debug] {msg}", file=sys.stderr)


def _resolve_repo_root() -> Path:
    """Resolve the *real* repo root directory (where the engine/ tree lives).

    Always walks up from this source file, regardless of --project-dir.
    The repo root is where primers, schemas, and the engine live.

    Path: …/chart-test-swarm/engine/testgrid/src/chart_test_swarm/commands/new_cmd.py
           → parents[5] = chart-test-swarm/  (the repo root)
    """
    this_file = Path(__file__).resolve()
    return this_file.parents[5]


def _resolve_integrations_root() -> Path:
    """Resolve the integrations reference directory.

    Always uses the real repo root (where primers live), independent of
    --project-dir, which only controls where scaffolded files are written.
    """
    return (
        _resolve_repo_root()
        / "engine"
        / "skills"
        / "chart-test-swarm"
        / "references"
        / "integrations"
    )


def _resolve_consumer_primers_root(project_dir: str | None = None) -> Path | None:
    """Resolve the consumer-provided primers root directory.

    Consumer primers live at ``$PROJECT_DIR/chart-test/primers/``, mirroring
    the engine's ``references/integrations/<category>/<integration>.md``
    structure.  Returns ``None`` when *project_dir* is not provided or the
    ``chart-test/primers/`` directory does not exist.
    """
    if not project_dir:
        return None
    primers_root = Path(project_dir).resolve() / "chart-test" / "primers"
    if not primers_root.is_dir():
        return None
    return primers_root


def _resolve_chart_test_dir(project_dir: str | None = None) -> Path:
    """Resolve the chart-test/ directory where scaffolded files are written.

    If --project-dir is given, looks for chart-test/ directly under it.
    Otherwise, defaults to examples/sample-product-chart/chart-test/ in the
    real repo.
    """
    if project_dir:
        return Path(project_dir).resolve() / "chart-test"

    # Default to examples/sample-product-chart/chart-test/
    return _resolve_repo_root() / "examples" / "sample-product-chart" / "chart-test"


def _discover_categories(integrations_root: Path) -> set[str]:
    """Discover valid integration categories from the directory tree."""
    if not integrations_root.is_dir():
        return set()
    return {
        d.name for d in integrations_root.iterdir() if d.is_dir() and not d.name.startswith(".")
    }


def _primers_for_category(integrations_root: Path, category: str) -> list[str]:
    """List primer stems (integration names) for a given category."""
    cat_dir = integrations_root / category
    if not cat_dir.is_dir():
        return []
    return sorted(f.stem for f in cat_dir.glob("*.md") if f.is_file())


def _primer_exists(integrations_root: Path, category: str, integration: str) -> bool:
    """Check whether a primer .md file exists for the given category+integration."""
    primer_path = integrations_root / category / f"{integration}.md"
    return primer_path.is_file()


def _primers_for_category_merged(
    engine_root: Path,
    consumer_root: Path | None,
    category: str,
) -> list[str]:
    """List primer stems for a category, merging consumer and engine sources.

    Consumer primers take precedence: they appear first in the result and
    engine primers are only appended when no consumer primer with the same
    stem exists.  The result is de-duplicated and sorted for deterministic
    output (consumer entries first, then new engine entries, then
    alphabetically sorted within each group).
    """
    consumer_stems: list[str] = []
    if consumer_root is not None:
        consumer_stems = _primers_for_category(consumer_root, category)

    engine_stems = _primers_for_category(engine_root, category)

    # Consumer-preferred ordering: consumer stems first, then engine stems
    # that are not already covered by a consumer primer.
    consumer_set = set(consumer_stems)
    merged = list(consumer_stems)  # already sorted from _primers_for_category
    for stem in engine_stems:
        if stem not in consumer_set:
            merged.append(stem)

    return merged


def _resolve_primer_path(
    engine_root: Path,
    consumer_root: Path | None,
    category: str,
    integration: str,
) -> Path | None:
    """Resolve the primer path, preferring the consumer over the engine.

    Returns the absolute path to the resolved primer file, or ``None`` when
    the primer exists in neither tree.
    """
    if consumer_root is not None:
        consumer_path = consumer_root / category / f"{integration}.md"
        if consumer_path.is_file():
            _debug(f"Resolved consumer primer: {consumer_path}")
            return consumer_path

    engine_path = engine_root / category / f"{integration}.md"
    if engine_path.is_file():
        _debug(f"Resolved engine primer: {engine_path}")
        return engine_path

    return None


def _determine_tier(category: str, kind: str) -> str:
    """Determine the default tier based on test kind and category.

    - integration → "live" (unless cloud-native → "authored-only")
    - capability → "capability"
    """
    if kind == "capability":
        return TIER_DEFAULTS["capability"]
    if category == "cloud-native":
        return TIER_DEFAULTS["cloud-native"]
    return TIER_DEFAULTS["integration"]


def _now_utc_iso() -> str:
    """Return current UTC time as ISO-8601 string."""
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── Template generation ────────────────────────────────────────────────────


def _generate_integration_scenario(
    *,
    category: str,
    integration: str,
    tier: str,
    fixture_rel: str,
    smoke_rel: str,
) -> str:
    """Generate a scenario YAML for integration mode.

    The scenario includes:
    - Primer-driven cluster.preinstall slot (placeholder for helm chart)
    - smoke-script assert referencing the scaffolded assert path
    - Self-description fields (category, integration, tier)
    """
    scenario_id = f"{category}-{integration}"

    doc: dict[str, object] = {
        "id": scenario_id,
        "name": f"{integration} integration test",
        "description": (
            f"Integration test for {integration} under the {category} category. "
            f"Scaffolded by chart-test-swarm new — customize preinstall, "
            f"product overrides, and assertions as needed."
        ),
        "labels": {"customer": "any", "profile": "integration"},
        "cluster": {
            "provider": "kind",
            "k8s_version": "v1.30.0",
            "preinstall": [
                {
                    "kind": "helm",
                    "chart": f"TODO/{integration}",
                    "version": "TODO",
                    "release": integration,
                    "namespace": integration,
                    "repo": {
                        "name": "TODO",
                        "url": "https://charts.TODO.example.com/",
                    },
                    "wait": "pods-ready",
                    "wait_timeout": "3m",
                }
            ],
        },
        "product": {
            "chart": "./chart",
            "release": "sample",
            "namespace": "sample",
            "values": fixture_rel,
        },
        "asserts": [
            {"type": "helm-status-deployed", "release": "sample", "namespace": "sample"},
            {"type": "pods-ready", "namespace": "sample", "timeout": "3m"},
            {"type": "smoke-script", "path": smoke_rel},
        ],
        "tags": ["pr-subset"],
        "category": category,
        "integration": integration,
        "tier": tier,
        "mechanisms": [f"addon:{integration}"],
        "generated_by": {
            "by": "chart-test-swarm-new",
            "integration": integration,
            "at": _now_utc_iso(),
        },
    }

    return yaml.dump(doc, sort_keys=False, default_flow_style=False, width=200)


def _generate_capability_scenario(
    *,
    capability_name: str,
    tier: str,
    fixture_rel: str,
    assert_type: str = DEFAULT_CAPABILITY_ASSERT_TYPE,
) -> str:
    """Generate a scenario YAML for capability mode.

    The scenario includes:
    - No preinstall (addon-less)
    - A §10.4 capability assert (default: labels-present)
    - Self-description fields (category=capability, capability, tier)
    """
    scenario_id = f"capability-{capability_name}"

    # Build the capability-specific assert block
    capability_assert: dict[str, object] = {
        "type": assert_type,
        "namespace": "sample",
        "source": "rendered",
    }

    # Add the required fields per assert type
    if assert_type == "labels-present":
        capability_assert["labels"] = {"TODO": "custom-label-value"}
    elif assert_type == "annotations-present":
        capability_assert["annotations"] = {"TODO": "custom-annotation-value"}
    elif assert_type == "scheme-enforced":
        capability_assert["scheme"] = "https-only"
    elif assert_type == "rbac-objects" or assert_type in (
        "security-context",
        "network-policy",
        "resources-present",
        "imagepullsecrets-present",
        "scheduling-present",
        "priority-class-present",
    ):
        capability_assert["expect_present"] = True

    doc: dict[str, object] = {
        "id": scenario_id,
        "name": f"Capability: {capability_name}",
        "description": (
            f"Addon-less capability/compliance test for {capability_name}. "
            f"Scaffolded by chart-test-swarm new — customize product "
            f"overrides and assertion parameters as needed."
        ),
        "labels": {"customer": "enterprise", "profile": "compliance"},
        "cluster": {
            "provider": "kind",
            "k8s_version": "v1.30.0",
        },
        "product": {
            "chart": "./chart",
            "release": "sample",
            "namespace": "sample",
            "values": fixture_rel,
        },
        "asserts": [
            {"type": "helm-status-deployed", "release": "sample", "namespace": "sample"},
            {"type": "pods-ready", "namespace": "sample", "timeout": "3m"},
            capability_assert,
        ],
        "tags": ["capability", "compliance"],
        "category": CAPABILITY_PSEUDO_CATEGORY,
        "capability": capability_name,
        "tier": tier,
        "mechanisms": [f"capability:{capability_name}"],
        "generated_by": {
            "by": "chart-test-swarm-new",
            "at": _now_utc_iso(),
        },
    }

    return yaml.dump(doc, sort_keys=False, default_flow_style=False, width=200)


def _generate_fixture_values(
    *,
    kind: str,
    integration: str | None = None,
    capability_name: str | None = None,
) -> str:
    """Generate a fixture values YAML.

    Per VAL-KIT-012, the fixture begins with the chartTestSwarm.enabled gate.
    """
    lines = [
        "# Fixture values scaffolded by chart-test-swarm new.",
        "# The chartTestSwarm.enabled gate ensures helm-test pods only inject",
        "# when the test framework is active.",
        "chartTestSwarm:",
        "  enabled: true",
        "",
    ]

    if kind == "integration" and integration:
        lines.append(f"# Integration: {integration}")
        lines.append("# Add product values overrides below (e.g. tls.enabled: true)")
    elif kind == "capability" and capability_name:
        lines.append(f"# Capability: {capability_name}")
        lines.append("# Add product values overrides below (e.g. extraLabels.team: platform)")
    else:
        lines.append("# Add product values overrides below")

    return "\n".join(lines) + "\n"


def _generate_smoke_script(*, integration: str) -> str:
    """Generate an executable smoke script for integration mode."""
    return f"""#!/usr/bin/env bash
# Smoke-test script for {integration} integration.
# Scaffolded by chart-test-swarm new — customize as needed.
#
# Environment:
#   RELEASE     — Helm release name
#   NAMESPACE   — Kubernetes namespace
#   KUBECONFIG  — Path to kubeconfig

set -euo pipefail

RELEASE="${{RELEASE:-sample}}"
NAMESPACE="${{NAMESPACE:-sample}}"

echo "=== {integration} smoke test ==="
echo "Release: $RELEASE"
echo "Namespace: $NAMESPACE"

# Example: check that the product deployment is available
# kubectl rollout status "deployment/$RELEASE" -n "$NAMESPACE" --timeout=60s

# Example: check that the integration addon is running
# kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" --no-headers

echo "=== {integration} smoke test: TODO — implement actual checks ==="
exit 0
"""


# ── Target parsing ─────────────────────────────────────────────────────────


class ParsedTarget:
    """Parsed target from the new command argument."""

    def __init__(
        self,
        *,
        kind: str,
        category: str,
        name: str,
    ) -> None:
        self.kind = kind  # "integration" or "capability"
        self.category = category
        self.name = name


def _parse_target(target: str) -> ParsedTarget:
    """Parse a target string like 'certificates/cert-manager' or 'capability/my-check'.

    Returns a ParsedTarget with kind, category, and name.
    Raises SystemExit on malformed input.
    """
    parts = target.split("/")

    if len(parts) != 2:
        _die(
            f"ERROR: target must be in the form <category>/<integration> "
            f"or capability/<name>, got: {target!r}",
            code=2,
        )

    category, name = parts

    if not category or not name:
        _die(
            f"ERROR: target category and name must be non-empty, got: {target!r}",
            code=2,
        )

    # Determine kind
    kind = "capability" if category == CAPABILITY_PSEUDO_CATEGORY else "integration"

    return ParsedTarget(kind=kind, category=category, name=name)


# ── Scaffolding logic ───────────────────────────────────────────────────────


def _scaffold_integration(
    *,
    target: ParsedTarget,
    chart_test_dir: Path,
    integrations_root: Path,
    consumer_primers_root: Path | None = None,
    dry_run: bool = False,
    force: bool = False,
    project_dir: str | None = None,
    tier_override: str | None = None,
) -> None:
    """Scaffold integration test files (fixture + scenario + smoke script)."""
    category = target.category
    integration = target.name
    tier = tier_override if tier_override else _determine_tier(category, "integration")

    _debug(f"Integration mode: category={category}, integration={integration}, tier={tier}")
    _debug(f"Consumer primers root: {consumer_primers_root}")

    # Validate category against taxonomy
    discovered = _discover_categories(integrations_root)
    all_valid = TAXONOMY_CATEGORIES | discovered | {CAPABILITY_PSEUDO_CATEGORY}

    if category not in all_valid:
        available = sorted(all_valid)
        _die(
            f"ERROR: unknown category {category!r}.\n"
            f"Available categories: {', '.join(available)}\n"
            f"No files were written.",
            code=1,
        )

    # Check primer existence (merged consumer + engine)
    resolved_primer = _resolve_primer_path(
        integrations_root, consumer_primers_root, category, integration
    )
    if resolved_primer is None:
        available = _primers_for_category_merged(
            integrations_root, consumer_primers_root, category
        )
        if available:
            _die(
                f"ERROR: no primer found for {category}/{integration}.\n"
                f"Available primers in {category}: {', '.join(available)}\n"
                f"No files were written.",
                code=1,
            )
        else:
            _die(
                f"ERROR: no primer found for {category}/{integration}.\n"
                f"No primers exist in category {category!r}.\n"
                f"No files were written.",
                code=1,
            )

    # Compute paths
    fixture_dir = chart_test_dir / "fixtures" / category
    fixture_path = fixture_dir / f"{integration}-values.yaml"
    scenario_dir = chart_test_dir / "scenarios" / category
    scenario_path = scenario_dir / f"{category}-{integration}.yaml"
    smoke_dir = chart_test_dir / "assertions"
    smoke_path = smoke_dir / f"{integration}-smoke.sh"

    # Compute relative paths for use in scenario YAML.
    # When --project-dir is given, the relative path is "chart-test/..."
    # (relative to the project root, which is the parent of chart-test/).
    # Otherwise, it's relative to the repo root.
    if project_dir:
        fixture_rel = f"chart-test/fixtures/{category}/{integration}-values.yaml"
        smoke_rel = f"chart-test/assertions/{integration}-smoke.sh"
    else:
        chart_test_rel = chart_test_dir.relative_to(_resolve_repo_root())
        fixture_rel = str(chart_test_rel / "fixtures" / category / f"{integration}-values.yaml")
        smoke_rel = str(chart_test_rel / "assertions" / f"{integration}-smoke.sh")

    # Check for existing files (no-clobber without --force)
    existing: list[Path] = []
    for p in (fixture_path, scenario_path, smoke_path):
        if p.exists():
            existing.append(p)

    if existing and not force:
        paths_str = "\n  ".join(str(p) for p in existing)
        _die(
            f"ERROR: files already exist for {category}/{integration}:\n"
            f"  {paths_str}\n"
            f"Use --force to overwrite. No files were modified.",
            code=1,
        )

    # Dry-run: just list prospective paths
    if dry_run:
        print("[dry-run] Would scaffold the following files:")
        print(f"  fixture:  {fixture_path}")
        print(f"  scenario: {scenario_path}")
        print(f"  smoke:    {smoke_path}")
        return

    # Generate content
    fixture_content = _generate_fixture_values(kind="integration", integration=integration)
    scenario_content = _generate_integration_scenario(
        category=category,
        integration=integration,
        tier=tier,
        fixture_rel=fixture_rel,
        smoke_rel=smoke_rel,
    )
    smoke_content = _generate_smoke_script(integration=integration)

    # Write files
    fixture_dir.mkdir(parents=True, exist_ok=True)
    fixture_path.write_text(fixture_content)
    _debug(f"Wrote fixture: {fixture_path}")

    scenario_dir.mkdir(parents=True, exist_ok=True)
    scenario_path.write_text(f"---\n{scenario_content}")
    _debug(f"Wrote scenario: {scenario_path}")

    smoke_dir.mkdir(parents=True, exist_ok=True)
    smoke_path.write_text(smoke_content)
    # Make the smoke script executable
    smoke_path.chmod(smoke_path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    _debug(f"Wrote smoke script: {smoke_path}")

    print(f"Scaffolded {category}/{integration}:")
    print(f"  fixture:  {fixture_path}")
    print(f"  scenario: {scenario_path}")
    print(f"  smoke:    {smoke_path}")


def _scaffold_capability(
    *,
    target: ParsedTarget,
    chart_test_dir: Path,
    dry_run: bool = False,
    force: bool = False,
    project_dir: str | None = None,
    assert_type: str | None = None,
    tier_override: str | None = None,
) -> None:
    """Scaffold capability test files (fixture + scenario)."""
    capability_name = target.name
    tier = (
        tier_override
        if tier_override
        else _determine_tier(CAPABILITY_PSEUDO_CATEGORY, "capability")
    )
    effective_assert_type = assert_type or DEFAULT_CAPABILITY_ASSERT_TYPE

    # Validate assert_type if provided
    if assert_type and assert_type not in CAPABILITY_ASSERT_TYPES:
        _die(
            f"ERROR: unknown capability assert type {assert_type!r}.\n"
            f"Available types: {', '.join(CAPABILITY_ASSERT_TYPES)}",
            code=2,
        )

    _debug(f"Capability mode: name={capability_name}, tier={tier}")

    # Compute paths
    fixture_dir = chart_test_dir / "fixtures" / CAPABILITY_PSEUDO_CATEGORY
    fixture_path = fixture_dir / f"{capability_name}-values.yaml"
    scenario_dir = chart_test_dir / "scenarios" / CAPABILITY_PSEUDO_CATEGORY
    scenario_path = scenario_dir / f"capability-{capability_name}.yaml"

    # Compute relative paths for scenario YAML
    if project_dir:
        fixture_rel = (
            f"chart-test/fixtures/{CAPABILITY_PSEUDO_CATEGORY}/{capability_name}-values.yaml"
        )
    else:
        chart_test_rel = chart_test_dir.relative_to(_resolve_repo_root())
        fixture_rel = str(
            chart_test_rel
            / "fixtures"
            / CAPABILITY_PSEUDO_CATEGORY
            / f"{capability_name}-values.yaml"
        )

    # Check for existing files
    existing: list[Path] = []
    for p in (fixture_path, scenario_path):
        if p.exists():
            existing.append(p)

    if existing and not force:
        paths_str = "\n  ".join(str(p) for p in existing)
        _die(
            f"ERROR: files already exist for capability/{capability_name}:\n"
            f"  {paths_str}\n"
            f"Use --force to overwrite. No files were modified.",
            code=1,
        )

    # Dry-run
    if dry_run:
        print("[dry-run] Would scaffold the following files:")
        print(f"  fixture:  {fixture_path}")
        print(f"  scenario: {scenario_path}")
        return

    # Generate content
    fixture_content = _generate_fixture_values(kind="capability", capability_name=capability_name)
    scenario_content = _generate_capability_scenario(
        capability_name=capability_name,
        tier=tier,
        fixture_rel=fixture_rel,
        assert_type=effective_assert_type,
    )

    # Write files
    fixture_dir.mkdir(parents=True, exist_ok=True)
    fixture_path.write_text(fixture_content)
    _debug(f"Wrote fixture: {fixture_path}")

    scenario_dir.mkdir(parents=True, exist_ok=True)
    scenario_path.write_text(f"---\n{scenario_content}")
    _debug(f"Wrote scenario: {scenario_path}")

    print(f"Scaffolded capability/{capability_name}:")
    print(f"  fixture:  {fixture_path}")
    print(f"  scenario: {scenario_path}")


# ── Public entry point ──────────────────────────────────────────────────────


def new_cmd(
    *,
    target: str,
    project_dir: str | None = None,
    force: bool = False,
    dry_run: bool = False,
    tier: str | None = None,
    assert_type: str | None = None,
) -> None:
    """Scaffold a new integration or capability test.

    \b
    TARGET format:
      <category>/<integration>  — Integration mode (requires a primer)
      capability/<name>         — Capability mode (addon-less, no primer needed)

    \b
    Examples:
        chart-test-swarm new certificates/cert-manager
        chart-test-swarm new capability/labels
        chart-test-swarm new certificates/cert-manager --dry-run
        chart-test-swarm new certificates/cert-manager --force
        chart-test-swarm new networking/traefik --tier authored-only
        chart-test-swarm new capability/my-check --assert-type rbac-objects
    """
    # Parse the target
    parsed = _parse_target(target)

    # Validate --tier value if provided
    if tier is not None and tier not in ("live", "authored-only", "capability"):
        _die(
            f"ERROR: invalid tier {tier!r}. Must be one of: live, authored-only, capability",
            code=2,
        )

    # Resolve directories
    # integrations_root: always the real repo's primer tree (independent of --project-dir)
    integrations_root = _resolve_integrations_root()
    # consumer_primers_root: consumer-provided primers (under $PROJECT_DIR/chart-test/primers/)
    consumer_primers_root = _resolve_consumer_primers_root(project_dir)
    # chart_test_dir: where scaffolded files are written
    chart_test_dir = _resolve_chart_test_dir(project_dir)

    if parsed.kind == "capability":
        _scaffold_capability(
            target=parsed,
            chart_test_dir=chart_test_dir,
            dry_run=dry_run,
            force=force,
            project_dir=project_dir,
            assert_type=assert_type,
            tier_override=tier,
        )
    else:
        _scaffold_integration(
            target=parsed,
            chart_test_dir=chart_test_dir,
            integrations_root=integrations_root,
            consumer_primers_root=consumer_primers_root,
            dry_run=dry_run,
            force=force,
            project_dir=project_dir,
            tier_override=tier,
        )
