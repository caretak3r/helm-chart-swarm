"""``chart-test-swarm generate pick`` subcommand — non-interactive selector.

Picks a scenario YAML from (category, integration, variant) tuples by matching
against the scenarios directory. Supports --category/--integration/--variant flags,
stdin JSON/YAML feed, and --output for file capture.

Adds ``generated_by`` provenance with ``by: pick``, no ``cmd``, and an
ISO-8601 UTC timestamp.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import UTC, datetime
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


def _coerce_str(value: object) -> str | None:
    """Safely coerce a value to str or None."""
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return str(value)


def _resolve_scenarios_dir(explicit: str | None = None) -> Path:
    """Return the absolute path to the scenarios directory.

    Resolution order:
      1. *explicit* (--scenarios-dir flag)
      2. ``CTS_SCENARIOS_DIR`` env var
      3. Walk up from this source file to the repo root
    """
    if explicit:
        return Path(explicit).resolve()

    env_override = os.environ.get("CTS_SCENARIOS_DIR")
    if env_override:
        return Path(env_override).resolve()

    # Walk up from src/chart_test_swarm/commands/generate_pick_cmd.py
    #   → commands → chart_test_swarm → src → testgrid → engine → repo root
    this_file = Path(__file__).resolve()
    engine_dir = this_file.parents[3]  # commands → chart_test_swarm → src → testgrid
    root_dir = engine_dir.parents[1]  # testgrid → engine → root
    return root_dir / "examples" / "sample-product-chart" / "chart-test" / "scenarios"


def _resolve_schema_path(explicit: str | None = None) -> Path:
    """Return the absolute path to the scenario schema JSON file."""
    if explicit:
        return Path(explicit).resolve()

    env_override = os.environ.get("CTS_SCHEMA_PATH")
    if env_override:
        return Path(env_override).resolve()

    this_file = Path(__file__).resolve()
    engine_dir = this_file.parents[3]
    root_dir = engine_dir.parents[1]
    return root_dir / "engine" / "templates" / "scenario.schema.json"


def generate_pick(  # noqa: PLR0913
    *,
    category: str | None = None,
    integration: str | None = None,
    variant: str | None = None,
    output: str | None = None,
    force: bool = False,  # noqa: FBT001, FBT002
    non_interactive: bool = False,  # noqa: FBT001
    stdin_feed: str | None = None,
    scenarios_dir: str | None = None,
    schema_path: str | None = None,
) -> None:
    """Pick a scenario YAML from (category, integration, variant) tuples.

    Selection sources (flags take precedence over stdin):
      1. Command-line flags --category, --integration, --variant
      2. *stdin_feed* — JSON or YAML string with keys category, integration, variant

    If neither is provided, exits non-zero with a clear error message.
    """
    # ── resolve selection ──────────────────────────────────────────────────
    sel_category = category
    sel_integration = integration
    sel_variant = variant

    if stdin_feed:
        feed = stdin_feed.strip()
        if feed:
            try:
                data = json.loads(feed)
            except json.JSONDecodeError:
                try:
                    import yaml as _yaml  # noqa: PLC0415

                    data = _yaml.safe_load(feed)
                except Exception as exc:
                    _die(
                        f"ERROR: failed to parse stdin as JSON or YAML: {exc}",
                        code=2,
                    )
            if not isinstance(data, dict):
                _die(
                    "ERROR: stdin must be a JSON/YAML object with keys: "
                    "category, integration, variant",
                    code=2,
                )
            # Flags take precedence over stdin
            if sel_category is None:
                sel_category = _coerce_str(data.get("category"))
            if sel_integration is None:
                sel_integration = _coerce_str(data.get("integration"))
            if sel_variant is None:
                sel_variant = _coerce_str(data.get("variant"))

    # ── validate selection ─────────────────────────────────────────────────
    if not sel_category or not sel_integration or not sel_variant:
        _die(
            "ERROR: no selection provided. Use --category, --integration, --variant flags, "
            "or pipe a JSON/YAML object to stdin with keys: category, integration, variant.",
            code=3,
        )

    _debug(
        f"Selection: category={sel_category}, integration={sel_integration}, variant={sel_variant}"
    )

    # ── find matching scenario ─────────────────────────────────────────────
    scn_dir = _resolve_scenarios_dir(scenarios_dir)
    _debug(f"Scenarios dir: {scn_dir}")

    if not scn_dir.is_dir():
        _die(f"ERROR: scenarios directory not found: {scn_dir}", code=4)

    # Filename pattern: {category}-{integration}-{variant}.yaml
    prefix = f"{sel_category}-{sel_integration}-"

    matches: list[Path] = []
    for yaml_file in sorted(scn_dir.rglob("*.yaml")):
        if not yaml_file.is_file():
            continue
        stem = yaml_file.stem
        if not stem.startswith(prefix):
            continue
        # The variant part is everything after the prefix
        variant_part = stem[len(prefix) :]
        if sel_variant in variant_part:
            matches.append(yaml_file)

    # Also check .yml extension
    for yml_file in sorted(scn_dir.rglob("*.yml")):
        if not yml_file.is_file():
            continue
        stem = yml_file.stem
        if not stem.startswith(prefix):
            continue
        variant_part = stem[len(prefix) :]
        if sel_variant in variant_part:
            matches.append(yml_file)

    if not matches:
        _die(
            f"ERROR: no scenario found for category={sel_category}, "
            f"integration={sel_integration}, variant={sel_variant}",
            code=5,
        )

    if len(matches) > 1:
        _debug(
            f"Multiple matches found: {[str(m.name) for m in matches]}; "
            f"using first: {matches[0].name}"
        )

    scenario_path = matches[0]
    scenario_yaml = scenario_path.read_text()

    _debug(f"Matched scenario: {scenario_path}")

    # ── validate against schema (best-effort) ──────────────────────────────
    schema = _resolve_schema_path(schema_path)
    if schema.exists():
        # Prefer check-jsonschema (supports YAML natively); fall back to
        # skipping validation if check-jsonschema is not found.
        try:
            result = subprocess.run(  # noqa: S603
                [
                    "check-jsonschema",
                    "--schemafile",
                    str(schema),
                    str(scenario_path),
                ],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                _die(
                    f"ERROR: selected scenario does not validate against schema:\n{result.stderr}",
                    code=6,
                )
        except FileNotFoundError:
            _debug("check-jsonschema not found; skipping schema validation")
    else:
        _debug(f"Schema not found at {schema}; skipping validation")

    # ── add generated_by provenance ───────────────────────────────────────
    import yaml as _yaml_lib  # noqa: PLC0415
    try:
        data = _yaml_lib.safe_load(scenario_yaml)
        if isinstance(data, dict):
            # Only add if not already present
            if "generated_by" not in data:
                data["generated_by"] = {
                    "by": "pick",
                    "timestamp": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
                }
            scenario_yaml = _yaml_lib.dump(
                data, default_flow_style=False, sort_keys=False, allow_unicode=True
            )
    except Exception:
        # If we can't parse YAML, emit as-is
        pass

    # ── emit ───────────────────────────────────────────────────────────────
    if output:
        out_path = Path(output).resolve()
        if out_path.exists() and out_path.stat().st_size > 0 and not force:
            _die(
                f"ERROR: {out_path} already exists.\n"
                "  Use --force to overwrite.",
                code=16,
            )
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(scenario_yaml)
        print(f"Scenario written to {out_path}")
    else:
        sys.stdout.write(scenario_yaml)
