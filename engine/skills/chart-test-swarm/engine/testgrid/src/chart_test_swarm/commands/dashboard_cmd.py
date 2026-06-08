"""``chart-test-swarm dashboard`` subcommand — wrap build-dashboard.sh.

Invokes ``engine/scripts/build-dashboard.sh`` via subprocess with typed flags,
forwarding env vars for REPORTS_DIR, PROJECT_DIR, and DASHBOARD_OUT.

When ``--watch`` is set, enters a polling loop that monitors the reports
directory for new or modified run-* directories and rebuilds automatically.

When ``--serve`` is set, starts a local HTTP server serving the dashboard
dist directory.  Combined with ``--watch``, the served dashboard updates
live as new results land — no manual rebuild needed (VAL-E2E-014).
"""

from __future__ import annotations

import http.server
import os
import socketserver
import subprocess
import sys
import threading
import time
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


def _resolve_reports_dir(reports_dir: str | None, project_dir: str | None) -> Path:
    """Resolve the reports directory for watch mode monitoring.

    Resolution order matches ``build-dashboard.sh``:
      1. Explicit ``--reports-dir`` flag
      2. ``REPORTS_DIR`` env var
      3. ``PROJECT_DIR/chart-test/reports`` if PROJECT_DIR is set
      4. Default: ``<repo_root>/reports``
    """
    if reports_dir:
        return Path(reports_dir)

    env_reports = os.environ.get("REPORTS_DIR")
    if env_reports:
        return Path(env_reports)

    resolved_project = _resolve_project_dir(project_dir)
    if resolved_project and (resolved_project / "chart-test").is_dir():
        return resolved_project / "chart-test" / "reports"

    # Default: repo root / reports
    this_file = Path(__file__).resolve()
    engine_dir = this_file.parents[3]  # commands → chart_test_swarm → src → testgrid
    root_dir = engine_dir.parents[1]  # testgrid → engine → root
    return root_dir / "reports"


def _scan_reports(reports_root: Path) -> dict[str, float]:
    """Scan *reports_root* for ``run-*`` directories and return ``{name: max_mtime}``.

    For each ``run-*`` directory, the maximum modification time across all
    contained files is recorded.  Returns an empty dict when the directory
    does not exist or contains no matching entries.
    """
    if not reports_root.is_dir():
        return {}

    state: dict[str, float] = {}
    for entry in reports_root.iterdir():
        if not entry.is_dir() or not entry.name.startswith("run-"):
            continue
        max_mtime = entry.stat().st_mtime
        for root, _dirs, files in os.walk(entry):
            for f in files:
                fp = Path(root) / f
                mtime = fp.stat().st_mtime
                if mtime > max_mtime:
                    max_mtime = mtime
        state[entry.name] = max_mtime
    return state


def _run_build(
    script: Path,
    env: dict[str, str],
    cmd_args: list[str],
    *,
    exit_on_failure: bool = True,
) -> None:
    """Execute ``build-dashboard.sh`` as a subprocess.

    When *exit_on_failure* is ``True`` (one-shot builds), a non-zero exit
    from the script terminates the process.  When ``False`` (watch-mode
    rebuilds), a warning is printed to stderr and execution continues.
    """
    cmd = ["bash", str(script)] + cmd_args
    result = subprocess.run(cmd, env=env, capture_output=True, text=True)

    if result.stdout:
        sys.stdout.write(result.stdout)
        sys.stdout.flush()
    if result.stderr:
        sys.stderr.write(result.stderr)
        sys.stderr.flush()

    if result.returncode != 0:
        if exit_on_failure:
            _die(
                f"build-dashboard.sh exited with code {result.returncode}",
                code=result.returncode,
            )
        else:
            print(
                f"[watch] warning: build exited with code {result.returncode}",
                file=sys.stderr,
            )


def _clamp_interval(interval: int) -> int:
    """Clamp *interval* to a minimum of 5 seconds.

    Prints a warning to stderr when clamping is applied.
    """
    if interval < 5:
        print(
            f"[watch] interval {interval}s is below minimum; using 5s",
            file=sys.stderr,
        )
        return 5
    return interval


