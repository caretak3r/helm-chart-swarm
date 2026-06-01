"""``chart-test-swarm run`` subcommand — wrap dispatch-swarm.sh.

Flags map to engine-script env vars via :data:`chart_test_swarm.flags.FLAG_TO_ENV`.
Cluster-name prefix is enforced at the CLI layer before any subprocess dispatch.
"""

from __future__ import annotations

import datetime as _dt_module
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

from chart_test_swarm.flags import (
    CLUSTER_NAME_PATTERN,
    FLAG_TO_ENV,  # noqa: F401 — documented mapping for VAL-CLI-022
    SUPPORTED_BACKENDS,
)

# ── Helpers ──────────────────────────────────────────────────────────────────


def _die(msg: str, code: int = 1) -> NoReturn:
    """Print *msg* to stderr and exit with *code*."""
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def _warn(msg: str) -> None:
    """Print a non-fatal warning to stderr."""
    print(f"WARNING: {msg}", file=sys.stderr)


def _debug(msg: str) -> None:
    """Print a debug trace line to stderr when ``CTS_DEBUG`` is set."""
    if os.environ.get("CTS_DEBUG", "").strip() in ("1", "true", "yes"):
        print(f"[cts debug] {msg}", file=sys.stderr)


def _resolve_engine_script(name: str) -> Path:
    """Return the absolute path to ``engine/scripts/<name>``.

    Resolution order:
      1. ``CTS_ENGINE_SCRIPTS_DIR`` env var (for testing with stubs)
      2. Walk up from this source file to the repo root
    """
    env_override = os.environ.get("CTS_ENGINE_SCRIPTS_DIR")
    if env_override:
        return Path(env_override) / name

    # Walk up from src/chart_test_swarm/commands/run_cmd.py
    #   → chart_test_swarm/ → src/ → testgrid/ → engine/ → repo root
    this_file = Path(__file__).resolve()
    engine_dir = this_file.parents[3]  # commands → chart_test_swarm → src → testgrid
    root_dir = engine_dir.parents[1]  # testgrid → engine → root
    return root_dir / "engine" / "scripts" / name


def _resolve_project_dir(explicit: str | None) -> Path:
    """Return the absolute project directory.

    Precedence: *explicit* > ``PROJECT_DIR`` env > current working directory.
    """
    if explicit:
        return Path(explicit).resolve()
    if os.environ.get("PROJECT_DIR"):
        return Path(os.environ["PROJECT_DIR"]).resolve()
    return Path.cwd()


def _generate_run_id() -> str:
    """Generate a unique run id matching ``^run-[0-9]{8}-[0-9]{6}$``."""
    ts = _dt_module.datetime.now(tz=_dt_module.UTC).strftime("%Y%m%d-%H%M%S")
    pid = os.getpid()
    return f"run-{ts}-{pid}"


def _validate_cluster_name(name: str) -> None:
    """Enforce the cluster-name prefix before any subprocess dispatch (VAL-CLI-014).

    Raises SystemExit on mismatch.
    """
    if not re.match(CLUSTER_NAME_PATTERN, name):
        _die(
            f"ERROR: CLUSTER_NAME='{name}' does not match required pattern "
            f"{CLUSTER_NAME_PATTERN}\n"
            f"       All cluster names must carry the chart-test-swarm- prefix "
            f"with a non-empty suffix.\n"
            f"       Example valid names: chart-test-swarm-test1, "
            f"chart-test-swarm-pr-42",
            code=1,
        )


def _validate_backend(backend: str | None) -> None:
    """Ensure *backend* is in the supported enum (VAL-CLI-009).

    Raises SystemExit on unknown value.
    """
    if backend is None:
        return
    if backend not in SUPPORTED_BACKENDS:
        hint = " | ".join(SUPPORTED_BACKENDS)
        _die(
            f"ERROR: unknown backend '{backend}'. Supported: {hint}",
            code=1,
        )


def _validate_parallelism(value: str | None) -> int:
    """Validate and coerce *--parallelism* to a positive integer (VAL-CLI-010).

    Returns the integer value.  Raises SystemExit on invalid input.
    """
    if value is None:
        return 2  # default

    try:
        n = int(value)
    except ValueError:
        _die(
            f"ERROR: --parallelism must be a positive integer, got '{value}'",
            code=1,
        )
    if n < 1:
        _die(
            f"ERROR: --parallelism must be >= 1, got {n}",
            code=1,
        )
    return n


