"""Tests for F9.3 — ``chart-test-swarm dashboard`` subcommand.

Validates:
  - VAL-CLI-011: dashboard shells out to build-dashboard.sh and produces index.html
  - VAL-CROSS-001 (partial): dashboard invoked after run renders visible scenario card
"""

from __future__ import annotations

import io as _io
import os
import sys
from pathlib import Path
from textwrap import dedent

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


def _scenario_yaml(tmp_path: Path, name: str) -> Path:
    """Write a minimal scenario YAML to *tmp_path*."""
    f = tmp_path / name
    f.write_text(
        f"---\n"
        f"id: {name.replace('.yaml', '')}\n"
        f"cluster:\n  provider: kind\n"
        f"product:\n  chart: ./chart\n  release: test\n  namespace: default\n"
        f"asserts: []\n"
        f"tags: []\n"
    )
    return f


def _write_fake_run(reports_dir: Path, run_id: str, scenario_id: str) -> Path:
    """Create a fake run directory with result.yaml and artifacts bundle."""
    run_dir = reports_dir / run_id
    run_dir.mkdir(parents=True)
    scn_dir = run_dir / f"scenario-{scenario_id}"
    scn_dir.mkdir(parents=True)

    # result.yaml
    (scn_dir / "result.yaml").write_text(
        dedent(f"""\
        id: {scenario_id}
        status: PASS
        """)
    )

    # artifacts
    art_dir = scn_dir / "artifacts"
    art_dir.mkdir(parents=True)
    (art_dir / "scenario.yaml").write_text(f"id: {scenario_id}\n")
    (art_dir / "applied-overrides.yaml").write_text("replicaCount: 1\n")
    (art_dir / "versions.json").write_text(
        '{"helm": "v3.16.0", "kubectl": "v1.30.0", "kind": "v0.24.0", '
        '"minikube": "v1.34.0", "k8s_server": "v1.30.0"}'
    )
    (art_dir / "fixtures").mkdir(parents=True)
    (art_dir / "fixtures" / "tls.crt").write_text("fake-cert")
    (art_dir / "manifests").mkdir(parents=True)
    (art_dir / "manifests" / "deployment.yaml").write_text("kind: Deployment\n")
    return run_dir


# ═══════════════════════════════════════════════════════════════════════════
# VAL-CLI-011: dashboard shells out to build-dashboard.sh, produces index.html
# ═══════════════════════════════════════════════════════════════════════════