def _serve_dir(
    directory: Path, port: int = 8080
) -> tuple[socketserver.TCPServer, threading.Thread]:
    """Start a local HTTP server serving *directory* on *port*.

    Returns a ``(server, thread)`` tuple.  The server runs in a daemon
    thread so it is automatically cleaned up when the process exits.
    Call ``server.shutdown()`` to stop the server and ``thread.join()``
    to wait for the thread to finish.

    When *port* is ``0``, the OS picks an available port; the actual
    port is available via ``server.server_address[1]``.
    """

    # Use a custom handler that disables caching so fresh content
    # is always returned after a rebuild (critical for VAL-E2E-014).
    class _NoCacheHandler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args: object, **kwargs: object) -> None:
            super().__init__(*args, directory=str(directory), **kwargs)  # type: ignore[arg-type]

        def end_headers(self) -> None:
            # Disable caching so successive fetches always see the latest build
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            super().end_headers()

        def log_message(self, format: str, *args: object) -> None:
            # Suppress per-request log noise; only log to stderr in debug mode
            if os.environ.get("CTS_DEBUG", "").strip() in ("1", "true", "yes"):
                super().log_message(format, *args)

    # allow_reuse_address so we don't get "Address already in use" on restart
    server = socketserver.TCPServer(
        ("127.0.0.1", port),
        _NoCacheHandler,
        bind_and_activate=True,
    )

    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def _resolve_dist_dir(reports_dir: str | None, project_dir: str | None) -> Path:
    """Resolve the dashboard dist directory for serving.

    Mirrors ``build-dashboard.sh`` logic:
      1. ``DASHBOARD_OUT`` env var
      2. ``REPORTS_DIR/dist``
      3. ``PROJECT_DIR/chart-test/reports/dist``
      4. ``<repo_root>/reports/dist``
    """
    env_out = os.environ.get("DASHBOARD_OUT")
    if env_out:
        return Path(env_out)

    resolved_reports = _resolve_reports_dir(reports_dir, project_dir)
    return resolved_reports / "dist"


def _watch_loop(
    script: Path,
    env: dict[str, str],
    reports_dir: Path,
    interval: int,
    cmd_args: list[str],
    *,
    _max_cycles: int | None = None,
) -> None:
    """Poll *reports_dir* for changes and rebuild the dashboard.

    Runs until ``SIGINT`` (``KeyboardInterrupt``) or *_max_cycles*
    iterations (for testing).  Each poll cycle prints a timestamped status
    line.  When changes are detected the dashboard is rebuilt and a rebuild
    notice is printed.
    """
    cycles = 0
    prev_state = _scan_reports(reports_dir)

    while _max_cycles is None or cycles < _max_cycles:
        try:
            time.sleep(interval)
        except KeyboardInterrupt:
            print("\n[watch] stopped.")
            break

        cycles += 1
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        current_state = _scan_reports(reports_dir)

        if current_state != prev_state:
            print(f"[watch] rebuilt dashboard at {timestamp}")
            _run_build(script, env, cmd_args, exit_on_failure=False)
            prev_state = current_state
        else:
            print(f"[watch] {timestamp}  polling... no changes")


# ── Dashboard command entry point ────────────────────────────────────────────


def dashboard(
    *,
    run_id: str | None = None,
    reports_dir: str | None = None,
    project_dir: str | None = None,
    watch: bool = False,
    interval: int = 30,
    serve: bool = False,
    port: int = 8080,
) -> None:
    """Build and view the test results dashboard.

    Wraps ``engine/scripts/build-dashboard.sh`` via subprocess with
    type-safe flags and env-var forwarding.

    When *watch* is ``True``, enters a polling loop that monitors the
    reports directory for new or modified ``run-*`` directories and
    rebuilds automatically.

    When *serve* is ``True``, starts a local HTTP server serving the
    dashboard dist directory.  Combined with *watch*, the served
    dashboard updates live as new results land — no manual rebuild
    needed (VAL-E2E-014).
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

    # ── 3. Build command arguments ───────────────────────────────────────
    cmd_args: list[str] = []
    if run_id:
        cmd_args.append(run_id)

    _debug(f"Invoking: bash {script} {' '.join(cmd_args)}")

    # ── 4. Start HTTP server (if --serve) ────────────────────────────────
    server: socketserver.TCPServer | None = None
    server_thread: threading.Thread | None = None

    if serve:
        dist_dir = _resolve_dist_dir(reports_dir, project_dir)
        dist_dir.mkdir(parents=True, exist_ok=True)
        server, server_thread = _serve_dir(dist_dir, port=port)
        actual_port = server.server_address[1]
        print(f"[serve] dashboard available at http://127.0.0.1:{actual_port}/")
        _debug(f"Serving {dist_dir} on port {actual_port}")

    # ── 5. Execute (watch or one-shot) ──────────────────────────────────
    try:
        if watch:
            clamped_interval = _clamp_interval(interval)
            resolved_reports = _resolve_reports_dir(reports_dir, project_dir)
            _debug(f"Watch mode: interval={clamped_interval}s, reports={resolved_reports}")

            # Initial build
            _run_build(script, env, cmd_args, exit_on_failure=True)

            # Enter polling loop
            _watch_loop(script, env, resolved_reports, clamped_interval, cmd_args)
        else:
            _run_build(script, env, cmd_args, exit_on_failure=True)
    except KeyboardInterrupt:
        print("\n[watch] stopped.")
    finally:
        # ── 6. Stop HTTP server (if running) ─────────────────────────────
        if server is not None and server_thread is not None:
            _debug("Shutting down HTTP server")
            server.shutdown()
            server_thread.join(timeout=5.0)
            print("[serve] server stopped.")
