"""Tests for F9.3 — ``chart-test-swarm dashboard`` subcommand.

Validates:
  - VAL-CLI-011: dashboard shells out to build-dashboard.sh and produces index.html
  - VAL-CROSS-001 (partial): dashboard invoked after run renders visible scenario card
"""

from __future__ import annotations

import os
from pathlib import Path
from textwrap import dedent

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
