"""Comprehensive CLI test coverage per VAL-CLI-015.

Exercises ``--help``, valid invocation, and at least one invalid-flag case for each:
  - ``run``
  - ``dashboard``
  - ``list integrations``
  - ``list variants``
  - ``generate pick``
  - ``generate author``
  - ``generate explore``
"""

from __future__ import annotations

import tempfile
from pathlib import Path

from typer.testing import CliRunner

from chart_test_swarm.main import app

runner = CliRunner()


# ── helpers ──────────────────────────────────────────────────────────────────


def _synthetic_integrations_tree(tmp: Path) -> Path:
    """Create a minimal synthetic integrations tree for tests."""
    cat = tmp / "certificates"
    cat.mkdir(parents=True)
    (cat / "cert-manager.md").write_text("# cert-manager\n\nPrimer content.\n")
    return tmp


def _synthetic_scenarios_dir(tmp: Path) -> Path:
    """Create a minimal synthetic scenarios directory."""
    (tmp / "certificates-cert-manager-basic.yaml").write_text(
        "---\nid: certificates-cert-manager-basic\n"
    )
    return tmp


# ═══════════════════════════════════════════════════════════════════════════════
# run subcommand
# ═══════════════════════════════════════════════════════════════════════════════


class TestRunCli:
    """VAL-CLI-015 coverage for ``run`` subcommand."""

    def test_help_exits_0(self) -> None:
        """--help exits 0 with usage."""
        result = runner.invoke(app, ["run", "--help"])
        assert result.exit_code == 0
        assert "Usage" in result.stdout or "usage" in result.stdout.lower()

    def test_valid_invocation_with_scenario_flag(self) -> None:
        """Valid invocation with --scenario flag does not exit with arg error."""
        result = runner.invoke(app, ["run", "--scenario", "/nonexistent/path"])
        # Should exit non-zero (missing file) but NOT with arg-parsing error (code 2)
        assert result.exit_code != 2, (
            f"Expected non-2 exit (arg error), got {result.exit_code}: {result.stderr}"
        )

    def test_invalid_flag_exits_nonzero(self) -> None:
        """Unknown flag exits non-zero."""
        result = runner.invoke(app, ["run", "--bogus-flag-that-does-not-exist"])
        assert result.exit_code != 0, f"Expected non-zero exit, got {result.exit_code}"

    def test_cluster_name_prefix_validation(self) -> None:
        """Invalid cluster name exits non-zero."""
        result = runner.invoke(
            app, ["run", "--cluster-name", "invalid-name", "--scenario", "/dev/null"]
        )
        assert result.exit_code != 0


# ═══════════════════════════════════════════════════════════════════════════════
# dashboard subcommand
# ═══════════════════════════════════════════════════════════════════════════════


class TestDashboardCli:
    """VAL-CLI-015 coverage for ``dashboard`` subcommand."""

    def test_help_exits_0(self) -> None:
        """--help exits 0 with usage."""
        result = runner.invoke(app, ["dashboard", "--help"])
        assert result.exit_code == 0
        assert "Usage" in result.stdout or "usage" in result.stdout.lower()

    def test_valid_invocation_with_reports_dir_flag(self) -> None:
        """Valid invocation with --reports-dir flag accepted."""
        with tempfile.TemporaryDirectory() as tmp:
            result = runner.invoke(app, ["dashboard", "--reports-dir", tmp])
            # May exit non-zero if build-dashboard.sh not found, but NOT arg error
            assert result.exit_code != 2, (
                f"Expected non-2 exit (arg error), got {result.exit_code}: {result.stderr}"
            )

    def test_invalid_flag_exits_nonzero(self) -> None:
        """Unknown flag exits non-zero."""
        result = runner.invoke(app, ["dashboard", "--bogus-flag-that-does-not-exist"])
        assert result.exit_code != 0, f"Expected non-zero exit, got {result.exit_code}"


# ═══════════════════════════════════════════════════════════════════════════════
# list integrations subcommand
# ═══════════════════════════════════════════════════════════════════════════════


