"""``chart-test-swarm dashboard`` subcommand — wrap build-dashboard.sh.

Invokes ``engine/scripts/build-dashboard.sh`` via subprocess with typed flags,
forwarding env vars for REPORTS_DIR, PROJECT_DIR, and DASHBOARD_OUT.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

# ── Helpers ──────────────────────────────────────────────────────────────────


def _die(msg: str, code: int = 1) -> NoReturn:
    """Print *msg* to stderr and exit with *code*."""
    print(msg, file=sys.stderr)
    raise SystemExit(code)


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

    # Walk up from src/chart_test_swarm/commands/dashboard_cmd.py
    #   → chart_test_swarm/ → src/ → testgrid/ → engine/ → repo root
    this_file = Path(__file__).resolve()
    engine_dir = this_file.parents[3]  # commands → chart_test_swarm → src → testgrid
    root_dir = engine_dir.parents[1]  # testgrid → engine → root
    return root_dir / "engine" / "scripts" / name


def _resolve_project_dir(explicit: str | None) -> Path | None:
    """Return the absolute project directory, or None if not set."""
    if explicit:
        return Path(explicit).resolve()
    if os.environ.get("PROJECT_DIR"):
        return Path(os.environ["PROJECT_DIR"]).resolve()
    return None


# ── Dashboard command entry point ────────────────────────────────────────────


def dashboard(
    *,
    run_id: str | None = None,
    reports_dir: str | None = None,
    project_dir: str | None = None,
) -> None:
    """Build and view the test results dashboard.

    Wraps ``engine/scripts/build-dashboard.sh`` via subprocess with
    type-safe flags and env-var forwarding.
    """
    # ── 1. Resolve script path ───────────────────────────────────────────
    script = _resolve_engine_script("build-dashboard.sh")
    if not script.is_file():
        _die(f"ERROR: build-dashboard.sh not found at {script}", code=1)

    _debug(f"Resolved script: {script}")

    # ── 2. Build environment ─────────────────────────────────────────────
    env = os.environ.copy()

    if reports_dir:
        env["REPORTS_DIR"] = reports_dir
        _debug(f"REPORTS_DIR={reports_dir}")

    resolved_project = _resolve_project_dir(project_dir)
    if resolved_project:
        env["PROJECT_DIR"] = str(resolved_project)
        _debug(f"PROJECT_DIR={resolved_project}")

    # DASHBOARD_OUT is left for build-dashboard.sh to default unless explicitly
    # set by the caller's environment

    # ── 3. Build command ─────────────────────────────────────────────────
    cmd = ["bash", str(script)]
    if run_id:
        cmd.append(run_id)

    _debug(f"Invoking: {' '.join(cmd)}")

    # ── 4. Execute ───────────────────────────────────────────────────────
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

    if result.returncode != 0:
        _die(f"build-dashboard.sh exited with code {result.returncode}", code=result.returncode)
