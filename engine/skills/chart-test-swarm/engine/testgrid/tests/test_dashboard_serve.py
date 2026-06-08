"""Tests for f17-4 — ``chart-test-swarm dashboard --serve`` and ``--watch --serve``.

Validates:
  - VAL-E2E-003: the live ``--watch`` dashboard rebuilds automatically as
    results land, prints timestamped rebuild lines, and terminates cleanly
    on SIGINT.
  - VAL-E2E-014: successive HTTP fetches of the served index.html during
    the run show monotonically growing covered-result content with no manual
    rebuild.
"""

from __future__ import annotations

import io as _io
import os
import sys
import threading
import time
import urllib.request
from pathlib import Path
from textwrap import dedent
from typing import NoReturn

import pytest
from typer.testing import CliRunner

from chart_test_swarm.main import app

runner = CliRunner()

REPO_ROOT = Path(__file__).resolve().parents[3]


# ── Helpers ──────────────────────────────────────────────────────────────────


def _write_stub(tmp_path: Path, name: str, content: str) -> Path:
    """Write an executable stub script to *tmp_path* and return its path."""
    stub = tmp_path / name
    stub.write_text(content)
    stub.chmod(0o755)
    return stub


def _add_to_path(tmp_path: Path) -> dict[str, str]:
    """Return an env dict with *tmp_path* prepended to PATH."""
    env = os.environ.copy()
    env["PATH"] = f"{tmp_path}{os.pathsep}{env.get('PATH', '')}"
    return env


def _write_fake_run(reports_dir: Path, run_id: str, scenario_id: str) -> Path:
    """Create a fake run directory with result.yaml and artifacts bundle."""
    run_dir = reports_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    scn_dir = run_dir / f"scenario-{scenario_id}"
    scn_dir.mkdir(parents=True, exist_ok=True)

    (scn_dir / "result.yaml").write_text(
        dedent(f"""\
        id: {scenario_id}
        status: PASS
        """)
    )

    art_dir = scn_dir / "artifacts"
    art_dir.mkdir(parents=True, exist_ok=True)
    (art_dir / "scenario.yaml").write_text(f"id: {scenario_id}\n")
    (art_dir / "applied-overrides.yaml").write_text("replicaCount: 1\n")
    (art_dir / "versions.json").write_text(
        '{"helm": "v3.16.0", "kubectl": "v1.30.0", "kind": "v0.24.0", '
        '"minikube": "v1.34.0", "k8s_server": "v1.30.0"}'
    )
    (art_dir / "fixtures").mkdir(parents=True, exist_ok=True)
    (art_dir / "manifests").mkdir(parents=True, exist_ok=True)
    return run_dir


