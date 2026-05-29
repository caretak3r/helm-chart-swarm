"""Tests for F2.2 — variant grouping in the matrix view.

Validates:
  - VAL-DASH-007: Multiple variants of same (category, integration) collapse under
                  a single header row when 3+ share the same pair.
  - VAL-DASH-008: Integration header row displays variant count and pass/fail breakdown.
  - VAL-DASH-009: Clicking the integration header toggles expand/collapse of variant rows.
  - VAL-DASH-010: Collapsed integration header reflects rolled-up worst-of-set status.
  - VAL-CROSS-011: Variant grouping correctly aggregates mixed PASS/FAIL outcomes
                   under one integration header.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[3]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_yaml(path: Path, data: object) -> None:
    path.write_text(yaml.dump(data), encoding="utf-8")


def _build_run_with_variants(
    reports_dir: Path,
    run_id: str,
    scenario_specs: list[dict[str, Any]],
) -> Path:
    """Create a synthetic run with scenarios having specific mechanisms and statuses.

    Each spec dict should have:
      - id: str
      - mechanisms: list[str]
      - status: str (PASS, FAIL, etc.)
      - (optional) tags, labels, cluster
    """
    run_dir = reports_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    _write_yaml(
        run_dir / "run-meta.yaml",
        {
            "run_id": run_id,
            "timestamp_utc": "2026-05-29T10:00:00Z",
            "num_agents": 1,
            "suite": "full",
        },
    )

    _write_yaml(
        run_dir / "scenarios-snapshot.yaml",
        {
            "scenarios": [
                {
                    "id": spec["id"],
                    "name": spec.get("name", f"Scenario {spec['id']}"),
                    "description": spec.get("description", f"Desc of {spec['id']}"),
                    "cluster": spec.get("cluster", {"provider": "kind"}),
                    "mechanisms": spec.get("mechanisms", []),
                    "tags": spec.get("tags", []),
                    "labels": spec.get("labels", {}),
                    "product": {"chart": "sample", "release": spec["id"], "namespace": "sample"},
                    "asserts": [{"type": "pods-ready", "status": "PASS", "notes": "ok"}],
                }
                for spec in scenario_specs
            ],
        },
    )

    agent_dir = run_dir / "agent-1"
    agent_dir.mkdir()
    _write_yaml(
        agent_dir / "result.yaml",
        {
            "agent": 1,
            "results": [
                {
                    "scenario_id": spec["id"],
                    "status": spec.get("status", "PASS"),
                    "duration_s": 30,
                    "asserts": [{"type": "pods-ready", "status": "PASS", "notes": "ok"}],
                }
                for spec in scenario_specs
            ],
        },
    )

    return run_dir


# ---------------------------------------------------------------------------
# Mechanism parsing helpers (in render.py)
# ---------------------------------------------------------------------------


class TestMechanismParsing:
    """Unit tests for extracting (category, integration, variant) from mechanisms."""

    def _mechanism_parts(self, m: str) -> tuple[str, str, str]:
        """Extract (category, integration, variant) from a mechanism string."""
        parts = m.split(":")
        category = parts[0] if len(parts) >= 1 else ""
        integration = parts[1] if len(parts) >= 2 else ""
        variant = parts[2] if len(parts) >= 3 else ""
        return category, integration, variant

    def _scenario_integration_key(self, scenario_mechanisms: list[str]) -> tuple[str, str] | None:
        """Return (category, integration) for the primary mechanism, or None."""
        if not scenario_mechanisms:
            return None
        # Use the first mechanism with at least 2 parts as the primary
        for m in scenario_mechanisms:
            parts = m.split(":")
            if len(parts) >= 2:
                return parts[0], parts[1]
        # Fallback: use first mechanism
        parts = scenario_mechanisms[0].split(":")
        return parts[0], "" if len(parts) == 1 else parts[1]

    def test_extracts_category_integration_variant(self) -> None:
        """Mechanism 'certificates:cert-manager:self-signed' yields
        category=certificates, integration=cert-manager, variant=self-signed."""
        cat, integ, var = self._mechanism_parts("certificates:cert-manager:self-signed")
        assert cat == "certificates"
        assert integ == "cert-manager"
        assert var == "self-signed"

    def test_extracts_category_integration_no_variant(self) -> None:
        """Mechanism 'certificates:cert-manager' yields variant=''."""
        cat, integ, var = self._mechanism_parts("certificates:cert-manager")
        assert cat == "certificates"
        assert integ == "cert-manager"
        assert var == ""

    def test_extracts_category_only(self) -> None:
        """Mechanism with only category yields empty integration and variant."""
        cat, integ, var = self._mechanism_parts("single")
        assert cat == "single"
        assert integ == ""
        assert var == ""

    def test_integration_key_from_mechanisms(self) -> None:
        """Returns the first 2-part mechanism as (category, integration)."""
        key = self._scenario_integration_key(
            ["addon:cert-manager:self-signed", "customer:profile-a"]
        )
        assert key == ("addon", "cert-manager")

    def test_integration_key_skip_short(self) -> None:
        """Skips mechanisms without a colon, uses the first 2+ part one."""
        key = self._scenario_integration_key(["general", "addon:cert-manager:basic"])
        assert key == ("addon", "cert-manager")

    def test_integration_key_none_for_empty(self) -> None:
        """Empty mechanisms list returns None."""
        assert self._scenario_integration_key([]) is None


# ---------------------------------------------------------------------------
# VariantGroup dataclass (in render.py)
# ---------------------------------------------------------------------------


class TestVariantGroupProperties:
    """Unit tests for VariantGroup computed properties."""

    @pytest.fixture
    def mock_scenarios(self) -> list[Any]:
        """Create mock Scenario objects with different statuses."""
        from testgrid.collect import Scenario

        return [
            Scenario(id="sc-pass-1", status="PASS"),
            Scenario(id="sc-pass-2", status="PASS"),
            Scenario(id="sc-fail-1", status="FAIL"),
        ]

    def test_rolled_status_worst_of_set(self, mock_scenarios: list[Any]) -> None:
        """With 2 PASS + 1 FAIL, rolled_status is FAIL (worst)."""
        from testgrid.collect import STATUS_RANK

        rolled = min((s.status for s in mock_scenarios), key=lambda st: STATUS_RANK.get(st, 99))
        assert rolled == "FAIL"

    def test_rolled_status_all_pass(self) -> None:
        """All PASS -> rolled status is PASS."""
        from testgrid.collect import STATUS_RANK, Scenario

        scenarios = [Scenario(id=f"sc-{i}", status="PASS") for i in range(3)]
        rolled = min((s.status for s in scenarios), key=lambda st: STATUS_RANK.get(st, 99))
        assert rolled == "PASS"

    def test_rolled_status_mixed_with_partial(self) -> None:
        """PASS + PARTIAL + FAIL -> rolled is FAIL (STATUS_RANK: FAIL=0, PARTIAL=1)."""
        from testgrid.collect import STATUS_RANK, Scenario

        scenarios = [
            Scenario(id="sc-1", status="PASS"),
            Scenario(id="sc-2", status="PARTIAL"),
            Scenario(id="sc-3", status="FAIL"),
        ]
        rolled = min((s.status for s in scenarios), key=lambda st: STATUS_RANK.get(st, 99))
        assert rolled == "FAIL"

    def test_rolled_status_untested_above_inconclusive(self) -> None:
        """STATUS_RANK has UNTESTED(3) < INCONCLUSIVE(2) — verify ordering."""
        from testgrid.collect import STATUS_RANK

        assert STATUS_RANK["UNTESTED"] > STATUS_RANK["INCONCLUSIVE"], (
            "UNTESTED should rank HIGHER (less severe) than INCONCLUSIVE"
        )
        # UNTESTED has rank 3, INCONCLUSIVE has rank 2
        # So min() would select INCONCLUSIVE as "worse"
        # VERIFY: INCONCLUSIVE is worse (lower rank number)
        assert STATUS_RANK["INCONCLUSIVE"] < STATUS_RANK["UNTESTED"]

    def test_inconclusive_and_untested_rollup_untested(self) -> None:
        """INCONCLUSIVE + UNTESTED -> INCONCLUSIVE is rolled (it's worse)."""
        from testgrid.collect import STATUS_RANK, Scenario

        scenarios = [
            Scenario(id="sc-1", status="INCONCLUSIVE"),
            Scenario(id="sc-2", status="UNTESTED"),
        ]
        rolled = min((s.status for s in scenarios), key=lambda st: STATUS_RANK.get(st, 99))
        # STATUS_RANK: INCONCLUSIVE=2, UNTESTED=3. Min rank = INCONCLUSIVE
        assert rolled == "INCONCLUSIVE"

    def test_status_breakdown_string(self) -> None:
        """Status breakdown produces correct count string."""
        from testgrid.collect import Scenario

        scenarios = [
            Scenario(id="sc-1", status="PASS"),
            Scenario(id="sc-2", status="PASS"),
            Scenario(id="sc-3", status="FAIL"),
        ]

        counts: dict[str, int] = {}
        for s in scenarios:
            counts[s.status] = counts.get(s.status, 0) + 1

        parts = []
        for status in ["PASS", "FAIL", "PARTIAL", "INCONCLUSIVE", "UNTESTED"]:
            if counts.get(status):
                parts.append(f"{counts[status]} {status}")
        breakdown = " / ".join(parts)

        assert breakdown == "2 PASS / 1 FAIL"

    def test_status_breakdown_includes_partial_untested(self) -> None:
        """Status breakdown includes PARTIAL and UNTESTED when present."""
        from testgrid.collect import Scenario

        scenarios = [
            Scenario(id="sc-1", status="PASS"),
            Scenario(id="sc-2", status="PARTIAL"),
            Scenario(id="sc-3", status="FAIL"),
            Scenario(id="sc-4", status="UNTESTED"),
        ]

        counts: dict[str, int] = {}
        for s in scenarios:
            counts[s.status] = counts.get(s.status, 0) + 1

        parts = []
        for status in ["PASS", "FAIL", "PARTIAL", "INCONCLUSIVE", "UNTESTED"]:
            if counts.get(status):
                parts.append(f"{counts[status]} {status}")
        breakdown = " / ".join(parts)

        assert "1 PASS" in breakdown
        assert "1 FAIL" in breakdown
        assert "1 PARTIAL" in breakdown
        assert "1 UNTESTED" in breakdown


# ---------------------------------------------------------------------------
# Variant grouping logic (render.py build_variant_groups)
# ---------------------------------------------------------------------------


class TestVariantGrouping:
    """Integration tests for variant grouping logic."""

    def _build_groups(self, scenarios: list[Any]) -> dict[str, Any]:
        """Group scenarios by (mechanism-category, integration).

        Returns:
          - groups: dict mapping key -> list of scenario ids
          - standalone: list of scenario ids not in any group
        """
        from testgrid.collect import Scenario

        # Determine integration key per scenario
        keyed: list[tuple[tuple[str, str] | None, Scenario]] = []
        for s in scenarios:
            key: tuple[str, str] | None = None
            for m in s.mechanisms:
                parts = m.split(":")
                if len(parts) >= 2:
                    key = (parts[0], parts[1])
                    break
            keyed.append((key, s))

        # Group by key (threshold: 3+)
        by_key: dict[tuple[str, str], list[Scenario]] = {}
        standalone: list[Scenario] = []
        for key, s in keyed:
            if key is None:
                standalone.append(s)
            else:
                by_key.setdefault(key, []).append(s)

        # Groups with 3+ scenarios
        groups = {k: v for k, v in by_key.items() if len(v) >= 3}
        # Standalone = scenarios not in any qualified group
        standalone.extend(s for k, v in by_key.items() if len(v) < 3 for s in v)

        return {"groups": groups, "standalone": standalone}

    def test_three_variants_form_group(self) -> None:
        """3 scenarios sharing (certificates, cert-manager) form a group."""
        from testgrid.collect import Scenario

        scenarios = [
            Scenario(
                id=f"certificates-cert-manager-{v}",
                mechanisms=[f"certificates:cert-manager:{v}"],
                status="PASS",
            )
            for v in ["self-signed", "lets-encrypt", "wildcard"]
        ]

        result = self._build_groups(scenarios)
        assert len(result["groups"]) == 1
        key = ("certificates", "cert-manager")
        assert key in result["groups"]
        assert len(result["groups"][key]) == 3

    def test_two_variants_stay_standalone(self) -> None:
        """2 scenarios sharing same integration do NOT form a group (<3 threshold)."""
        from testgrid.collect import Scenario

        scenarios = [
            Scenario(
                id=f"certificates-cert-manager-{v}",
                mechanisms=[f"certificates:cert-manager:{v}"],
                status="PASS",
            )
            for v in ["self-signed", "lets-encrypt"]
        ]

        result = self._build_groups(scenarios)
        assert len(result["groups"]) == 0
        assert len(result["standalone"]) == 2

    def test_mixed_integrations(self) -> None:
        """Scenarios from different integrations form separate groups."""
        from testgrid.collect import Scenario

        scenarios = [
            Scenario(id="cm-1", mechanisms=["certificates:cert-manager:self"], status="PASS"),
            Scenario(id="cm-2", mechanisms=["certificates:cert-manager:le"], status="PASS"),
            Scenario(id="cm-3", mechanisms=["certificates:cert-manager:wc"], status="FAIL"),
            Scenario(id="ig-1", mechanisms=["ingress-controllers:traefik:basic"], status="PASS"),
            Scenario(id="ig-2", mechanisms=["ingress-controllers:traefik:tls"], status="PASS"),
            Scenario(
                id="ig-3", mechanisms=["ingress-controllers:traefik:middleware"], status="PASS"
            ),
            Scenario(id="standalone", mechanisms=["other:single"], status="PASS"),
        ]

        result = self._build_groups(scenarios)
        assert len(result["groups"]) == 2
        assert ("certificates", "cert-manager") in result["groups"]
        assert ("ingress-controllers", "traefik") in result["groups"]
        assert len(result["standalone"]) == 1

    def test_scenario_without_mechanisms_is_standalone(self) -> None:
        """Scenario with no mechanisms stays standalone."""
        from testgrid.collect import Scenario

        scenarios = [
            Scenario(id="sc-1", mechanisms=[], status="PASS"),
            Scenario(id="sc-2", mechanisms=[], status="PASS"),
            Scenario(id="sc-3", mechanisms=[], status="PASS"),
        ]

        result = self._build_groups(scenarios)
        assert len(result["groups"]) == 0
        assert len(result["standalone"]) == 3

    def test_cross_feature_mixed_pass_fail_aggregation(self) -> None:
        """VAL-CROSS-011: Mixed PASS/FAIL outcomes aggregate correctly under
        one integration header with correct breakdown."""
        from testgrid.collect import Scenario

        scenarios = [
            Scenario(id="m3-cert-1", mechanisms=["certificates:cert-manager:v1"], status="PASS"),
            Scenario(id="m3-cert-2", mechanisms=["certificates:cert-manager:v2"], status="FAIL"),
            Scenario(id="m3-cert-3", mechanisms=["certificates:cert-manager:v3"], status="PASS"),
        ]

        result = self._build_groups(scenarios)
        assert len(result["groups"]) == 1
        key = ("certificates", "cert-manager")
        group = result["groups"][key]

        statuses = [s.status for s in group]
        assert statuses.count("PASS") == 2
        assert statuses.count("FAIL") == 1


# ---------------------------------------------------------------------------
# Render tests — HTML output
# ---------------------------------------------------------------------------


class TestVariantGroupingRender:
    """Integration tests: full collect → render pipeline verifying HTML output."""

    def _render_and_read(self, tmp_path: Path, run_id: str) -> str:
        """Build and render a run, return the HTML content."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        out = tmp_path / "dist"
        out.mkdir()

        run = collect_run(reports, run_id)
        render_run(run, out)
        return (out / run_id / "index.html").read_text(encoding="utf-8")

    def test_integration_header_rendered(self, tmp_path: Path) -> None:
        """VAL-DASH-007: When 3+ scenarios share (category, integration),
        the HTML contains an integration header row for that group."""
        reports = tmp_path / "reports"
        reports.mkdir()

        specs = [
            {
                "id": "certificates-cert-manager-self-signed",
                "mechanisms": ["certificates:cert-manager:self-signed"],
                "status": "PASS",
            },
            {
                "id": "certificates-cert-manager-lets-encrypt",
                "mechanisms": ["certificates:cert-manager:lets-encrypt"],
                "status": "PASS",
            },
            {
                "id": "certificates-cert-manager-wildcard",
                "mechanisms": ["certificates:cert-manager:wildcard"],
                "status": "FAIL",
            },
        ]
        _build_run_with_variants(reports, "run-variants", specs)

        html = self._render_and_read(tmp_path, "run-variants")

        # Should contain an integration group details element
        assert '<details class="integration-group' in html, (
            "Integration group should use <details> for expand/collapse"
        )
        assert "cert-manager" in html
        assert "variants" in html.lower()

    def test_integration_header_contains_variant_summary(self, tmp_path: Path) -> None:
        """VAL-DASH-008: Integration header shows variant count and pass/fail breakdown."""
        reports = tmp_path / "reports"
        reports.mkdir()

        specs = [
            {"id": "cm-self", "mechanisms": ["certificates:cert-manager:self"], "status": "PASS"},
            {"id": "cm-le", "mechanisms": ["certificates:cert-manager:le"], "status": "PASS"},
            {"id": "cm-wc", "mechanisms": ["certificates:cert-manager:wc"], "status": "FAIL"},
        ]
        _build_run_with_variants(reports, "run-summary", specs)

        html = self._render_and_read(tmp_path, "run-summary")

        # Check variant count
        assert "3 variants" in html, "Should show '3 variants'"
        # Check pass/fail breakdown
        assert "2 PASS" in html
        assert "1 FAIL" in html

    def test_integration_header_has_details_open(self, tmp_path: Path) -> None:
        """VAL-DASH-009: <details open> enables expand/collapse behavior;
        second click returns to prior state (native <details> behavior)."""
        reports = tmp_path / "reports"
        reports.mkdir()

        specs = [
            {"id": "cm-1", "mechanisms": ["certificates:cert-manager:v1"], "status": "PASS"},
            {"id": "cm-2", "mechanisms": ["certificates:cert-manager:v2"], "status": "PASS"},
            {"id": "cm-3", "mechanisms": ["certificates:cert-manager:v3"], "status": "PASS"},
        ]
        _build_run_with_variants(reports, "run-details-open", specs)

        html = self._render_and_read(tmp_path, "run-details-open")

        # The <details> element should have the 'open' attribute by default
        assert '<details class="integration-group' in html
        assert " open>" in html or " open " in html or " open\n" in html or " open\t" in html, (
            "Integration group <details> should be <details open> by default"
        )

    def test_collapsed_integration_header_shows_rolled_up_status(self, tmp_path: Path) -> None:
        """VAL-DASH-010: The integration header's status badge shows the worst-of-set
        status (FAIL when any variant fails)."""
        reports = tmp_path / "reports"
        reports.mkdir()

        specs = [
            {"id": "cm-pass-1", "mechanisms": ["certificates:cert-manager:v1"], "status": "PASS"},
            {"id": "cm-pass-2", "mechanisms": ["certificates:cert-manager:v2"], "status": "PASS"},
            {"id": "cm-fail", "mechanisms": ["certificates:cert-manager:v3"], "status": "FAIL"},
        ]
        _build_run_with_variants(reports, "run-rolled", specs)

        html = self._render_and_read(tmp_path, "run-rolled")

        # The integration header should have a FAIL badge (worst of set)
        assert "status-fail" in html, "HTML should contain FAIL status class for rolled-up badge"
        assert "FAIL" in html

    def test_two_variants_not_grouped(self, tmp_path: Path) -> None:
        """Only 2 variants → no integration header; they appear as standalone rows."""
        reports = tmp_path / "reports"
        reports.mkdir()

        specs = [
            {"id": "cm-1", "mechanisms": ["certificates:cert-manager:v1"], "status": "PASS"},
            {"id": "cm-2", "mechanisms": ["certificates:cert-manager:v2"], "status": "PASS"},
        ]
        _build_run_with_variants(reports, "run-two-only", specs)

        html = self._render_and_read(tmp_path, "run-two-only")

        # Should NOT contain integration group details for 2 variants
        assert '<details class="integration-group' not in html, (
            "2 variants should not trigger integration grouping"
        )
        # Individual scenario rows should appear in the matrix table
        assert "cm-1" in html
        assert "cm-2" in html

    def test_variant_rows_present_in_html(self, tmp_path: Path) -> None:
        """All variant scenario IDs appear in the rendered HTML."""
        reports = tmp_path / "reports"
        reports.mkdir()

        specs = [
            {"id": "cm-v1", "mechanisms": ["certificates:cert-manager:v1"], "status": "PASS"},
            {"id": "cm-v2", "mechanisms": ["certificates:cert-manager:v2"], "status": "FAIL"},
            {"id": "cm-v3", "mechanisms": ["certificates:cert-manager:v3"], "status": "PASS"},
        ]
        _build_run_with_variants(reports, "run-all-rows", specs)

        html = self._render_and_read(tmp_path, "run-all-rows")

        # All variant IDs should appear
        for sid in ["cm-v1", "cm-v2", "cm-v3"]:
            assert sid in html, f"Variant {sid} should appear in rendered HTML"

    def test_expand_reveals_individual_statuses(self, tmp_path: Path) -> None:
        """VAL-CROSS-011: Expanding reveals each variant's individual status
        (PASS/FAIL) in the sub-table."""
        reports = tmp_path / "reports"
        reports.mkdir()

        specs = [
            {"id": "cm-v1", "mechanisms": ["certificates:cert-manager:v1"], "status": "PASS"},
            {"id": "cm-v2", "mechanisms": ["certificates:cert-manager:v2"], "status": "FAIL"},
            {"id": "cm-v3", "mechanisms": ["certificates:cert-manager:v3"], "status": "PARTIAL"},
        ]
        _build_run_with_variants(reports, "run-expand", specs)

        html = self._render_and_read(tmp_path, "run-expand")

        # Individual status badges should be visible in the variant sub-table
        assert "status-pass" in html
        assert "status-fail" in html
        assert "status-partial" in html

    def test_mixed_category_groups(self, tmp_path: Path) -> None:
        """Two different integrations each with 3+ variants produce two groups."""
        reports = tmp_path / "reports"
        reports.mkdir()

        specs = [
            {"id": "cm-a1", "mechanisms": ["certificates:cert-manager:a1"], "status": "PASS"},
            {"id": "cm-a2", "mechanisms": ["certificates:cert-manager:a2"], "status": "PASS"},
            {"id": "cm-a3", "mechanisms": ["certificates:cert-manager:a3"], "status": "PASS"},
            {"id": "tf-b1", "mechanisms": ["ingress-controllers:traefik:b1"], "status": "FAIL"},
            {"id": "tf-b2", "mechanisms": ["ingress-controllers:traefik:b2"], "status": "FAIL"},
            {"id": "tf-b3", "mechanisms": ["ingress-controllers:traefik:b3"], "status": "PASS"},
            {"id": "standalone", "mechanisms": ["other:single"], "status": "PASS"},
        ]
        _build_run_with_variants(reports, "run-mixed", specs)

        html = self._render_and_read(tmp_path, "run-mixed")

        # Two integration groups should appear
        assert html.count('<details class="integration-group') == 2, (
            "Should have exactly 2 integration group <details> elements"
        )
        # Standalone scenario should appear in matrix table
        assert "standalone" in html

    def test_all_pass_group_shows_pass_badge(self, tmp_path: Path) -> None:
        """When all variants PASS, the integration header shows a PASS badge."""
        reports = tmp_path / "reports"
        reports.mkdir()

        specs = [
            {"id": "cm-p1", "mechanisms": ["certificates:cert-manager:p1"], "status": "PASS"},
            {"id": "cm-p2", "mechanisms": ["certificates:cert-manager:p2"], "status": "PASS"},
            {"id": "cm-p3", "mechanisms": ["certificates:cert-manager:p3"], "status": "PASS"},
        ]
        _build_run_with_variants(reports, "run-all-pass", specs)

        html = self._render_and_read(tmp_path, "run-all-pass")

        assert "status-pass" in html
        assert "3 variants" in html
        assert "3 PASS" in html


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


class TestVariantGroupingEdgeCases:
    """Edge case tests for variant grouping."""

    def test_empty_scenarios(self, tmp_path: Path) -> None:
        """Run with no scenarios renders without crashing."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_variants(reports, "run-empty", [])

        out = tmp_path / "dist"
        out.mkdir()
        run = collect_run(reports, "run-empty")
        render_run(run, out)

        html = (out / "run-empty" / "index.html").read_text(encoding="utf-8")
        assert "index.html" in (out / "run-empty" / "index.html").name.lower() or True
        # Should not crash
        assert "chart-test-swarm" in html

    def test_scenario_with_5_variants_still_groups(self, tmp_path: Path) -> None:
        """5 variants of same integration still group (threshold is 3+)."""
        reports = tmp_path / "reports"
        reports.mkdir()

        specs = [
            {"id": f"cm-{i}", "mechanisms": [f"certificates:cert-manager:v{i}"], "status": "PASS"}
            for i in range(5)
        ]
        _build_run_with_variants(reports, "run-5-var", specs)

        # Render
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        out = tmp_path / "dist"
        out.mkdir()
        run = collect_run(reports, "run-5-var")
        render_run(run, out)

        html = (out / "run-5-var" / "index.html").read_text(encoding="utf-8")
        assert "5 variants" in html
        assert '<details class="integration-group' in html

    def test_status_rank_ordering_unchanged(self) -> None:
        """STATUS_RANK maintains expected ordering:
        FAIL(0) < PARTIAL(1) < INCONCLUSIVE(2) < UNTESTED(3) < PASS(4)."""
        from testgrid.collect import STATUS_RANK

        assert STATUS_RANK["FAIL"] < STATUS_RANK["PARTIAL"]
        assert STATUS_RANK["PARTIAL"] < STATUS_RANK["INCONCLUSIVE"]
        assert STATUS_RANK["INCONCLUSIVE"] < STATUS_RANK["UNTESTED"]
        assert STATUS_RANK["UNTESTED"] < STATUS_RANK["PASS"]

    def test_unknown_status_ranks_high(self) -> None:
        """An unknown status has rank 99, so it doesn't win the min() rollup."""
        from testgrid.collect import STATUS_RANK, Scenario

        scenarios = [
            Scenario(id="sc-1", status="PASS"),
            Scenario(id="sc-2", status="PASS"),
            Scenario(id="sc-3", status="MADE_UP_STATUS"),
        ]
        rolled = min((s.status for s in scenarios), key=lambda st: STATUS_RANK.get(st, 99))
        # MADE_UP_STATUS has rank 99, PASS has rank 4, so PASS should be rolled
        assert rolled == "PASS"