def _validate_scenario_file(path_str: str) -> Path:
    """Verify the scenario file exists (VAL-CLI-019).

    Returns the resolved :class:`Path`.  Exits non-zero with a clear error
    message (no Python traceback) when the file is missing.
    """
    path = Path(path_str).expanduser().resolve()
    if not path.exists():
        _die(
            f"ERROR: scenario file not found: {path_str}\n       (resolved to: {path})",
            code=1,
        )
    if not path.is_file():
        _die(
            f"ERROR: path exists but is not a file: {path_str}\n       (resolved to: {path})",
            code=1,
        )
    return path


def _find_scenarios_by_integration(project_dir: Path, integration: str) -> list[Path]:
    """Walk the project's scenarios directory and return files whose path
    contains *integration* (case-insensitive match on the stem).

    Raises SystemExit with a "no scenarios matched" message if zero files match.
    """
    # Determine scenarios dir from chart-test-swarm.yaml or default
    config = project_dir / "chart-test-swarm.yaml"
    if config.exists():
        import yaml as _yaml_lib

        with open(config) as fh:
            cfg = _yaml_lib.safe_load(fh) or {}
        scenarios_rel = cfg.get("scenarios_dir", "chart-test/scenarios")
    else:
        scenarios_rel = "chart-test/scenarios"

    scn_dir = (project_dir / scenarios_rel).resolve()
    if not scn_dir.is_dir():
        _die(
            f"ERROR: scenarios directory not found: {scn_dir}",
            code=1,
        )

    # Collect .yaml/.yml files whose stem contains the integration name
    matched: list[Path] = []
    integration_lower = integration.lower()
    for f in sorted(scn_dir.rglob("*.yaml")):
        if f.is_file() and integration_lower in f.stem.lower():
            matched.append(f)
    for f in sorted(scn_dir.rglob("*.yml")):
        if f.is_file() and integration_lower in f.stem.lower():
            matched.append(f)

    if not matched:
        _die(
            f"ERROR: no scenarios matched integration '{integration}' in {scn_dir}",
            code=1,
        )
    return matched


def _build_env(
    *,
    backend: str | None,
    parallelism: int,
    cluster_name: str,
    run_id: str,
    reports_dir: str | None,
    project_dir: Path,
    suite: str | None,
    include_cloud_native: bool = False,
) -> dict[str, str]:
    """Build the environment dict for the subprocess call.

    Returns a copy of ``os.environ`` with CLI-supplied values overlaid.
    """
    env = os.environ.copy()

    env["PROVIDER"] = backend or "kind"
    env["NUM_AGENTS"] = str(parallelism)
    env["CLUSTER_NAME"] = cluster_name
    env["RUN_ID"] = run_id
    env["PROJECT_DIR"] = str(project_dir)
    env["CTS_INCLUDE_CLOUD_NATIVE"] = "1" if include_cloud_native else "0"
    if suite:
        env["SUITE"] = suite
    if reports_dir:
        env["REPORTS_DIR"] = reports_dir

    _debug(f"PROVIDER={env['PROVIDER']}")
    _debug(f"NUM_AGENTS={env['NUM_AGENTS']}")
    _debug(f"CLUSTER_NAME={env['CLUSTER_NAME']}")
    _debug(f"RUN_ID={env['RUN_ID']}")
    _debug(f"PROJECT_DIR={env['PROJECT_DIR']}")
    _debug(f"CTS_INCLUDE_CLOUD_NATIVE={env['CTS_INCLUDE_CLOUD_NATIVE']}")
    if suite:
        _debug(f"SUITE={env['SUITE']}")
    if reports_dir:
        _debug(f"REPORTS_DIR={env['REPORTS_DIR']}")

    return env


