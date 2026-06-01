"""Tests for F9.1 — CLI scaffolding.

Validates:
  - VAL-CLI-001: pyproject.toml declares chart-test-swarm entry point
  - VAL-CLI-002: binary is executable after uv sync
  - VAL-CLI-003: root --help exits 0 and lists all four subcommands
  - VAL-CLI-004: no-args invocation exits non-zero with help message
  - VAL-CLI-005: unknown subcommand exits non-zero with clear error
  - VAL-CLI-020: --version prints semver-ish version and exits 0
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

from typer.testing import CliRunner

from chart_test_swarm import __version__
from chart_test_swarm.main import app

# Paths
REPO_ROOT = Path(__file__).resolve().parents[3]
TESTGRID_DIR = REPO_ROOT / "engine" / "testgrid"
PYPROJECT = TESTGRID_DIR / "pyproject.toml"
VENV_BIN = TESTGRID_DIR / ".venv" / "bin" / "chart-test-swarm"

runner = CliRunner()


# ---------------------------------------------------------------------------
# VAL-CLI-001: Console script registered in pyproject.toml
# ---------------------------------------------------------------------------


class TestPyprojectEntryPoint:
    """VAL-CLI-001: pyproject.toml declares chart-test-swarm entry point."""

    def test_console_script_declared(self) -> None:
        """chart-test-swarm entry exists in [project.scripts]."""
        import tomllib

        data = tomllib.loads(PYPROJECT.read_text())
        scripts = data.get("project", {}).get("scripts", {})
        assert "chart-test-swarm" in scripts, (
            f"chart-test-swarm not found in [project.scripts]: {list(scripts.keys())}"
        )

    def test_entry_points_to_main_app(self) -> None:
        """Entry points at chart_test_swarm.main:app."""
        import tomllib

        data = tomllib.loads(PYPROJECT.read_text())
        entry = data["project"]["scripts"]["chart-test-swarm"]
        # Should end with :app or :main
        assert entry.endswith(":app") or entry.endswith(":main"), (
            f"Expected entry ending in :app or :main, got: {entry}"
        )
        assert "chart_test_swarm.main" in entry, (
            f"Expected entry in chart_test_swarm.main, got: {entry}"
        )


# ---------------------------------------------------------------------------
# VAL-CLI-002: Console script installs on PATH after uv sync
# ---------------------------------------------------------------------------


class TestBinaryInstall:
    """VAL-CLI-002: binary is executable after uv sync."""

    def test_binary_exists(self) -> None:
        """chart-test-swarm binary exists in .venv/bin."""
        assert VENV_BIN.exists(), f"Binary not found: {VENV_BIN}"

    def test_binary_is_executable(self) -> None:
        """Binary has execute permission."""
        assert VENV_BIN.is_file(), f"{VENV_BIN} is not a file"
        import os

        assert os.access(str(VENV_BIN), os.X_OK), f"{VENV_BIN} is not executable"

    def test_binary_produces_output(self) -> None:
        """Running --help produces non-empty stdout."""
        result = subprocess.run(
            [str(VENV_BIN), "--help"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert result.returncode == 0, f"--help failed: {result.stderr}"
        assert result.stdout.strip(), "--help produced empty stdout"


# ---------------------------------------------------------------------------
# VAL-CLI-003: Root --help exits 0 and lists all subcommands
# ---------------------------------------------------------------------------


class TestRootHelp:
    """VAL-CLI-003: root --help exits 0 and lists all subcommands."""

    def test_help_exits_0(self) -> None:
        """--help exits with code 0."""
        result = runner.invoke(app, ["--help"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}, output={result.output}"

    def test_help_lists_run(self) -> None:
        """--help output contains 'run' subcommand."""
        result = runner.invoke(app, ["--help"])
        assert "run" in result.stdout

    def test_help_lists_dashboard(self) -> None:
        """--help output contains 'dashboard' subcommand."""
        result = runner.invoke(app, ["--help"])
        assert "dashboard" in result.stdout

    def test_help_lists_list(self) -> None:
        """--help output contains 'list' subcommand."""
        result = runner.invoke(app, ["--help"])
        assert "list" in result.stdout

    def test_help_lists_generate(self) -> None:
        """--help output contains 'generate' subcommand."""
        result = runner.invoke(app, ["--help"])
        assert "generate" in result.stdout

    def test_help_contains_usage(self) -> None:
        """--help output contains 'Usage'."""
        result = runner.invoke(app, ["--help"])
        assert "Usage" in result.stdout


# ---------------------------------------------------------------------------
# VAL-CLI-004: No-args invocation exits non-zero with help message
# ---------------------------------------------------------------------------


class TestNoArgs:
    """VAL-CLI-004: no-args exits non-zero with help/usage message."""

    def test_no_args_exits_nonzero(self) -> None:
        """Invoking with no arguments exits non-zero."""
        result = runner.invoke(app, [])
        assert result.exit_code != 0, f"Expected non-zero exit, got {result.exit_code}"

    def test_no_args_shows_usage(self) -> None:
        """No-args output contains 'Usage'."""
        result = runner.invoke(app, [])
        combined = result.stdout + result.stderr  # typer may write to either
        assert "Usage" in combined, (
            f"Expected 'Usage' in output, got:\nstdout={result.stdout}\nstderr={result.stderr}"
        )

    def test_no_args_lists_subcommands(self) -> None:
        """No-args output contains at least one subcommand name."""
        result = runner.invoke(app, [])
        combined = result.stdout + result.stderr
        assert any(cmd in combined for cmd in ["run", "dashboard", "list", "generate"]), (
            f"Expected at least one subcommand in output:\n{combined}"
        )


# ---------------------------------------------------------------------------
# VAL-CLI-005: Unknown subcommand exits non-zero with clear error
# ---------------------------------------------------------------------------


class TestUnknownSubcommand:
    """VAL-CLI-005: unknown subcommand exits non-zero with error naming the token."""

    def test_unknown_subcommand_exits_nonzero(self) -> None:
        """Unknown subcommand exits non-zero."""
        result = runner.invoke(app, ["not-a-real-subcommand"])
        assert result.exit_code != 0, f"Expected non-zero exit, got {result.exit_code}"

    def test_unknown_subcommand_names_token(self) -> None:
        """Error message names the offending token."""
        result = runner.invoke(app, ["not-a-real-subcommand"])
        assert "not-a-real-subcommand" in result.stderr, (
            f"Expected 'not-a-real-subcommand' in stderr, got: {result.stderr}"
        )

    def test_unknown_subcommand_suggests_help(self) -> None:
        """Error suggests trying --help."""
        result = runner.invoke(app, ["another-bogus-cmd"])
        stderr_combined = result.stderr
        assert "--help" in stderr_combined or "help" in stderr_combined.lower(), (
            f"Expected '--help' suggestion in stderr, got: {stderr_combined}"
        )


# ---------------------------------------------------------------------------
# VAL-CLI-020: --version prints semver-ish version and exits 0
# ---------------------------------------------------------------------------


class TestVersion:
    """VAL-CLI-020: --version prints semver version and exits 0."""

    def test_version_exits_0(self) -> None:
        """--version exits with code 0."""
        result = runner.invoke(app, ["--version"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"

    def test_version_contains_semver(self) -> None:
        """--version output contains a semver-shaped version string."""
        result = runner.invoke(app, ["--version"])
        # Match semver: digits.digits.digits
        match = re.search(r"\d+\.\d+\.\d+", result.stdout)
        assert match, f"Expected semver in output, got: {result.stdout}"

    def test_version_matches_init(self) -> None:
        """--version version matches chart_test_swarm.__version__."""
        result = runner.invoke(app, ["--version"])
        assert __version__ in result.stdout, (
            f"Expected version '{__version__}' in output, got: {result.stdout}"
        )

    def test_version_matches_pyproject(self) -> None:
        """Version matches pyproject.toml [project].version."""
        import tomllib

        data = tomllib.loads(PYPROJECT.read_text())
        expected = data["project"]["version"]
        result = runner.invoke(app, ["--version"])
        assert expected in result.stdout, (
            f"Expected pyproject version '{expected}' in --version output, got: {result.stdout}"
        )

    def test_version_fast(self) -> None:
        """--version completes in under 2 seconds."""
        import time

        start = time.monotonic()
        result = runner.invoke(app, ["--version"])
        elapsed = time.monotonic() - start
        assert result.exit_code == 0
        assert elapsed < 2.0, f"--version took {elapsed:.2f}s (expected < 2s)"


# ---------------------------------------------------------------------------
# Subcommand stub tests
# ---------------------------------------------------------------------------


class TestSubcommandStubs:
    """Verify each subcommand stub exists and produces expected behavior."""

    def test_run_exists(self) -> None:
        """run command is registered."""
        result = runner.invoke(app, ["run", "--help"])
        assert result.exit_code == 0

    def test_dashboard_exists(self) -> None:
        """dashboard command is registered."""
        result = runner.invoke(app, ["dashboard", "--help"])
        assert result.exit_code == 0

    def test_list_integrations_exists(self) -> None:
        """list integrations command is registered."""
        result = runner.invoke(app, ["list", "integrations", "--help"])
        assert result.exit_code == 0

    def test_list_variants_exists(self) -> None:
        """list variants command is registered."""
        result = runner.invoke(app, ["list", "variants", "--help"])
        assert result.exit_code == 0

    def test_list_variants_accepts_integration_flag(self) -> None:
        """list variants --integration is accepted."""
        result = runner.invoke(app, ["list", "variants", "--integration", "cert-manager"])
        # Real implementation: should find matching scenarios; exit 0
        assert result.exit_code == 0

    def test_generate_pick_exists(self) -> None:
        """generate pick command is registered."""
        result = runner.invoke(app, ["generate", "pick", "--help"])
        assert result.exit_code == 0

    def test_generate_author_exists(self) -> None:
        """generate author command is registered."""
        result = runner.invoke(app, ["generate", "author", "--help"])
        assert result.exit_code == 0

    def test_generate_explore_exists(self) -> None:
        """generate explore command is registered."""
        result = runner.invoke(app, ["generate", "explore", "--help"])
        assert result.exit_code == 0

    def test_generate_author_accepts_description(self) -> None:
        """generate author accepts a description argument."""
        result = runner.invoke(app, ["generate", "author", "test description"])
        # Will exit 1 (stub), not 2 (arg error)
        assert result.exit_code == 1


# ---------------------------------------------------------------------------
# list and generate sub-command group tests
# ---------------------------------------------------------------------------


class TestListSubcommandGroup:
    """Verify the list sub-command group works correctly."""

    def test_list_no_args_shows_help(self) -> None:
        """list with no subcommand shows help."""
        result = runner.invoke(app, ["list"])
        # no_args_is_help=True should show help and exit non-zero
        assert result.exit_code != 0
        assert "Usage" in (result.stdout + result.stderr)

    def test_list_integrations_succeeds(self) -> None:
        """list integrations exits 0 with real implementation."""
        result = runner.invoke(app, ["list", "integrations"])
        assert result.exit_code == 0
        assert result.stdout.strip(), "Expected non-empty stdout"

    def test_list_variants_succeeds(self) -> None:
        """list variants exits 0 with real implementation."""
        result = runner.invoke(app, ["list", "variants"])
        assert result.exit_code == 0
        assert result.stdout.strip(), "Expected non-empty stdout"


class TestGenerateSubcommandGroup:
    """Verify the generate sub-command group works correctly."""

    def test_generate_no_args_shows_help(self) -> None:
        """generate with no subcommand shows help."""
        result = runner.invoke(app, ["generate"])
        assert result.exit_code != 0
        assert "Usage" in (result.stdout + result.stderr)

    def test_generate_pick_stub(self) -> None:
        """generate pick stub exits non-zero."""
        result = runner.invoke(app, ["generate", "pick"])
        assert result.exit_code == 1

    def test_generate_author_stub(self) -> None:
        """generate author stub exits non-zero."""
        result = runner.invoke(app, ["generate", "author", "a scenario"])
        assert result.exit_code == 1

    def test_generate_explore_stub(self) -> None:
        """generate explore stub exits non-zero."""
        result = runner.invoke(app, ["generate", "explore"])
        assert result.exit_code == 1
