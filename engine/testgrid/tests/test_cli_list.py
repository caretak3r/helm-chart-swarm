"""Tests for F9.4 — list integrations and list variants subcommands.

Validates:
  - VAL-CLI-012: list integrations enumerates (category, integration) tuples
  - VAL-CLI-013: list variants --integration filters by integration name
  - VAL-CLI-024: list integrations emits exactly 6 categories on production tree
"""

from __future__ import annotations

import tempfile
from pathlib import Path

from typer.testing import CliRunner

from chart_test_swarm.main import app

runner = CliRunner()


# ---------------------------------------------------------------------------
# Synthetic fixture helpers
# ---------------------------------------------------------------------------


def make_integrations_tree(tmp: Path, entries: list[tuple[str, str]]) -> Path:
    """Create a synthetic integrations tree with *entries*.

    Each entry is (category, integration).  Creates ``<category>/<integration>.md``.
    Returns the root of the synthetic tree.
    """
    for category, integration in entries:
        cat_dir = tmp / category
        cat_dir.mkdir(parents=True, exist_ok=True)
        (cat_dir / f"{integration}.md").write_text(f"# {integration}\n\nPrimer content.\n")
    return tmp


def make_scenario_tree(tmp: Path, filenames: list[str]) -> Path:
    """Create a synthetic scenario directory with empty YAML files."""
    for name in filenames:
        (tmp / name).write_text("---\nid: test\n")
    return tmp


# ---------------------------------------------------------------------------
# VAL-CLI-012: list integrations — synthetic fixture
# ---------------------------------------------------------------------------


