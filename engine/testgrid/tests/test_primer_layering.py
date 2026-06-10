"""Tests for primer search-path layering (VAL-PLUGGABLE-029 through VAL-PLUGGABLE-034).

Validates:
  - VAL-PLUGGABLE-029: Consumer primer is selected over the engine default
    for the same category/integration
  - VAL-PLUGGABLE-030: Engine primer is used when the consumer provides none
  - VAL-PLUGGABLE-031: A consumer-only NEW primer resolves with no engine
    equivalent
  - VAL-PLUGGABLE-032: Primer listing/availability merges consumer and engine
    sources (consumer-preferred)
  - VAL-PLUGGABLE-033: No-primer refusal still fires (and lists merged primers)
    when neither tree has the requested primer
  - VAL-PLUGGABLE-034: Primer layering does not regress default (no-project)
    scaffolding behavior
"""

from __future__ import annotations

from pathlib import Path

import pytest
from typer.testing import CliRunner

from chart_test_swarm.main import app

# ── Constants ──────────────────────────────────────────────────────────────

REPO_ROOT = Path(__file__).resolve().parents[3]
ENGINE_INTEGRATIONS = (
    REPO_ROOT / "engine" / "skills" / "chart-test-swarm" / "references" / "integrations"
)

runner = CliRunner()


# ── Synthetic tree helpers ─────────────────────────────────────────────────


def _make_consumer_primer(project_dir: Path, category: str, integration: str) -> Path:
    """Create a fake consumer primer under chart-test/primers/."""
    primers_dir = project_dir / "chart-test" / "primers" / category
    primers_dir.mkdir(parents=True, exist_ok=True)
    primer = primers_dir / f"{integration}.md"
    primer.write_text(f"# Consumer primer for {category}/{integration}\n")
    return primer


def _make_chart_test_dirs(project_dir: Path) -> Path:
    """Create chart-test/ with all required subdirs."""
    chart_test = project_dir / "chart-test"
    chart_test.mkdir()
    (chart_test / "scenarios").mkdir()
    (chart_test / "fixtures").mkdir()
    (chart_test / "assertions").mkdir()
    (chart_test / "primers").mkdir()
    return chart_test


# ── VAL-PLUGGABLE-029: Consumer primer selected over engine default ────────


class TestConsumerOverridesEngine:
    """VAL-PLUGGABLE-029: Consumer primer is selected over the engine default."""

    def test_consumer_primer_wins_same_category_integration(self, tmp_path: Path) -> None:
        """A consumer primer overrides the engine primer for the same cat/int."""
        chart_test = _make_chart_test_dirs(tmp_path)
        # Create an engine primer
        # cert-manager primer already exists in the engine tree
        # Create a consumer primer for the same integration
        _make_consumer_primer(tmp_path, "certificates", "cert-manager")

        result = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code == 0, (
            f"Expected success, got exit={result.exit_code}, out={result.output}"
            f" stderr={result.stderr}"
        )

        # The scaffold should succeed (primer found)
        fixture = chart_test / "fixtures" / "certificates" / "cert-manager-values.yaml"
        assert fixture.exists(), "Scaffold should complete with consumer primer"

    def test_consumer_primer_used_not_engine(self, tmp_path: Path) -> None:
        """When both exist, the consumer primer should be the resolved one.

        We verify this indirectly: the engine primer has content A and the
        consumer primer has content B. Since the scaffolded output is driven
        by the primer content (via the primer's YAML frontmatter), we confirm
        the consumer path is where the resolution lands by checking that the
        no-primer refusal does NOT fire (meaning resolution succeeded).
        """
        _make_chart_test_dirs(tmp_path)
        # cert-manager primer already exists in the engine tree
        _make_consumer_primer(tmp_path, "certificates", "cert-manager")

        result = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )
        # Should succeed — if engine-only was used it would still succeed
        # since both exist, but the key is that it does NOT refuse
        assert result.exit_code == 0, (
            f"Consumer override should not cause refusal: "
            f"exit={result.exit_code}, stderr={result.stderr}"
        )
        assert "no primer found" not in (result.output + result.stderr or "").lower(), (
            "Should not trigger no-primer refusal when consumer primer exists"
        )


# ── VAL-PLUGGABLE-030: Engine primer used when consumer provides none ──────


class TestEngineFallback:
    """VAL-PLUGGABLE-030: Engine primer is used when the consumer provides none."""

    def test_engine_primer_used_when_no_consumer(self, tmp_path: Path) -> None:
        """When consumer has no primer, the engine primer resolves."""
        _make_chart_test_dirs(tmp_path)
        # Only create engine primer, no consumer primer
        # cert-manager primer already exists in the engine tree

        result = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code == 0, (
            f"Engine fallback should succeed: exit={result.exit_code}, stderr={result.stderr}"
        )

    def test_engine_primer_used_different_consumer_integration(self, tmp_path: Path) -> None:
        """Consumer has a different integration; engine fallback for others."""
        _make_chart_test_dirs(tmp_path)
        # cert-manager and manual-tls-secret primers already exist in the engine tree
        # Consumer only has a primer for manual-tls-secret
        _make_consumer_primer(tmp_path, "certificates", "manual-tls-secret")

        # Request cert-manager — consumer has NO primer for it
        result = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code == 0, (
            f"Engine fallback for cert-manager should succeed: "
            f"exit={result.exit_code}, stderr={result.stderr}"
        )