class TestDashboardHelp:
    """dashboard --help exits 0 and advertises flags."""

    def test_help_exits_0(self) -> None:
        """dashboard --help exits with code 0."""
        result = runner.invoke(app, ["dashboard", "--help"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"

    def test_help_mentions_build(self) -> None:
        """--help output mentions building or dashboard."""
        result = runner.invoke(app, ["dashboard", "--help"])
        assert (
            "build" in (result.stdout + result.stderr).lower()
            or "dashboard" in (result.stdout + result.stderr).lower()
        )


class TestDashboardStubDispatch:
    """VAL-CLI-011: dashboard shells out to build-dashboard.sh via subprocess."""

    def test_stub_invoked(self, tmp_path: Path) -> None:
        """The PATH stub is invoked and logs its argv."""
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "build-dashboard invoked"
                echo "argv: $*"
                echo "REPORTS_DIR=${REPORTS_DIR:-unset}"
                echo "DASHBOARD_OUT=${DASHBOARD_OUT:-unset}"
                echo "PROJECT_DIR=${PROJECT_DIR:-unset}"
                exit 0
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["dashboard"],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "build-dashboard invoked" in result.stdout, (
            f"Expected stub output in stdout, got: {result.stdout}"
        )

    def test_run_id_passed_as_arg(self, tmp_path: Path) -> None:
        """--run-id is forwarded as the first positional argument."""
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "argv: $*"
                exit 0
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["dashboard", "--run-id", "run-20250101-120000"],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "run-20250101-120000" in result.stdout, (
            f"Expected run-id in argv, got: {result.stdout}"
        )

    def test_reports_dir_passed_as_env(self, tmp_path: Path) -> None:
        """--reports-dir sets REPORTS_DIR env var."""
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "REPORTS_DIR=${REPORTS_DIR:-unset}"
                exit 0
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["dashboard", "--reports-dir", "/tmp/my-reports"],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "REPORTS_DIR=/tmp/my-reports" in result.stdout, (
            f"Expected REPORTS_DIR in output, got: {result.stdout}"
        )

    def test_project_dir_passed_as_env(self, tmp_path: Path) -> None:
        """--project-dir sets PROJECT_DIR env var."""
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "PROJECT_DIR=${PROJECT_DIR:-unset}"
                exit 0
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["dashboard", "--project-dir", "/tmp/my-project"],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        # On macOS /tmp is a symlink to /private/tmp, so Path.resolve()
        # may expand it.  Check that PROJECT_DIR is set and contains my-project.
        assert "PROJECT_DIR=" in result.stdout, (
            f"Expected PROJECT_DIR in output, got: {result.stdout}"
        )
        assert "my-project" in result.stdout, (
            f"Expected 'my-project' in output, got: {result.stdout}"
        )

    def test_stub_exits_nonzero_propagates(self, tmp_path: Path) -> None:
        """When build-dashboard.sh exits non-zero, CLI propagates the exit code."""
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "FAILING" >&2
                exit 5
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["dashboard"],
            env=env,
        )
        assert result.exit_code == 5, f"Expected exit 5, got {result.exit_code}"
        assert "FAILING" in result.stderr


class TestDashboardStubCapturesBuildDashboardInArgvLog:
    """Stub mode captures build-dashboard.sh in argv log (expectedBehavior)."""

    def test_stub_records_build_dashboard_invocation(self, tmp_path: Path) -> None:
        """Stub logs build-dashboard.sh argv for test inspection."""
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "ARGV_LOG: $0 $*"
                echo "CTS_DEBUG: build-dashboard.sh invoked with ${#} positional args"
                echo "ARGS: $@"
                exit 0
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)
        env["CTS_DEBUG"] = "1"

        result = runner.invoke(
            app,
            ["dashboard", "--run-id", "run-stub", "--reports-dir", "/tmp/stub-reports"],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        # The stub is invoked
        assert "build-dashboard.sh" in result.stdout, (
            f"build-dashboard.sh should appear in output: {result.stdout}"
        )
        # The run-id is passed
        assert "run-stub" in result.stdout


class TestDashboardWithRealReports:
    """Integration test: dashboard produces index.html from a fake run."""

    def test_dashboard_with_fake_run_produces_index(self, tmp_path: Path) -> None:
        """With a synthetic reports tree, dashboard builds index.html."""
        reports_dir = tmp_path / "reports"
        reports_dir.mkdir(parents=True)

        # Create a fake run
        run_id = "run-20250101-120000"
        _write_fake_run(reports_dir, run_id, "test-scenario")

        # Create a stub build-dashboard that simulates the real script behavior
        # but using the test reports dir
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent(f"""\
                #!/usr/bin/env bash
                # Stub that simulates build-dashboard.sh behavior
                echo "Building dashboard..."
                mkdir -p "{reports_dir}/dist"
                cat > "{reports_dir}/dist/index.html" << 'HTMLEOF'
                <!DOCTYPE html>
                <html>
                <head><title>chart-test-swarm</title></head>
                <body>
                <section class="runs">
                <table><tbody>
                <tr class="run-row">
                  <td><a href="{run_id}/index.html">{run_id}</a></td>
                  <td>1</td>
                </tr>
                </tbody></table>
                </section>
                </body>
                </html>
                HTMLEOF
                echo "Dashboard written to {reports_dir}/dist/index.html"
                exit 0
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["dashboard", "--reports-dir", str(reports_dir)],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"

        # Verify index.html exists and contains <html
        index_path = reports_dir / "dist" / "index.html"
        assert index_path.is_file(), f"index.html not found at {index_path}"
        content = index_path.read_text()
        assert "<html" in content, f"index.html does not contain <html: {content[:200]}"


class TestDashboardExitCodePropagation:
    """Dashboard exit code propagation from build-dashboard.sh."""

    def test_build_script_exits_nonzero(self, tmp_path: Path) -> None:
        """If build-dashboard.sh exits non-zero, dashboard command exits non-zero."""
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "Error: no reports found" >&2
                exit 1
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["dashboard"],
            env=env,
        )
        assert result.exit_code != 0, f"Expected non-zero exit, got {result.exit_code}"
        assert "no reports found" in result.stderr

    def test_build_script_exits_0_gracefully(self, tmp_path: Path) -> None:
        """If build-dashboard.sh exits 0, dashboard command exits 0."""
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "Dashboard built successfully"
                exit 0
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["dashboard"],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "Dashboard built" in result.stdout


class TestDashboardEnvironmentVariables:
    """Dashboard forwards environment variables to build-dashboard.sh."""

    def test_all_env_vars_forwarded(self, tmp_path: Path) -> None:
        """When all flags are set, all env vars appear in the subprocess."""
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "REPORTS_DIR=${REPORTS_DIR:-unset}"
                echo "DASHBOARD_OUT=${DASHBOARD_OUT:-unset}"
                echo "PROJECT_DIR=${PROJECT_DIR:-unset}"
                echo "RUN_ID_ARG=$1"
                exit 0
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            [
                "dashboard",
                "--reports-dir",
                "/tmp/my-reports",
                "--project-dir",
                "/tmp/my-project",
                "--run-id",
                "run-custom-20250101",
            ],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "REPORTS_DIR=/tmp/my-reports" in result.stdout
        # On macOS /tmp is a symlink to /private/tmp, so Path.resolve() may
        # expand it.  Check that PROJECT_DIR is set and contains my-project.
        assert "PROJECT_DIR=" in result.stdout
        assert "my-project" in result.stdout
        assert "RUN_ID_ARG=run-custom-20250101" in result.stdout

    def test_no_flags_uses_defaults(self, tmp_path: Path) -> None:
        """With no flags, build-dashboard.sh receives no env var overrides."""
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "REPORTS_DIR=${REPORTS_DIR:-unset}"
                echo "DASHBOARD_OUT=${DASHBOARD_OUT:-unset}"
                echo "PROJECT_DIR=${PROJECT_DIR:-unset}"
                echo "RUN_ID_ARG=${1:-unset}"
                exit 0
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["dashboard"],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        # Without any flags, the env vars should not be overridden by CLI
        # (REPORTS_DIR may be unset or set by the env)
        assert "RUN_ID_ARG=unset" in result.stdout


# ═══════════════════════════════════════════════════════════════════════════
# VAL-DASH-026: --watch and --interval flags on dashboard subcommand
# ═══════════════════════════════════════════════════════════════════════════


class TestDashboardWatchHelp:
    """``dashboard --help`` advertises --watch and --interval flags."""

    def test_help_shows_watch_flag(self) -> None:
        """--help output includes --watch."""
        result = runner.invoke(app, ["dashboard", "--help"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"
        assert "--watch" in result.stdout, f"Expected --watch in help output, got: {result.stdout}"

    def test_help_shows_interval_flag(self) -> None:
        """--help output includes --interval."""
        result = runner.invoke(app, ["dashboard", "--help"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"
        assert "--interval" in result.stdout, (
            f"Expected --interval in help output, got: {result.stdout}"
        )

    def test_help_shows_interval_default_30(self) -> None:
        """--help output mentions the default poll interval of 30."""
        result = runner.invoke(app, ["dashboard", "--help"])
        assert result.exit_code == 0
        assert "30" in result.stdout, (
            f"Expected default interval 30 in help text, got: {result.stdout}"
        )


class TestDashboardScanReports:
    """Unit tests for ``_scan_reports`` helper."""

    def test_empty_dir_returns_empty_dict(self) -> None:
        """_scan_reports returns {} for a non-existent directory."""
        from chart_test_swarm.commands.dashboard_cmd import _scan_reports

        assert _scan_reports(Path("/nonexistent/path/ctstest42")) == {}

    def test_detects_run_dirs(self, tmp_path: Path) -> None:
        """_scan_reports detects run-* dirs with their mtimes."""
        from chart_test_swarm.commands.dashboard_cmd import _scan_reports

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()
        (reports_dir / "run-001").mkdir()
        (reports_dir / "run-001" / "result.yaml").write_text("status: PASS\n")

        state = _scan_reports(reports_dir)
        assert "run-001" in state, f"Expected run-001 in state, got keys: {list(state.keys())}"
        # mtime should be a positive float
        assert state["run-001"] > 0.0

    def test_ignores_non_run_dirs(self, tmp_path: Path) -> None:
        """_scan_reports ignores directories not starting with 'run-'."""
        from chart_test_swarm.commands.dashboard_cmd import _scan_reports

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()
        (reports_dir / "dist").mkdir()
        (reports_dir / "run-001").mkdir()
        (reports_dir / "run-001" / "result.yaml").write_text("status: PASS\n")
        (reports_dir / "other-dir").mkdir()

        state = _scan_reports(reports_dir)
        assert "run-001" in state
        assert "dist" not in state
        assert "other-dir" not in state

    def test_detects_file_change_in_run_dir(self, tmp_path: Path) -> None:
        """_scan_reports returns different state when a file inside a run changes."""
        import time as _time

        from chart_test_swarm.commands.dashboard_cmd import _scan_reports

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()
        run_dir = reports_dir / "run-001"
        run_dir.mkdir()
        (run_dir / "result.yaml").write_text("status: PASS\n")

        state_before = _scan_reports(reports_dir)

        # Sleep to guarantee mtime tick (many filesystems have 1s granularity)
        _time.sleep(1.1)
        (run_dir / "result.yaml").write_text("status: FAIL\n")

        state_after = _scan_reports(reports_dir)
        assert state_after["run-001"] > state_before["run-001"], (
            "Expected mtime to increase after file modification"
        )


class TestDashboardClampInterval:
    """Unit tests for ``_clamp_interval`` helper."""

    def test_below_minimum_clamped_to_5(self) -> None:
        """Values below 5 are clamped to 5."""
        from chart_test_swarm.commands.dashboard_cmd import _clamp_interval

        assert _clamp_interval(3) == 5
        assert _clamp_interval(1) == 5
        assert _clamp_interval(0) == 5
        assert _clamp_interval(-1) == 5

    def test_above_minimum_passes_through(self) -> None:
        """Values >= 5 are returned unchanged."""
        from chart_test_swarm.commands.dashboard_cmd import _clamp_interval

        assert _clamp_interval(5) == 5
        assert _clamp_interval(30) == 30
        assert _clamp_interval(60) == 60
        assert _clamp_interval(300) == 300

    def test_clamping_prints_warning(self, capsys: pytest.CaptureFixture[str]) -> None:
        """Clamping prints a warning to stderr."""
        from chart_test_swarm.commands.dashboard_cmd import _clamp_interval

        _clamp_interval(3)
        captured = capsys.readouterr()
        assert "below minimum" in captured.err
        assert "using 5s" in captured.err


class TestDashboardWatchLoop:
    """Integration-style tests for ``_watch_loop`` with stubs."""

    def test_watch_loop_polls_and_prints_status_lines(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """_watch_loop prints a timestamped status line each poll cycle."""
        from chart_test_swarm.commands.dashboard_cmd import _watch_loop

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()

        stub = _write_stub(
            tmp_path,
            "build-dashboard.sh",
            "#!/usr/bin/env bash\nexit 0\n",
        )

        # Capture sleep calls but do not actually sleep
        sleep_calls: list[float] = []
        monkeypatch.setattr("time.sleep", lambda s: sleep_calls.append(s))

        # Capture stdout
        fake_stdout = _io.StringIO()
        monkeypatch.setattr(sys, "stdout", fake_stdout)

        # Stub _run_build to a no-op
        monkeypatch.setattr(
            "chart_test_swarm.commands.dashboard_cmd._run_build",
            lambda *_a: None,
            raising=False,
        )

        _watch_loop(stub, {}, reports_dir, 30, [], _max_cycles=3)

        output = fake_stdout.getvalue()
        assert 2 <= output.count("polling... no changes") <= 3, (
            f"Expected 2-3 polling lines, got {output.count('polling... no changes')}"
        )
        assert len(sleep_calls) == 3

    def test_watch_loop_rebuilds_on_new_run(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """_watch_loop rebuilds the dashboard when a new run-* dir appears."""
        from chart_test_swarm.commands.dashboard_cmd import _watch_loop

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()

        stub = _write_stub(
            tmp_path,
            "build-dashboard.sh",
            "#!/usr/bin/env bash\nexit 0\n",
        )

        # Track build calls
        build_count = 0

        def _fake_build(*_a: object, **_kw: object) -> None:
            nonlocal build_count
            build_count += 1

        # Insert a new run dir after the first sleep cycle
        sleep_count = 0

        def _fake_sleep(_seconds: float) -> None:
            nonlocal sleep_count
            sleep_count += 1
            if sleep_count == 1:
                run_dir = reports_dir / "run-new"
                run_dir.mkdir()
                (run_dir / "result.yaml").write_text("status: PASS\n")

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
        assert "rebuilt dashboard at" in output, f"Expected rebuild line in output, got: {output}"

    def test_watch_loop_keyboard_interrupt_clean_exit(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """KeyboardInterrupt terminates _watch_loop cleanly without raising."""
        from chart_test_swarm.commands.dashboard_cmd import _watch_loop

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()

        stub = _write_stub(
            tmp_path,
            "build-dashboard.sh",
            "#!/usr/bin/env bash\nexit 0\n",
        )

        # Raise KeyboardInterrupt on the first sleep call
        def _raise_kb(_s: float) -> None:
            raise KeyboardInterrupt

        monkeypatch.setattr("time.sleep", _raise_kb)

        # Stub _run_build
        monkeypatch.setattr(
            "chart_test_swarm.commands.dashboard_cmd._run_build",
            lambda *_a: None,
            raising=False,
        )

        fake_stdout = _io.StringIO()
        monkeypatch.setattr(sys, "stdout", fake_stdout)

        # Must NOT raise
        _watch_loop(stub, {}, reports_dir, 30, [], _max_cycles=10)

        output = fake_stdout.getvalue()
        assert "stopped" in output, f"Expected '[watch] stopped.' in output, got: {output}"

    def test_watch_loop_rebuilds_on_modified_run(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """_watch_loop rebuilds when an existing run's result.yaml is modified."""
        from chart_test_swarm.commands.dashboard_cmd import _watch_loop

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()

        # Pre-create a run dir
        run_dir = reports_dir / "run-001"
        run_dir.mkdir()
        (run_dir / "result.yaml").write_text("status: PASS\n")

        stub = _write_stub(
            tmp_path,
            "build-dashboard.sh",
            "#!/usr/bin/env bash\nexit 0\n",
        )

        build_count = 0

        def _fake_build(*_a: object, **_kw: object) -> None:
            nonlocal build_count
            build_count += 1

        sleep_count = 0

        def _fake_sleep(_seconds: float) -> None:
            nonlocal sleep_count
            sleep_count += 1
            if sleep_count == 1:
                # Modify existing run's result file
                (run_dir / "result.yaml").write_text("status: FAIL\n")

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
        assert "rebuilt dashboard at" in output


class TestDashboardWatchCliIntegration:
    """CLI-level integration tests for --watch and --interval flags."""

    def test_interval_flag_clamped_in_help_or_validation(self) -> None:
        """--interval below 5 is clamped or help mentions the minimum."""
        # Verify that --help shows the minimum constraint
        result = runner.invoke(app, ["dashboard", "--help"])
        assert result.exit_code == 0
        # The help text should mention the minimum (5)
        help_text = result.stdout.lower()
        assert "minimum" in help_text or "min" in help_text or "5" in help_text, (
            f"Help should mention interval minimum: {result.stdout}"
        )

    def test_watch_with_stub_reports_dir(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """--watch with a stubbed build-dashboard.sh does initial build and polls."""
        # Stub that records invocations to a file
        invocation_log = tmp_path / "invocations.txt"
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            f"""#!/usr/bin/env bash
echo "$(date +%s)" >> {invocation_log}
exit 0
""",
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()

        # Monkeypatch time.sleep to avoid real sleep
        sleep_calls: list[float] = []
        monkeypatch.setattr("time.sleep", lambda s: sleep_calls.append(s))

        # Monkeypatch _watch_loop to run a bounded number of cycles
        import chart_test_swarm.commands.dashboard_cmd as dash_mod

        original_watch_loop = dash_mod._watch_loop

        def _bounded_watch_loop(
            script: Path,
            loop_env: dict,
            loop_reports_dir: Path,
            loop_interval: int,
            cmd_args: list,
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

        result = runner.invoke(
            app,
            [
                "dashboard",
                "--watch",
                "--interval",
                "5",
                "--reports-dir",
                str(reports_dir),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"

        # Verify the stub was invoked at least once (initial build)
        assert invocation_log.is_file(), "Stub should have been invoked at least once"
        lines = invocation_log.read_text().strip().split("\n")
        assert len(lines) >= 1, f"Expected >=1 invocations, got {len(lines)}"

    def test_no_watch_one_shot_preserved(self, tmp_path: Path) -> None:
        """Without --watch, dashboard builds once and exits (no regression)."""
        _write_stub(
            tmp_path,
            "build-dashboard.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "built once"
                exit 0
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(app, ["dashboard"], env=env)
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "built once" in result.stdout
        # Only one occurrence — no polling loop
        assert result.stdout.count("built once") == 1