class TestListIntegrations:
    """VAL-CLI-012: list integrations enumerates (category, integration) tuples."""

    def test_emits_sorted_entries(self) -> None:
        """With two categories, output is sorted and contains both entries."""
        with tempfile.TemporaryDirectory() as tmp:
            root = make_integrations_tree(
                Path(tmp),
                [
                    ("certificates", "cert-manager"),
                    ("ingress-controllers", "nginx-ingress"),
                ],
            )
            result = runner.invoke(app, ["list", "integrations", "--root", root])
            assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"
            lines = result.stdout.strip().split("\n")
            assert len(lines) == 2, f"Expected 2 lines, got {len(lines)}: {lines}"

            # Sorted: certificates before ingress-controllers
            assert "certificates" in lines[0]
            assert "cert-manager" in lines[0]
            assert "ingress-controllers" in lines[1]
            assert "nginx-ingress" in lines[1]

    def test_skips_stray_files(self) -> None:
        """Stray files at the top level are skipped, only dirs counted."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_integrations_tree(root, [("policy", "kyverno")])
            # Add a stray file at the top level
            (root / "NOT_A_DIR.md").write_text("stray")
            # Add a nested stray
            (root / "policy" / "README.txt").write_text("not a primer")

            result = runner.invoke(app, ["list", "integrations", "--root", str(root)])
            assert result.exit_code == 0
            lines = result.stdout.strip().split("\n")
            assert len(lines) == 1, f"Expected 1 line, got {len(lines)}: {lines}"
            assert "policy" in lines[0]
            assert "kyverno" in lines[0]

    def test_zero_categories_exits_nonzero(self) -> None:
        """Empty root exits 1 with a clear message."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            root.mkdir(parents=True, exist_ok=True)
            result = runner.invoke(app, ["list", "integrations", "--root", str(root)])
            assert result.exit_code == 1, f"Expected exit 1, got {result.exit_code}"
            assert "no integrations found" in result.stderr.lower()

    def test_empty_category_skipped(self) -> None:
        """An empty category directory with no .md files is skipped."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            empty_dir = root / "empty-category"
            empty_dir.mkdir(parents=True)
            make_integrations_tree(root, [("service-mesh", "istio")])

            result = runner.invoke(app, ["list", "integrations", "--root", str(root)])
            assert result.exit_code == 0
            lines = result.stdout.strip().split("\n")
            assert len(lines) == 1, f"Expected 1 line (empty-category skipped): {lines}"

    def test_missing_root_exits_nonzero(self) -> None:
        """Non-existent root exits 1 with a clear error."""
        result = runner.invoke(app, ["list", "integrations", "--root", "/tmp/non_existent_dir_xyz"])
        assert result.exit_code == 1
        assert "not found" in result.stderr.lower()

    def test_multiple_integrations_per_category(self) -> None:
        """One category with multiple integrations lists all, sorted."""
        with tempfile.TemporaryDirectory() as tmp:
            root = make_integrations_tree(
                Path(tmp),
                [
                    ("certificates", "cert-manager"),
                    ("certificates", "manual-tls-secret"),
                    ("certificates", "mounted-tls-certs"),
                ],
            )
            result = runner.invoke(app, ["list", "integrations", "--root", str(root)])
            assert result.exit_code == 0
            lines = result.stdout.strip().split("\n")
            assert len(lines) == 3
            assert "certificates\tcert-manager" in lines
            assert "certificates\tmanual-tls-secret" in lines
            assert "certificates\tmounted-tls-certs" in lines

    def test_sort_order(self) -> None:
        """Entries are sorted first by category, then by integration."""
        with tempfile.TemporaryDirectory() as tmp:
            root = make_integrations_tree(
                Path(tmp),
                [
                    ("service-mesh", "linkerd"),
                    ("certificates", "cert-manager"),
                    ("service-mesh", "istio"),
                ],
            )
            result = runner.invoke(app, ["list", "integrations", "--root", str(root)])
            assert result.exit_code == 0
            lines = result.stdout.strip().split("\n")
            assert len(lines) == 3
            # certificates comes before service-mesh alphabetically
            assert "certificates" in lines[0]
            # Within service-mesh: istio before linkerd
            assert lines[1] == "service-mesh\tistio"
            assert lines[2] == "service-mesh\tlinkerd"

    # -----------------------------------------------------------------------
    # VAL-CLI-024: Production tree emits exactly 6 categories
    # -----------------------------------------------------------------------

    def test_production_tree_emits_six_categories(self) -> None:
        """list integrations against production tree emits exactly 6 categories."""
        result = runner.invoke(app, ["list", "integrations"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"

        output = result.stdout.strip()
        lines = output.split("\n")
        assert len(lines) >= 6, f"Expected at least 6 lines, got {len(lines)}: {lines}"

        # Extract unique categories
        categories = set()
        for line in lines:
            parts = line.split("\t")
            if len(parts) >= 1:
                categories.add(parts[0])

        expected = {
            "certificates",
            "ingress-controllers",
            "gateway-api",
            "service-mesh",
            "policy",
            "cloud-native",
        }
        assert categories == expected, (
            f"Expected exactly {sorted(expected)}, got {sorted(categories)}"
        )

    def test_production_tree_sorted_output(self) -> None:
        """Output is sorted by category, then by integration."""
        result = runner.invoke(app, ["list", "integrations"])
        assert result.exit_code == 0

        lines = result.stdout.strip().split("\n")
        # Verify lines are in sorted order
        assert lines == sorted(lines), f"Output not sorted: {lines}"

    def test_production_tree_no_spurious_entries(self) -> None:
        """No stray file or directory appears in the output."""
        result = runner.invoke(app, ["list", "integrations"])
        assert result.exit_code == 0

        lines = result.stdout.strip().split("\n")
        for line in lines:
            parts = line.split("\t")
            assert len(parts) == 2, f"Line should have category and integration: {line}"
            cat = parts[0]
            assert cat in {
                "certificates",
                "ingress-controllers",
                "gateway-api",
                "service-mesh",
                "policy",
                "cloud-native",
            }, f"Unexpected category: {cat}"


# ---------------------------------------------------------------------------
# VAL-CLI-013: list variants — filtering by integration
# ---------------------------------------------------------------------------


class TestListVariants:
    """VAL-CLI-013: list variants --integration filters by integration name."""

    def test_filters_by_integration_name(self) -> None:
        """--integration cert-manager lists only matching scenarios."""
        with tempfile.TemporaryDirectory() as tmp:
            root = make_scenario_tree(
                Path(tmp),
                [
                    "certificates-cert-manager-self-signed.yaml",
                    "certificates-cert-manager-letsencrypt.yaml",
                    "ingress-controllers-nginx-ingress-basic.yaml",
                    "minimal.yaml",
                ],
            )
            result = runner.invoke(
                app,
                ["list", "variants", "--integration", "cert-manager", "--scenarios-dir", root],
            )
            assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"
            lines = result.stdout.strip().split("\n")
            assert len(lines) == 2, f"Expected 2 matches, got {len(lines)}: {lines}"
            assert any("cert-manager" in line for line in lines)
            assert not any("nginx-ingress" in line for line in lines)

    def test_no_integration_lists_all(self) -> None:
        """Without --integration, all scenarios are listed."""
        with tempfile.TemporaryDirectory() as tmp:
            root = make_scenario_tree(
                Path(tmp),
                [
                    "cert-manager-self-signed.yaml",
                    "nginx-basic.yaml",
                    "minimal.yaml",
                ],
            )
            result = runner.invoke(
                app,
                ["list", "variants", "--scenarios-dir", root],
            )
            assert result.exit_code == 0
            lines = result.stdout.strip().split("\n")
            assert len(lines) == 3, f"Expected 3 lines, got {len(lines)}: {lines}"

    def test_case_insensitive_match(self) -> None:
        """--integration matching is case-insensitive."""
        with tempfile.TemporaryDirectory() as tmp:
            root = make_scenario_tree(
                Path(tmp),
                ["CERT-MANAGER-self-signed.yaml", "cert-manager-letsencrypt.yaml"],
            )
            result = runner.invoke(
                app,
                ["list", "variants", "--integration", "cert-manager", "--scenarios-dir", root],
            )
            assert result.exit_code == 0
            lines = result.stdout.strip().split("\n")
            assert len(lines) == 2

    def test_no_match_exits_nonzero(self) -> None:
        """No matching integration exits 1 with error message."""
        with tempfile.TemporaryDirectory() as tmp:
            root = make_scenario_tree(Path(tmp), ["nginx-basic.yaml"])
            result = runner.invoke(
                app,
                ["list", "variants", "--integration", "nonexistent", "--scenarios-dir", root],
            )
            assert result.exit_code == 1
            assert "no scenario variants found" in result.stderr.lower()
            assert "nonexistent" in result.stderr.lower()

    def test_missing_scenarios_dir_exits_nonzero(self) -> None:
        """Non-existent scenarios-dir exits 1."""
        result = runner.invoke(
            app,
            [
                "list",
                "variants",
                "--scenarios-dir",
                "/tmp/non_existent_scenarios_dir_xyz",
            ],
        )
        assert result.exit_code == 1
        assert "not found" in result.stderr.lower()

    def test_production_list_variants_all(self) -> None:
        """list variants against production tree lists all scenarios."""
        result = runner.invoke(app, ["list", "variants"])
        assert result.exit_code == 0
        lines = result.stdout.strip().split("\n")
        assert len(lines) >= 10, f"Expected at least 10 variants, got {len(lines)}"
        # Check all lines are scenario paths
        for line in lines:
            assert line.endswith(".yaml") or line.endswith(".yml"), f"Unexpected: {line}"

    def test_production_list_variants_filtered(self) -> None:
        """list variants --integration cert-manager returns cert-manager scenarios."""
        result = runner.invoke(app, ["list", "variants", "--integration", "cert-manager"])
        assert result.exit_code == 0
        lines = result.stdout.strip().split("\n")
        assert len(lines) >= 4, f"Expected at least 4 cert-manager variants, got {len(lines)}"
        for line in lines:
            assert "cert-manager" in line.lower(), f"Non-matching: {line}"


# ---------------------------------------------------------------------------
# VAL-CLI-015: --help, valid invocation, invalid-flag for list subcommands
# ---------------------------------------------------------------------------


class TestListHelp:
    """--help and invalid-flag coverage for list subcommands."""

    # -- list integrations --help ----------------------------------------------

    def test_list_integrations_help_exits_0(self) -> None:
        result = runner.invoke(app, ["list", "integrations", "--help"])
        assert result.exit_code == 0

    def test_list_integrations_help_has_usage(self) -> None:
        result = runner.invoke(app, ["list", "integrations", "--help"])
        assert "Usage" in result.stdout

    def test_list_integrations_help_mentions_root(self) -> None:
        result = runner.invoke(app, ["list", "integrations", "--help"])
        assert "--root" in result.stdout

    # -- list variants --help -------------------------------------------------

    def test_list_variants_help_exits_0(self) -> None:
        result = runner.invoke(app, ["list", "variants", "--help"])
        assert result.exit_code == 0

    def test_list_variants_help_has_usage(self) -> None:
        result = runner.invoke(app, ["list", "variants", "--help"])
        assert "Usage" in result.stdout

    def test_list_variants_help_mentions_integration(self) -> None:
        result = runner.invoke(app, ["list", "variants", "--help"])
        assert "--integration" in result.stdout

    # -- invalid flag ----------------------------------------------------------

    def test_list_integrations_unknown_flag(self) -> None:
        """Unknown flag exits non-zero."""
        result = runner.invoke(app, ["list", "integrations", "--nonexistent-flag"])
        assert result.exit_code != 0

    def test_list_variants_unknown_flag(self) -> None:
        """Unknown flag exits non-zero."""
        result = runner.invoke(app, ["list", "variants", "--nonexistent-flag"])
        assert result.exit_code != 0