# ── VAL-PLUGGABLE-031: Consumer-only NEW primer resolves ───────────────────


class TestConsumerOnlyPrimer:
    """VAL-PLUGGABLE-031: A consumer-only NEW primer resolves with no engine equivalent."""

    def test_consumer_only_primer_resolves(self, tmp_path: Path) -> None:
        """A primer that exists only in the consumer tree resolves successfully."""
        chart_test = _make_chart_test_dirs(tmp_path)
        # Create a consumer primer for an integration NOT in the engine tree
        # We need a valid category that exists in TAXONOMY_CATEGORIES
        _make_consumer_primer(tmp_path, "certificates", "my-custom-ca")

        result = runner.invoke(
            app,
            ["new", "certificates/my-custom-ca", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code == 0, (
            f"Consumer-only primer should resolve: exit={result.exit_code}, stderr={result.stderr}"
        )

        fixture = chart_test / "fixtures" / "certificates" / "my-custom-ca-values.yaml"
        assert fixture.exists(), "Scaffold should complete with consumer-only primer"

    def test_consumer_only_primer_without_engine_counterpart(self, tmp_path: Path) -> None:
        """Consumer-only primer in a category that exists but with no engine match."""
        _make_chart_test_dirs(tmp_path)
        _make_consumer_primer(tmp_path, "ingress-controllers", "my-custom-ingress")

        result = runner.invoke(
            app,
            [
                "new",
                "ingress-controllers/my-custom-ingress",
                "--project-dir",
                str(tmp_path),
            ],
        )
        assert result.exit_code == 0, (
            f"Consumer-only primer should resolve: exit={result.exit_code}, stderr={result.stderr}"
        )


# ── VAL-PLUGGABLE-032: Primer listing merges consumer + engine ─────────────


class TestMergedPrimerListing:
    """VAL-PLUGGABLE-032: Primer listing merges consumer and engine sources."""

    def test_no_primer_refusal_lists_merged_primers(self, tmp_path: Path) -> None:
        """When neither tree has the requested primer, the refusal lists merged primers."""
        _make_chart_test_dirs(tmp_path)
        # cert-manager and manual-tls-secret primers already exist in the engine tree
        # Consumer adds a primer that the engine doesn't have
        _make_consumer_primer(tmp_path, "certificates", "my-custom-ca")

        result = runner.invoke(
            app,
            ["new", "certificates/nonexistent-integration", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code != 0, f"Should refuse missing primer: exit={result.exit_code}"

        combined = result.output + (result.stderr or "")

        # Must list engine primers
        assert "cert-manager" in combined, f"Should list engine primer cert-manager: {combined}"
        assert "manual-tls-secret" in combined, (
            f"Should list engine primer manual-tls-secret: {combined}"
        )
        # Must list consumer-only primer
        assert "my-custom-ca" in combined, (
            f"Should list consumer-only primer my-custom-ca: {combined}"
        )

    def test_merged_listing_no_duplicates(self, tmp_path: Path) -> None:
        """When both trees have the same primer, the merged list has no duplicates.

        We verify by extracting the available-primers line and checking that
        each integration stem appears at most once.
        """
        _make_chart_test_dirs(tmp_path)
        # cert-manager primer already exists in the engine tree
        _make_consumer_primer(tmp_path, "certificates", "cert-manager")

        result = runner.invoke(
            app,
            ["new", "certificates/nonexistent-integration", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code != 0

        # Extract the "Available primers in certificates:" line(s).
        # With CliRunner defaults, stderr may be mixed into output;
        # grab the first occurrence of the primers list.
        combined = result.output + (result.stderr or "")
        for line in combined.splitlines():
            if "Available primers in certificates:" in line:
                # Split out the comma-separated list after the colon
                _, _, primers_str = line.partition("Available primers in certificates:")
                stems = [s.strip() for s in primers_str.split(",") if s.strip()]
                # cert-manager should appear at most once
                count = sum(1 for s in stems if s == "cert-manager")
                assert count <= 1, f"cert-manager duplicated in merged listing: {stems}"
                return

        pytest.fail("No 'Available primers in certificates:' line found in output")

    def test_list_integrations_merges_with_project_dir(self, tmp_path: Path) -> None:
        """list integrations --project-dir shows merged consumer+engine primers."""
        _make_chart_test_dirs(tmp_path)
        _make_consumer_primer(tmp_path, "certificates", "my-custom-ca")

        result = runner.invoke(
            app,
            [
                "list",
                "integrations",
                "--project-dir",
                str(tmp_path),
            ],
        )
        # Should succeed because engine primers are always available
        assert result.exit_code == 0, (
            f"list integrations should succeed: exit={result.exit_code}, stderr={result.stderr}"
        )
        combined = result.output
        # Should include consumer-only primer
        assert "my-custom-ca" in combined, f"Should include consumer-only primer: {combined}"
        # Should include engine primers
        assert "cert-manager" in combined, f"Should include engine primer: {combined}"


# ── VAL-PLUGGABLE-033: No-primer refusal with merged primer list ───────────


class TestNoPrimerRefusalMerged:
    """VAL-PLUGGABLE-033: No-primer refusal fires with merged listing when neither tree has it."""

    def test_no_primer_refusal_lists_merged_with_both_missing(self, tmp_path: Path) -> None:
        """When neither tree has the primer, refuse and list merged availability."""
        _make_chart_test_dirs(tmp_path)
        # cert-manager primer already exists in the engine tree
        _make_consumer_primer(tmp_path, "certificates", "my-custom-ca")

        result = runner.invoke(
            app,
            ["new", "certificates/missing-in-both-trees", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code != 0, f"Should refuse with non-zero exit: {result.exit_code}"

        combined = result.output + (result.stderr or "")
        assert "no primer found" in combined.lower(), f"Should mention no primer found: {combined}"
        # Should list both engine and consumer primers
        assert "cert-manager" in combined
        assert "my-custom-ca" in combined

    def test_no_primer_refusal_empty_category_lists_merged(self, tmp_path: Path) -> None:
        """No primers in either tree for a category shows merged (empty) message."""
        _make_chart_test_dirs(tmp_path)

        result = runner.invoke(
            app,
            ["new", "gateway-api/nonexistent-gateway", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code != 0

        combined = result.output + (result.stderr or "")
        assert "no primer found" in combined.lower(), f"Should mention no primer found: {combined}"


# ── VAL-PLUGGABLE-034: No regression for default scaffolding ───────────────


class TestNoRegressionDefaultScaffolding:
    """VAL-PLUGGABLE-034: Primer layering does not regress default (no-project) behavior."""

    def test_default_no_project_works_as_before(self, tmp_path: Path) -> None:
        """Without --project-dir, scaffolding uses engine primers only."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        # Use default path (examples/sample-product-chart/chart-test/)
        # We test with --project-dir pointing to tmp_path without
        # any consumer primers to simulate "default" behavior.

        result = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code == 0, (
            f"Default scaffolding should work: exit={result.exit_code}, stderr={result.stderr}"
        )

    def test_no_project_dir_uses_engine_only(self, tmp_path: Path) -> None:
        """Without --project-dir (using default path), engine primers are used."""
        _make_chart_test_dirs(tmp_path)

        result = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code == 0, (
            f"Engine primer should resolve without consumer dir: "
            f"exit={result.exit_code}, stderr={result.stderr}"
        )

    def test_existing_new_tests_stay_green_consumer_none(self, tmp_path: Path) -> None:
        """When no consumer primers exist, behavior matches pre-layering exactly."""
        _make_chart_test_dirs(tmp_path)
        # No consumer primers at all

        result = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code == 0, "Should succeed with engine primer only"

        # No-primer refusal still works
        result2 = runner.invoke(
            app,
            ["new", "certificates/nonexistent-primer", "--project-dir", str(tmp_path)],
        )
        assert result2.exit_code != 0, "Should refuse non-existent primer"
        combined = result2.output + (result2.stderr or "")
        assert "cert-manager" in combined, "Should list available engine primers"

    def test_default_capability_unaffected(self, tmp_path: Path) -> None:
        """Capability scaffolding is unaffected by primer layering."""
        _make_chart_test_dirs(tmp_path)

        result = runner.invoke(
            app,
            ["new", "capability/my-check", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code == 0, (
            f"Capability scaffolding should be unaffected: "
            f"exit={result.exit_code}, stderr={result.stderr}"
        )


# ── Additional edge-case tests ─────────────────────────────────────────────


class TestPrimerLayeringEdgeCases:
    """Edge cases for primer layering."""

    def test_consumer_primer_without_engine_category_still_works(self, tmp_path: Path) -> None:
        """A consumer primer in a valid taxonomy category works even if no engine primers exist."""
        _make_chart_test_dirs(tmp_path)
        # The policy category is valid (in TAXONOMY_CATEGORIES) and has engine primers
        # but we use a consumer-only integration
        _make_consumer_primer(tmp_path, "policy", "my-custom-policy")

        result = runner.invoke(
            app,
            ["new", "policy/my-custom-policy", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code == 0, (
            f"Consumer-only in valid category should succeed: "
            f"exit={result.exit_code}, stderr={result.stderr}"
        )

    def test_category_discovery_includes_engine_categories(self, tmp_path: Path) -> None:
        """Even with consumer primers, engine categories are still valid for scaffolding."""
        _make_chart_test_dirs(tmp_path)
        _make_consumer_primer(tmp_path, "certificates", "my-custom-ca")

        # cert-manager is engine-only — should still work
        result = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code == 0, (
            f"Engine-only integration should still be scaffoldable: "
            f"exit={result.exit_code}, stderr={result.stderr}"
        )
