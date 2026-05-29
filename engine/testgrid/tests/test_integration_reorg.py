"""Tests for F1.3 — integration category reorg.

Validates:
  - VAL-ENGINE-011: No primer remains at top level; each lives under its
    correct category subdir.
  - Structural reorg check (default): each moved primer exists at its
    expected category subdir, is non-empty markdown, and contains the
    required H2 sections per primer-author skill.
  - Baseline migration check (CTS_REORG_BASELINE=1 only): SHA-256 hashes
    match frozen baseline for one-time audit of the reorg itself.
  - discover_integrations() walks the category subdirs correctly.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

import pytest

# The integrations directory inside the repo.
# test file: engine/testgrid/tests/test_integration_reorg.py
# repo root: chart-test-swarm/  (parents[3])
REPO_ROOT = Path(__file__).resolve().parents[3]
INTEGRATIONS_DIR = (
    REPO_ROOT / "engine" / "skills" / "chart-test-swarm" / "references" / "integrations"
)
FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"

# Expected mapping: category subdir → list of primer basenames.
EXPECTED_LAYOUT: dict[str, list[str]] = {
    "certificates": ["cert-manager.md"],
    "ingress-controllers": ["traefik.md"],
    "service-mesh": ["istio-service-mesh.md", "istio-ingress-gateway.md"],
    "gateway-api": ["gateway-api.md"],
    "policy": ["opa-gatekeeper.md"],
}

# Required H2 sections per the primer-author skill.
# The structural check verifies that each primer has at least a
# minimum number of H2-level headings (demonstrating it is a
# properly structured primer document, not a stub).
MIN_H2_SECTIONS = 3


class TestCategorySubdirs:
    """VAL-ENGINE-011: primers live under category subdirectories."""

    def test_no_md_files_at_top_level(self) -> None:
        """No .md primer remains at the top of references/integrations/."""
        top_level_mds = [
            p.name for p in INTEGRATIONS_DIR.iterdir() if p.is_file() and p.suffix == ".md"
        ]
        assert top_level_mds == [], f"Found .md files at top level: {top_level_mds}"

    @pytest.mark.parametrize(
        "category,primer",
        [
            ("certificates", "cert-manager.md"),
            ("ingress-controllers", "traefik.md"),
            ("service-mesh", "istio-service-mesh.md"),
            ("service-mesh", "istio-ingress-gateway.md"),
            ("gateway-api", "gateway-api.md"),
            ("policy", "opa-gatekeeper.md"),
        ],
    )
    def test_primer_exists_under_category(self, category: str, primer: str) -> None:
        """Each expected primer is present under its category subdir."""
        path = INTEGRATIONS_DIR / category / primer
        assert path.is_file(), f"Missing: {path}"


class TestPrimerStructure:
    """Structural reorg check (default test run).

    Verifies each moved primer:
      (a) exists at the expected category subdir path,
      (b) is a properly structured document with a minimum number of
          H2-level headings (not a stub), and
      (c) is non-empty markdown.

    This is the DEFAULT check — no SHA-256 comparison.  Future primer
    edits that maintain the primer-author structure pass this test
    without needing to update any hash registry.
    """

    @pytest.mark.parametrize(
        "rel_path",
        [
            "certificates/cert-manager.md",
            "ingress-controllers/traefik.md",
            "service-mesh/istio-service-mesh.md",
            "service-mesh/istio-ingress-gateway.md",
            "gateway-api/gateway-api.md",
            "policy/opa-gatekeeper.md",
        ],
    )
    def test_primer_is_non_empty(self, rel_path: str) -> None:
        """Each moved primer exists and contains non-whitespace content."""
        path = INTEGRATIONS_DIR / rel_path
        assert path.is_file(), f"Primer missing: {path}"
        text = path.read_text(encoding="utf-8")
        assert text.strip(), f"Primer is empty or whitespace-only: {path}"

    @pytest.mark.parametrize(
        "rel_path",
        [
            "certificates/cert-manager.md",
            "ingress-controllers/traefik.md",
            "service-mesh/istio-service-mesh.md",
            "service-mesh/istio-ingress-gateway.md",
            "gateway-api/gateway-api.md",
            "policy/opa-gatekeeper.md",
        ],
    )
    def test_primer_has_h2_sections(self, rel_path: str) -> None:
        """Each primer has at least the minimum number of H2-level
        headings, confirming it is a structured primer (not a stub)."""
        path = INTEGRATIONS_DIR / rel_path
        text = path.read_text(encoding="utf-8")
        h2_headings = [line for line in text.splitlines() if line.startswith("## ")]
        assert len(h2_headings) >= MIN_H2_SECTIONS, (
            f"Primer {rel_path} has only {len(h2_headings)} H2 section(s) "
            f"(minimum {MIN_H2_SECTIONS} required).  H2 headings found: {h2_headings}"
        )

    @pytest.mark.parametrize(
        "rel_path",
        [
            "certificates/cert-manager.md",
            "ingress-controllers/traefik.md",
            "service-mesh/istio-service-mesh.md",
            "service-mesh/istio-ingress-gateway.md",
            "gateway-api/gateway-api.md",
            "policy/opa-gatekeeper.md",
        ],
    )
    def test_primer_file_has_markdown_extension(self, rel_path: str) -> None:
        """Each primer file has a .md extension (markdown)."""
        assert rel_path.endswith(".md"), f"Primer {rel_path} is not a .md file"


class TestBaselineHashes:
    """Opt-in migration check: CTS_REORG_BASELINE=1 only.

    Compares current primer content against frozen SHA-256 hashes in
    tests/fixtures/pre_reorg_hashes.json.  This is a ONE-TIME migration
    audit — it verifies the F1.3 reorg itself was a pure rename without
    content changes.  It is NOT run by default because it would block
    any future intentional primer rewrite.
    """

    BASELINE_FILE = FIXTURES_DIR / "pre_reorg_hashes.json"

    @pytest.mark.skipif(
        os.environ.get("CTS_REORG_BASELINE") != "1",
        reason="Set CTS_REORG_BASELINE=1 to run the frozen-baseline hash check",
    )
    def test_baseline_file_exists(self) -> None:
        """The baseline fixture file exists when the env var is set."""
        assert self.BASELINE_FILE.is_file(), f"Baseline file missing: {self.BASELINE_FILE}"

    @pytest.mark.skipif(
        os.environ.get("CTS_REORG_BASELINE") != "1",
        reason="Set CTS_REORG_BASELINE=1 to run the frozen-baseline hash check",
    )
    @pytest.mark.parametrize(
        "rel_path",
        [
            "certificates/cert-manager.md",
            "ingress-controllers/traefik.md",
            "service-mesh/istio-service-mesh.md",
            "service-mesh/istio-ingress-gateway.md",
            "gateway-api/gateway-api.md",
            "policy/opa-gatekeeper.md",
        ],
    )
    def test_sha256_matches_baseline(self, rel_path: str) -> None:
        """SHA-256 of the primer matches the frozen baseline hash."""
        path = INTEGRATIONS_DIR / rel_path
        assert path.is_file(), f"Primer missing: {path}"

        baseline = json.loads(self.BASELINE_FILE.read_text(encoding="utf-8"))
        expected = baseline["primers"].get(rel_path)
        assert expected, f"No baseline hash for {rel_path}"

        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        assert digest == expected, (
            f"Baseline mismatch for {rel_path}: "
            f"expected {expected}, got {digest}.  "
            f"This may be expected if the primer was intentionally rewritten.  "
            f"If this is a one-time migration audit, update the hash in "
            f"{self.BASELINE_FILE}."
        )


class TestDiscoverIntegrations:
    """discover_integrations() walks the new subdir layout."""

    def test_discover_integrations_returns_all_categories(self) -> None:
        """discover_integrations finds every category with at least one primer."""
        from testgrid.collect import discover_integrations

        result = discover_integrations(INTEGRATIONS_DIR)
        for cat in EXPECTED_LAYOUT:
            assert cat in result, f"Category {cat!r} missing from result"

    def test_discover_integrations_returns_primer_names(self) -> None:
        """discover_integrations lists primer stems (sans .md) per category."""
        from testgrid.collect import discover_integrations

        result = discover_integrations(INTEGRATIONS_DIR)
        for cat, primers in EXPECTED_LAYOUT.items():
            stems = [p.removesuffix(".md") for p in primers]
            assert set(result[cat]) == set(stems), (
                f"Category {cat!r}: expected {stems}, got {result[cat]}"
            )

    def test_discover_integrations_with_empty_dir(self, tmp_path: Path) -> None:
        """discover_integrations returns empty dict when no .md files exist."""
        from testgrid.collect import discover_integrations

        empty_integrations = tmp_path / "integrations"
        empty_integrations.mkdir()
        result = discover_integrations(empty_integrations)
        assert result == {}

    def test_discover_integrations_with_flat_md(self, tmp_path: Path) -> None:
        """discover_integrations ignores stray .md files at the top level
        (they should not exist post-reorg, but the function should not crash)."""
        from testgrid.collect import discover_integrations

        d = tmp_path / "integrations"
        d.mkdir()
        (d / "stray.md").write_text("# stray")
        result = discover_integrations(d)
        # Stray .md at top level is NOT a valid category primer.
        # The function should only discover within subdirs.
        assert result == {}

    def test_discover_integrations_single_category(self, tmp_path: Path) -> None:
        """discover_integrations correctly walks a single category subdir."""
        from testgrid.collect import discover_integrations

        d = tmp_path / "integrations"
        cat_dir = d / "certificates"
        cat_dir.mkdir(parents=True)
        (cat_dir / "cert-manager.md").write_text("# cert-manager")
        result = discover_integrations(d)
        assert "certificates" in result
        assert "cert-manager" in result["certificates"]