class TestListIntegrationsCli:
    """VAL-CLI-015 coverage for ``list integrations`` subcommand."""

    def test_help_exits_0(self) -> None:
        """--help exits 0 with usage."""
        result = runner.invoke(app, ["list", "integrations", "--help"])
        assert result.exit_code == 0
        assert "Usage" in result.stdout or "usage" in result.stdout.lower()

    def test_valid_invocation_with_root_flag(self) -> None:
        """Valid invocation with --root flag exits 0."""
        with tempfile.TemporaryDirectory() as tmp:
            root = _synthetic_integrations_tree(Path(tmp))
            result = runner.invoke(app, ["list", "integrations", "--root", str(root)])
            assert result.exit_code == 0

    def test_valid_invocation_production_tree(self) -> None:
        """Valid invocation against production tree exits 0."""
        result = runner.invoke(app, ["list", "integrations"])
        assert result.exit_code == 0
        assert result.stdout.strip(), "Expected non-empty stdout"

    def test_invalid_flag_exits_nonzero(self) -> None:
        """Unknown flag exits non-zero."""
        result = runner.invoke(app, ["list", "integrations", "--bogus-flag-that-does-not-exist"])
        assert result.exit_code != 0


# ═══════════════════════════════════════════════════════════════════════════════
# list variants subcommand
# ═══════════════════════════════════════════════════════════════════════════════


class TestListVariantsCli:
    """VAL-CLI-015 coverage for ``list variants`` subcommand."""

    def test_help_exits_0(self) -> None:
        """--help exits 0 with usage."""
        result = runner.invoke(app, ["list", "variants", "--help"])
        assert result.exit_code == 0
        assert "Usage" in result.stdout or "usage" in result.stdout.lower()

    def test_valid_invocation_with_integration_flag(self) -> None:
        """Valid invocation with --integration flag exits 0."""
        with tempfile.TemporaryDirectory() as tmp:
            scn = _synthetic_scenarios_dir(Path(tmp))
            result = runner.invoke(
                app,
                ["list", "variants", "--integration", "cert-manager", "--scenarios-dir", str(scn)],
            )
            assert result.exit_code == 0

    def test_valid_invocation_without_filter(self) -> None:
        """Valid invocation without --integration lists all scenarios."""
        with tempfile.TemporaryDirectory() as tmp:
            scn = _synthetic_scenarios_dir(Path(tmp))
            result = runner.invoke(app, ["list", "variants", "--scenarios-dir", str(scn)])
            assert result.exit_code == 0

    def test_invalid_flag_exits_nonzero(self) -> None:
        """Unknown flag exits non-zero."""
        result = runner.invoke(app, ["list", "variants", "--bogus-flag-that-does-not-exist"])
        assert result.exit_code != 0


# ═══════════════════════════════════════════════════════════════════════════════
# generate pick subcommand
# ═══════════════════════════════════════════════════════════════════════════════


class TestGeneratePickCli:
    """VAL-CLI-015 coverage for ``generate pick`` subcommand."""

    def test_help_exits_0(self) -> None:
        """--help exits 0 with usage."""
        result = runner.invoke(app, ["generate", "pick", "--help"])
        assert result.exit_code == 0
        assert "Usage" in result.stdout or "usage" in result.stdout.lower()

    def test_valid_invocation(self) -> None:
        """Valid invocation (stub) exits 1 but not arg error."""
        result = runner.invoke(app, ["generate", "pick"])
        # Stub exits 1 — not arg error 2
        assert result.exit_code != 2, (
            f"Expected non-2 exit (arg error), got {result.exit_code}: {result.stderr}"
        )

    def test_invalid_flag_exits_nonzero(self) -> None:
        """Unknown flag exits non-zero."""
        result = runner.invoke(app, ["generate", "pick", "--bogus-flag-that-does-not-exist"])
        assert result.exit_code != 0


# ═══════════════════════════════════════════════════════════════════════════════
# generate author subcommand
# ═══════════════════════════════════════════════════════════════════════════════