def _call_dispatch(
    script: Path,
    scenarios: list[Path],
    *,
    backend: str | None,
    parallelism: int,
    cluster_name: str,
    run_id: str,
    reports_dir: str | None,
    project_dir: Path,
    suite: str | None,
    include_cloud_native: bool = False,
) -> int:
    """Call ``dispatch-swarm.sh`` via subprocess.

    Captures stdout/stderr and forwards them to the Python process's
    stdout/stderr so they appear in CliRunner's captured output.
    Returns the exit code of the subprocess.
    """
    env = _build_env(
        backend=backend,
        parallelism=parallelism,
        cluster_name=cluster_name,
        run_id=run_id,
        reports_dir=reports_dir,
        project_dir=project_dir,
        suite=suite,
        include_cloud_native=include_cloud_native,
    )

    # Pass scenario list via CTS_SCENARIOS (newline-separated)
    env["CTS_SCENARIOS"] = "\n".join(str(s) for s in scenarios)

    _debug(f"CTS_SCENARIOS={env['CTS_SCENARIOS']!r}")
    _debug(f"Invoking: bash {script} {project_dir} ...")

    # Build the command line
    cmd = [
        "bash",
        str(script),
        str(project_dir),
        suite or "pr-subset",
        str(parallelism),
        run_id,
    ]

    _debug(f"CMD: {' '.join(cmd)}")

    result = subprocess.run(
        cmd,
        env=env,
        capture_output=True,
        text=True,
    )

    # Forward subprocess output to Python stdout/stderr so CliRunner captures it
    if result.stdout:
        sys.stdout.write(result.stdout)
        sys.stdout.flush()
    if result.stderr:
        sys.stderr.write(result.stderr)
        sys.stderr.flush()

    return result.returncode


# ── Run command entry point ──────────────────────────────────────────────────


def run(
    *,
    scenario: str | None = None,
    integration: str | None = None,
    backend: str | None = None,
    parallelism: str | None = None,
    cluster_name: str = "chart-test-swarm-default",
    run_id: str | None = None,
    reports_dir: str | None = None,
    project_dir: str | None = None,
    suite: str | None = None,
    include_cloud_native: bool = False,
) -> None:
    """Run scenarios against a Kubernetes cluster.

    Wraps ``engine/scripts/dispatch-swarm.sh`` with type-safe flags,
    input validation, and cluster-name prefix enforcement.
    """
    # ── 1. Validate inputs ──────────────────────────────────────────────
    resolved_run_id = run_id or _generate_run_id()
    resolved_parallelism = _validate_parallelism(parallelism)

    _validate_backend(backend)

    # Cluster-name prefix enforcement (VAL-CLI-014)
    _validate_cluster_name(cluster_name)

    # Project dir
    resolved_project_dir = _resolve_project_dir(project_dir)

    # ── 2. Resolve scenario list ────────────────────────────────────────
    script = _resolve_engine_script("dispatch-swarm.sh")
    if not script.is_file():
        # Try to find it - useful for tests that shim PATH
        resolved = _resolve_via_path("dispatch-swarm.sh")
        if resolved:
            script = resolved
        else:
            _die(f"ERROR: dispatch-swarm.sh not found at {script}", code=1)

    scenarios: list[Path]
    if scenario is not None:
        # Single scenario mode (VAL-CLI-007)
        scenario_path = _validate_scenario_file(scenario)
        scenarios = [scenario_path]
    elif integration is not None:
        # Filter by integration name (VAL-CLI-008)
        scenarios = _find_scenarios_by_integration(resolved_project_dir, integration)
    else:
        # Suite mode — let dispatch-swarm.sh resolve scenarios from tags
        scenarios = []

    # ── 3. Dispatch ─────────────────────────────────────────────────────
    rc = _call_dispatch(
        script,
        scenarios,
        backend=backend,
        parallelism=resolved_parallelism,
        cluster_name=cluster_name,
        run_id=resolved_run_id,
        reports_dir=reports_dir,
        project_dir=resolved_project_dir,
        suite=suite,
        include_cloud_native=include_cloud_native,
    )

    # ── 4. Emit RUN_ID as last line of stdout (VAL-CLI-018) ─────────────
    print(resolved_run_id, flush=True)

    if rc != 0:
        _die(f"dispatch-swarm.sh exited with code {rc}", code=rc)


def _resolve_via_path(name: str) -> Path | None:
    """Search for *name* on ``PATH`` (used for stub-based testing)."""
    for d in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(d) / name
        if candidate.is_file():
            return candidate
    return None
