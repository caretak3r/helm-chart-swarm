"""``chart-test-swarm list`` subcommand — walk integrations and variants.

``list integrations`` walks ``engine/skills/chart-test-swarm/references/integrations/<category>/``
and emits one line per primer (category + integration) in sorted order.

``list variants`` walks scenario YAML directories and prints matching file paths,
optionally filtered by ``--integration <name>``.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import NoReturn


def _die(msg: str, code: int = 1) -> NoReturn:
    """Print *msg* to stderr and exit with *code*."""
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def _debug(msg: str) -> None:
    """Print a debug trace line to stderr when ``CTS_DEBUG`` is set."""
    if os.environ.get("CTS_DEBUG", "").strip() in ("1", "true", "yes"):
        print(f"[cts debug] {msg}", file=sys.stderr)


def _resolve_integrations_root(explicit: str | None = None) -> Path:
    """Return the absolute path to the integrations root directory.

    Resolution order:
      1. *explicit* (--root flag, for testing)
      2. ``CTS_INTEGRATIONS_ROOT`` env var
      3. Walk up from this source file to the repo root
    """
    if explicit:
        return Path(explicit).resolve()

    env_override = os.environ.get("CTS_INTEGRATIONS_ROOT")
    if env_override:
        return Path(env_override).resolve()

    # Walk up from src/chart_test_swarm/commands/list_cmd.py
    #   → chart_test_swarm/ → src/ → testgrid/ → engine/ → repo root
    this_file = Path(__file__).resolve()
    engine_dir = this_file.parents[3]  # commands → chart_test_swarm → src → testgrid
    root_dir = engine_dir.parents[1]  # testgrid → engine → root
    return root_dir / "engine" / "skills" / "chart-test-swarm" / "references" / "integrations"


def _resolve_scenarios_dir(explicit: str | None = None) -> Path:
    """Return the absolute path to the scenarios directory.

    Resolution order:
      1. *explicit* (--scenarios-dir flag, for testing)
      2. ``CTS_SCENARIOS_DIR`` env var
      3. Walk up from this source file to find examples/sample-product-chart/chart-test/scenarios
    """
    if explicit:
        return Path(explicit).resolve()

    env_override = os.environ.get("CTS_SCENARIOS_DIR")
    if env_override:
        return Path(env_override).resolve()

    # Walk up from src/chart_test_swarm/commands/list_cmd.py
    this_file = Path(__file__).resolve()
    engine_dir = this_file.parents[3]
    root_dir = engine_dir.parents[1]
    return root_dir / "examples" / "sample-product-chart" / "chart-test" / "scenarios"


# ── Helpers for consumer-primer layering ──────────────────────────────────


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


def _collect_primer_entries(root: Path) -> list[tuple[str, str]]:
    """Collect (category, integration) tuples from a primer tree."""
    entries: list[tuple[str, str]] = []
    if not root.is_dir():
        return entries
    for category_dir in sorted(root.iterdir()):
        if not category_dir.is_dir():
            continue
        category = category_dir.name
        for primer_file in sorted(category_dir.iterdir()):
            if not primer_file.is_file():
                continue
            if primer_file.suffix != ".md":
                continue
            integration = primer_file.stem
            entries.append((category, integration))
    return entries


# ── list integrations ──────────────────────────────────────────────────────


def list_integrations(
    *,
    root: str | None = None,
    project_dir: str | None = None,
) -> None:
    """Walk the integrations directory and print one line per primer.

    Output format: ``{category}  {integration}`` (tab-separated, sorted).
    When *project_dir* is provided, consumer primers from
    ``chart-test/primers/`` are merged with engine primers (consumer
    preferred — consumer entries appear first and engine duplicates are
    removed).

    Exits non-zero if zero categories are found.
    """
    integrations_root = _resolve_integrations_root(root)
    consumer_root = _resolve_consumer_primers_root(project_dir)

    _debug(f"Integrations root: {integrations_root}")
    _debug(f"Consumer primers root: {consumer_root}")

    if not integrations_root.is_dir():
        _die(
            f"ERROR: integrations directory not found: {integrations_root}\n"
            f"       Use --root to specify a custom path.",
            code=1,
        )

    # Collect engine entries
    engine_entries = _collect_primer_entries(integrations_root)

    # Collect consumer entries (only when a consumer tree exists)
    consumer_entries: list[tuple[str, str]] = []
    if consumer_root is not None:
        consumer_entries = _collect_primer_entries(consumer_root)

    # Merge: consumer-preferred (consumer entries first, then engine entries
    # that are not duplicated by a consumer entry)
    consumer_set = set(consumer_entries)
    merged = list(consumer_entries)  # already sorted from _collect_primer_entries
    for entry in engine_entries:
        if entry not in consumer_set:
            merged.append(entry)

    if not merged:
        _die(
            "ERROR: no integrations found — the integrations tree appears empty.\n"
            f"       Searched: {integrations_root}",
            code=1,
        )

    # Print merged list (already sorted: consumer entries first, then
    # non-overlapping engine entries, both alphabetically within group)
    for category, integration in merged:
        print(f"{category}\t{integration}")


# ── list variants ──────────────────────────────────────────────────────────


def list_variants(
    *,
    integration: str | None = None,
    scenarios_dir: str | None = None,
) -> None:
    """List scenario variant YAML paths, optionally filtered by integration name.

    Searches ``examples/*/scenarios/`` recursively for ``.yaml`` and ``.yml`` files.
    When *integration* is given, only files whose stem contains the integration
    name (case-insensitive) are emitted.

    Exits non-zero if zero variants are found.
    """
    scn_dir = _resolve_scenarios_dir(scenarios_dir)

    _debug(f"Scenarios dir: {scn_dir}")
    if integration:
        _debug(f"Filtering by integration: {integration}")

    if not scn_dir.is_dir():
        _die(
            f"ERROR: scenarios directory not found: {scn_dir}\n"
            f"       Use --scenarios-dir to specify a custom path.",
            code=1,
        )

    matched: list[Path] = []
    integration_lower = integration.lower() if integration else None

    for yaml_file in sorted(scn_dir.rglob("*.yaml")):
        if not yaml_file.is_file():
            continue
        if integration_lower and integration_lower not in yaml_file.stem.lower():
            continue
        matched.append(yaml_file)

    for yml_file in sorted(scn_dir.rglob("*.yml")):
        if not yml_file.is_file():
            continue
        if integration_lower and integration_lower not in yml_file.stem.lower():
            continue
        matched.append(yml_file)

    if not matched:
        msg = "ERROR: no scenario variants found"
        if integration:
            msg += f" matching integration '{integration}'"
        msg += f" in {scn_dir}"
        _die(msg, code=1)

    for path in matched:
        print(str(path))