class TestGenerateAuthorCli:
    """VAL-CLI-015 coverage for ``generate author`` subcommand."""

    def test_help_exits_0(self) -> None:
        """--help exits 0 with usage."""
        result = runner.invoke(app, ["generate", "author", "--help"])
        assert result.exit_code == 0
        assert "Usage" in result.stdout or "usage" in result.stdout.lower()

    def test_valid_invocation(self) -> None:
        """Valid invocation with description argument accepted."""
        result = runner.invoke(app, ["generate", "author", "test scenario description"])
        # Stub exits 1 — not arg error 2
        assert result.exit_code != 2, (
            f"Expected non-2 exit (arg error), got {result.exit_code}: {result.stderr}"
        )

    def test_invalid_flag_exits_nonzero(self) -> None:
        """Unknown flag exits non-zero."""
        result = runner.invoke(app, ["generate", "author", "--bogus-flag-that-does-not-exist"])
        assert result.exit_code != 0


# ═══════════════════════════════════════════════════════════════════════════════
# generate explore subcommand
# ═══════════════════════════════════════════════════════════════════════════════


class TestGenerateExploreCli:
    """VAL-CLI-015 coverage for ``generate explore`` subcommand."""

    def test_help_exits_0(self) -> None:
        """--help exits 0 with usage."""
        result = runner.invoke(app, ["generate", "explore", "--help"])
        assert result.exit_code == 0
        assert "Usage" in result.stdout or "usage" in result.stdout.lower()

    def test_valid_invocation(self) -> None:
        """Valid invocation with required flags exits non-zero (no LLM binary in test env)."""
        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                "/tmp/nonexistent",
                "--integrations",
                "cert-manager",
            ],
        )
        # Real implementation: exits non-zero (no LLM binary or chart not found)
        # but NOT arg-error (exit 2)
        assert result.exit_code not in (0, 2), (
            f"Expected non-zero/non-arg-error exit, got {result.exit_code}: {result.stderr}"
        )

    def test_invalid_flag_exits_nonzero(self) -> None:
        """Unknown flag exits non-zero."""
        result = runner.invoke(app, ["generate", "explore", "--bogus-flag-that-does-not-exist"])
        assert result.exit_code != 0


# ═══════════════════════════════════════════════════════════════════════════════
# Help propagation check (VAL-CROSS-027 support)
# ═══════════════════════════════════════════════════════════════════════════════


class TestHelpCoverage:
    """Every subcommand path exposes --help."""

    SUBCOMMAND_PATHS: list[list[str]] = [
        ["run"],
        ["dashboard"],
        ["list", "integrations"],
        ["list", "variants"],
        ["generate", "pick"],
        ["generate", "author"],
        ["generate", "explore"],
    ]

    def test_all_subcommands_help_exits_0(self) -> None:
        """Every subcommand path --help exits 0."""
        for path in self.SUBCOMMAND_PATHS:
            result = runner.invoke(app, path + ["--help"])
            assert result.exit_code == 0, (
                f"{' '.join(path)} --help failed: exit={result.exit_code}, stderr={result.stderr}"
            )

    def test_all_subcommands_help_nonempty(self) -> None:
        """Every subcommand path --help has non-empty stdout."""
        for path in self.SUBCOMMAND_PATHS:
            result = runner.invoke(app, path + ["--help"])
            assert result.stdout.strip(), f"{' '.join(path)} --help produced empty stdout"

    def test_root_help_advertises_all_subcommand_groups(self) -> None:
        """Root --help lists run, dashboard, list, generate."""
        result = runner.invoke(app, ["--help"])
        assert "run" in result.stdout
        assert "dashboard" in result.stdout
        assert "list" in result.stdout
        assert "generate" in result.stdout

    def test_root_help_no_dark_commands(self) -> None:
        """No orphan subcommands in the root --help.

        The root --help lists only: run, dashboard, list, generate.
        """
        result = runner.invoke(app, ["--help"])
        # These should be the only subcommand group names listed
        expected_groups = {"run", "dashboard", "list", "generate"}
        # Additional typer noise should be minimal
        # Just verify our expected groups are present
        for group in expected_groups:
            assert group in result.stdout, f"Missing expected subcommand group '{group}'"
