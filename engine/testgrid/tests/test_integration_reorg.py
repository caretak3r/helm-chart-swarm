"""Tests for F1.3 — integration category reorg.

Validates:
  - VAL-ENGINE-011: No primer remains at top level; each lives under its
    correct category subdir.
  - VAL-ENGINE-012: Primer content is byte-identical after the move.
  - discover_integrations() walks the category subdirs correctly.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import pytest

# The integrations directory inside the repo.
# test file: engine/testgrid/tests/test_integration_reorg.py
# repo root: chart-test-swarm/  (parents[3])
REPO_ROOT = Path(__file__).resolve().parents[3]
INTEGRATIONS_DIR = (
    REPO_ROOT / "engine" / "skills" / "chart-test-swarm" / "references" / "integrations"
)

# Expected mapping: category subdir → list of primer basenames.
EXPECTED_LAYOUT: dict[str, list[str]] = {
    "certificates": ["cert-manager.md"],
    "ingress-controllers": ["traefik.md"],
    "service-mesh": ["istio-service-mesh.md", "istio-ingress-gateway.md"],
    "gateway-api": ["gateway-api.md"],
    "policy": ["opa-gatekeeper.md"],
}


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


class TestByteIdenticalContent:
    """VAL-ENGINE-012: primer content is byte-identical post-reorg.

    We verify by checking that each file under the new layout has a stable
    SHA-256 that was recorded before the move.  The expected hashes were
    captured from the pre-reorg top-level files.
    """

    # SHA-256 hashes of the six primers BEFORE the reorg (captured 2026-05-27).
    EXPECTED_HASHES: dict[str, str] = {
        "certificates/cert-manager.md": (
            "3daa1307d34be3a2b448b2a0c01f4661730448dbddd0b3b32c06e3afcce9e1be"
        ),
        "ingress-controllers/traefik.md": (
            "563b514d8b3b66469bc6c0dc77a99b275d25d7842c231c92abed86166d92bc65"
        ),
        "service-mesh/istio-service-mesh.md": (
            "25ecc56431ddea504d3def3effb662d14a143ac6ac42aa7f0527472c20faff88"
        ),
        "service-mesh/istio-ingress-gateway.md": (
            "74c7797eb4d27462b58b24f8a87552cd53eb3ccefe8a7d3e0701147e1e7fabb5"
        ),
        "gateway-api/gateway-api.md": (
            "e1355184da721d0fb4c636818a71ded379924c63cb6a89f219e948fd7df6dcb2"
        ),
        "policy/opa-gatekeeper.md": (
            "04a123be0158e0d71b75634cc9d3750ef45b9ec0cc0744ddb799f952a88c0615"
        ),
    }

    @pytest.mark.parametrize(
        "rel_path",
        list(EXPECTED_HASHES.keys()),
    )
    def test_sha256_matches_pre_reorg(self, rel_path: str) -> None:
        """SHA-256 of the moved file matches the pre-reorg blob."""
        path = INTEGRATIONS_DIR / rel_path
        assert path.is_file(), f"File missing: {path}"
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        assert digest == self.EXPECTED_HASHES[rel_path], (
            f"Content mismatch for {rel_path}: got {digest}"
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