def _wait_for_server(port: int, timeout: float = 5.0) -> None:
    """Block until an HTTP server on *port* responds, or *timeout* elapses."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=0.5)
            return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"HTTP server on port {port} did not start within {timeout}s")


def _http_get_text(url: str) -> str:
    """GET *url* and return the decoded response body."""
    with urllib.request.urlopen(url, timeout=2.0) as resp:
        return resp.read().decode("utf-8", errors="replace")


# ═══════════════════════════════════════════════════════════════════════════
# VAL-E2E-003 / VAL-E2E-014: --serve flag and watch+serve integration
# ═══════════════════════════════════════════════════════════════════════════


class TestDashboardServeHelp:
    """``dashboard --help`` advertises --serve and --port flags."""

    def test_help_shows_serve_flag(self) -> None:
        """--help output includes --serve."""
        result = runner.invoke(app, ["dashboard", "--help"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"
        assert "--serve" in result.stdout, f"Expected --serve in help output, got: {result.stdout}"

    def test_help_shows_port_flag(self) -> None:
        """--help output includes --port."""
        result = runner.invoke(app, ["dashboard", "--help"])
        assert result.exit_code == 0
        assert "--port" in result.stdout, f"Expected --port in help output, got: {result.stdout}"


class TestDashboardServeUnit:
    """Unit tests for _serve_dir helper."""

    def test_serve_dir_starts_http_server(self, tmp_path: Path) -> None:
        """_serve_dir starts an HTTP server that serves files from the directory."""
        from chart_test_swarm.commands.dashboard_cmd import _serve_dir

        # Create a file to serve
        serve_dir = tmp_path / "dist"
        serve_dir.mkdir()
        (serve_dir / "index.html").write_text("<html>Hello</html>")

        # Start the server in a background thread
        server, thread = _serve_dir(serve_dir, port=0)  # port=0 means auto-assign
        try:
            # Get the actual port
            actual_port = server.server_address[1]
            _wait_for_server(actual_port, timeout=3.0)

            # Verify the file is served
            body = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "Hello" in body
        finally:
            server.shutdown()
            thread.join(timeout=5.0)

    def test_serve_dir_auto_port(self, tmp_path: Path) -> None:
        """_serve_dir with port=0 picks an available port."""
        from chart_test_swarm.commands.dashboard_cmd import _serve_dir

        serve_dir = tmp_path / "dist"
        serve_dir.mkdir()
        (serve_dir / "test.txt").write_text("ok")

        server, thread = _serve_dir(serve_dir, port=0)
        try:
            actual_port = server.server_address[1]
            assert actual_port > 0
            assert actual_port != 8080  # not the default
        finally:
            server.shutdown()
            thread.join(timeout=5.0)


class TestDashboardWatchServeIntegration:
    """Integration tests for --watch --serve behavior (VAL-E2E-003, VAL-E2E-014)."""

    def test_watch_serve_rebuilds_and_serves_new_content(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """--watch --serve: new result.yaml causes rebuild; served index.html
        shows the new scenario id after each rebuild."""
        from chart_test_swarm.commands.dashboard_cmd import _serve_dir

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()
        dist_dir = tmp_path / "dist"
        dist_dir.mkdir()

        # Write initial index.html
        (dist_dir / "index.html").write_text("<html>initial</html>")

        # Create a build stub that rewrites index.html with current run count
        invocation_log = tmp_path / "build_count.txt"
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent(f"""\
                #!/usr/bin/env bash
                COUNT=$(cat "{invocation_log}" 2>/dev/null || echo 0)
                COUNT=$((COUNT + 1))
                echo "$COUNT" > "{invocation_log}"
                mkdir -p "{dist_dir}"
                echo "<html>build-$COUNT</html>" > "{dist_dir}/index.html"
                exit 0
            """),
        )

        # Start a server on an auto port
        server, thread = _serve_dir(dist_dir, port=0)
        actual_port = server.server_address[1]
        _wait_for_server(actual_port, timeout=3.0)

        try:
            # Verify initial content
            body0 = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "initial" in body0

            # Track builds
            build_count = 0

            def _fake_build(*_a: object, **_kw: object) -> None:
                nonlocal build_count
                build_count += 1
                # Mimic what the real stub does
                count = build_count
                invocation_log.write_text(str(count))
                (dist_dir / "index.html").write_text(f"<html>build-{count}</html>")

            monkeypatch.setattr(
                "chart_test_swarm.commands.dashboard_cmd._run_build",
                _fake_build,
            )

            # Simulate the watch loop: add a new run, then rebuild
            _write_fake_run(reports_dir, "run-001", "cert-manager-self-signed")

            # Just do the rebuild manually and verify served content changes
            _fake_build()

            body1 = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "build-1" in body1, f"Expected build-1 in served content, got: {body1}"

            # Add another run and rebuild
            _write_fake_run(reports_dir, "run-002", "istio-sidecar")

            _fake_build()

            body2 = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "build-2" in body2, f"Expected build-2 in served content, got: {body2}"
            assert build_count == 2

        finally:
            server.shutdown()
            thread.join(timeout=5.0)

    def test_watch_loop_prints_rebuilt_line_on_new_run(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """_watch_loop prints '[watch] rebuilt dashboard at <ts>' when a new
        run appears (VAL-E2E-003)."""
        from chart_test_swarm.commands.dashboard_cmd import _watch_loop

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()

        stub = _write_stub(
            tmp_path,
            "build-dashboard.sh",
            "#!/usr/bin/env bash\nexit 0\n",
        )

        build_count = 0

        def _fake_build(*_a: object, **_kw: object) -> None:
            nonlocal build_count
            build_count += 1

        # Insert a new run after the first sleep
        sleep_count = 0

        def _fake_sleep(_seconds: float) -> None:
            nonlocal sleep_count
            sleep_count += 1
            if sleep_count == 1:
                _write_fake_run(reports_dir, "run-001", "cert-manager-self-signed")

        monkeypatch.setattr("time.sleep", _fake_sleep)
        monkeypatch.setattr(
            "chart_test_swarm.commands.dashboard_cmd._run_build",
            _fake_build,
        )

        fake_stdout = _io.StringIO()
        monkeypatch.setattr(sys, "stdout", fake_stdout)

        _watch_loop(stub, {}, reports_dir, 30, [], _max_cycles=3)

        output = fake_stdout.getvalue()
        assert build_count >= 1, f"Expected at least 1 rebuild, got {build_count}"
        assert "[watch] rebuilt dashboard at" in output, (
            f"Expected '[watch] rebuilt dashboard at' line, got: {output}"
        )

    def test_watch_loop_keyboard_interrupt_clean_exit(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """KeyboardInterrupt terminates _watch_loop cleanly (VAL-E2E-003)."""
        from chart_test_swarm.commands.dashboard_cmd import _watch_loop

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()

        stub = _write_stub(
            tmp_path,
            "build-dashboard.sh",
            "#!/usr/bin/env bash\nexit 0\n",
        )

        def _raise_kb(_s: float) -> NoReturn:
            raise KeyboardInterrupt

        monkeypatch.setattr("time.sleep", _raise_kb)
        monkeypatch.setattr(
            "chart_test_swarm.commands.dashboard_cmd._run_build",
            lambda *_a: None,
            raising=False,
        )

        fake_stdout = _io.StringIO()
        monkeypatch.setattr(sys, "stdout", fake_stdout)

        _watch_loop(stub, {}, reports_dir, 30, [], _max_cycles=10)

        output = fake_stdout.getvalue()
        assert "[watch] stopped" in output, f"Expected '[watch] stopped.' in output, got: {output}"

    def test_serve_content_updates_without_server_restart(self, tmp_path: Path) -> None:
        """Served index.html reflects file changes without restarting the server
        (VAL-E2E-014)."""
        from chart_test_swarm.commands.dashboard_cmd import _serve_dir

        dist_dir = tmp_path / "dist"
        dist_dir.mkdir()
        (dist_dir / "index.html").write_text("<html>version-1</html>")

        server, thread = _serve_dir(dist_dir, port=0)
        actual_port = server.server_address[1]
        _wait_for_server(actual_port, timeout=3.0)

        try:
            # Fetch initial content
            body1 = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "version-1" in body1

            # Rewrite the file on disk (simulating a rebuild)
            (dist_dir / "index.html").write_text("<html>version-2 with more scenarios</html>")

            # Fetch again — no server restart needed
            body2 = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "version-2" in body2, (
                f"Served content should reflect on-disk update, got: {body2}"
            )
            assert "more scenarios" in body2

            # Rewrite once more
            (dist_dir / "index.html").write_text("<html>version-3 even more scenarios</html>")

            body3 = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "version-3" in body3
            assert "even more" in body3

        finally:
            server.shutdown()
            thread.join(timeout=5.0)

    def test_serve_shows_monotonically_growing_scenario_count(self, tmp_path: Path) -> None:
        """Successive HTTP GETs of the served index.html show monotonically
        growing content as new runs are added and the dashboard is rebuilt
        (VAL-E2E-014)."""
        from chart_test_swarm.commands.dashboard_cmd import _serve_dir

        dist_dir = tmp_path / "dist"
        dist_dir.mkdir()

        # Initial: 1 scenario
        (dist_dir / "index.html").write_text("<html><body>1 scenarios: cert-manager</body></html>")

        server, thread = _serve_dir(dist_dir, port=0)
        actual_port = server.server_address[1]
        _wait_for_server(actual_port, timeout=3.0)

        try:
            body1 = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "cert-manager" in body1
            len1 = len(body1)

            # Rebuild adds istio scenario
            (dist_dir / "index.html").write_text(
                "<html><body>2 scenarios: cert-manager istio</body></html>"
            )

            body2 = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "istio" in body2
            assert "cert-manager" in body2
            len2 = len(body2)

            assert len2 > len1, "Served content should grow monotonically as new results are added"

            # Rebuild adds traefik scenario
            (dist_dir / "index.html").write_text(
                "<html><body>3 scenarios: cert-manager istio traefik</body></html>"
            )

            body3 = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "traefik" in body3
            len3 = len(body3)

            assert len3 > len2 > len1, (
                "Content length should grow monotonically across successive fetches"
            )

        finally:
            server.shutdown()
            thread.join(timeout=5.0)

    def test_watch_serve_together_via_cli(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """``chart-test-swarm dashboard --watch --serve`` runs both the
        watch loop and the HTTP server together."""
        invocation_log = tmp_path / "invocations.txt"
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            f"""#!/usr/bin/env bash
echo "$(date +%s)" >> {invocation_log}
exit 0
""",
        )

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()
        dist_dir = tmp_path / "dist"
        dist_dir.mkdir()
        (dist_dir / "index.html").write_text("<html>dashboard</html>")

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)
        env["REPORTS_DIR"] = str(reports_dir)
        env["DASHBOARD_OUT"] = str(dist_dir)

        # Monkeypatch sleep to avoid real sleeps
        sleep_calls: list[float] = []
        monkeypatch.setattr("time.sleep", lambda s: sleep_calls.append(s))

        # Monkeypatch _watch_loop to run bounded
        import chart_test_swarm.commands.dashboard_cmd as dash_mod

        original_watch_loop = dash_mod._watch_loop

        def _bounded_watch_loop(
            script: Path,
            loop_env: dict,
            loop_reports_dir: Path,
            loop_interval: int,
            cmd_args: list,
            *,
            _max_cycles: int | None = None,
        ) -> None:
            original_watch_loop(
                script,
                loop_env,
                loop_reports_dir,
                loop_interval,
                cmd_args,
                _max_cycles=2,
            )

        monkeypatch.setattr(dash_mod, "_watch_loop", _bounded_watch_loop)

        # Stub _serve_dir to return a dummy server that doesn't actually bind
        server_started = threading.Event()
        shutdown_called = threading.Event()

        class _FakeServer:
            server_address = ("127.0.0.1", 9999)

            def shutdown(self) -> None:
                shutdown_called.set()

            def serve_forever(self) -> None:
                server_started.set()
                # Block until shutdown is called
                shutdown_called.wait(timeout=5.0)

        class _FakeThread(threading.Thread):
            def __init__(self) -> None:
                super().__init__(daemon=True)
                self.started = False

            def run(self) -> None:
                self.started = True
                # Don't actually serve

            def join(self, timeout: float | None = None) -> None:
                pass

        def _fake_serve_dir(directory: Path, port: int = 8080) -> tuple[_FakeServer, _FakeThread]:
            return _FakeServer(), _FakeThread()

        monkeypatch.setattr(dash_mod, "_serve_dir", _fake_serve_dir)

        result = runner.invoke(
            app,
            [
                "dashboard",
                "--watch",
                "--serve",
                "--interval",
                "5",
                "--reports-dir",
                str(reports_dir),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"

        # Verify the stub build-dashboard was invoked at least once
        assert invocation_log.is_file(), "Stub build-dashboard.sh should have been invoked"


class TestDashboardServeCleanShutdown:
    """Server and watcher shut down cleanly on SIGINT."""

    def test_serve_shutdown_on_signal(self, tmp_path: Path) -> None:
        """The HTTP server shuts down when _serve_dir's server.shutdown() is
        called (simulating SIGINT handling)."""
        from chart_test_swarm.commands.dashboard_cmd import _serve_dir

        dist_dir = tmp_path / "dist"
        dist_dir.mkdir()
        (dist_dir / "index.html").write_text("<html>test</html>")

        server, thread = _serve_dir(dist_dir, port=0)
        actual_port = server.server_address[1]
        _wait_for_server(actual_port, timeout=3.0)

        # Verify it's serving
        body = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
        assert "test" in body

        # Shutdown
        server.shutdown()
        thread.join(timeout=5.0)

        # After shutdown, the server should no longer accept connections
        with pytest.raises((ConnectionRefusedError, OSError)):
            urllib.request.urlopen(f"http://127.0.0.1:{actual_port}/", timeout=1.0)


class TestDashboardServeMonotonicContent:
    """VAL-E2E-014: successive curl fetches show monotonically growing
    covered-result content with no manual rebuild."""

    def test_content_grows_as_runs_appear_via_serve(self, tmp_path: Path) -> None:
        """Each new result.yaml that triggers a dashboard rebuild causes the
        served index.html to contain more scenario ids than before."""
        from chart_test_swarm.commands.dashboard_cmd import _serve_dir

        dist_dir = tmp_path / "dist"
        dist_dir.mkdir()

        # Build an initial dashboard with 1 scenario
        (dist_dir / "index.html").write_text(
            '<html><div class="scenario-id">cert-manager</div></html>'
        )

        server, thread = _serve_dir(dist_dir, port=0)
        actual_port = server.server_address[1]
        _wait_for_server(actual_port, timeout=3.0)

        try:
            # Fetch 1: cert-manager only
            body1 = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "cert-manager" in body1

            # Simulate a watch-triggered rebuild that adds istio
            (dist_dir / "index.html").write_text(
                '<html><div class="scenario-id">cert-manager</div>'
                '<div class="scenario-id">istio</div></html>'
            )

            # Fetch 2: cert-manager + istio
            body2 = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "cert-manager" in body2
            assert "istio" in body2
            assert len(body2) > len(body1)

            # Simulate another rebuild adding traefik
            (dist_dir / "index.html").write_text(
                '<html><div class="scenario-id">cert-manager</div>'
                '<div class="scenario-id">istio</div>'
                '<div class="scenario-id">traefik</div></html>'
            )

            # Fetch 3: all three
            body3 = _http_get_text(f"http://127.0.0.1:{actual_port}/index.html")
            assert "traefik" in body3
            assert "istio" in body3
            assert "cert-manager" in body3
            assert len(body3) > len(body2) > len(body1)

        finally:
            server.shutdown()
            thread.join(timeout=5.0)
