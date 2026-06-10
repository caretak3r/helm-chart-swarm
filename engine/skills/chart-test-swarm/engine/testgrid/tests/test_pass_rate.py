"""Tests for the home-page scenario pass-rate metric (_compute_pass_rate_pct).

The headline metric is the scenario pass rate:

    PASS scenarios / ALL catalog scenarios

where the denominator includes authored-only (cloud) scenarios.  Authored-only
scenarios are never run and never PASS, so they only ever sit in the
denominator.
"""

from __future__ import annotations

from pathlib import Path

import testgrid.cli as cli
from testgrid.render import SupportMatrixEntry


def _entry(scenario_id: str, status: str, *, authored: bool) -> SupportMatrixEntry:
    return SupportMatrixEntry(
        scenario_id=scenario_id,
        name=scenario_id,
        category="cat",
        integration_key="int",
        tier="authored-only" if authored else None,
        status=status,
        scenario_href=None,
        overrides_href=None,
        is_authored_only=authored,
    )


def _patch_matrix(monkeypatch, entries: list[SupportMatrixEntry]) -> None:
    monkeypatch.setattr(cli, "build_support_matrix", lambda *a, **k: {"cat": list(entries)})


class TestComputePassRatePct:
    def test_pass_rate_69_pass_30_fail_30_authored(self, monkeypatch, tmp_path: Path) -> None:
        """69 PASS, 30 FAIL, 30 authored-only (129 total) → 53.5%."""
        entries = (
            [_entry(f"p{i}", "PASS", authored=False) for i in range(69)]
            + [_entry(f"f{i}", "FAIL", authored=False) for i in range(30)]
            + [_entry(f"a{i}", "AUTHORED", authored=True) for i in range(30)]
        )
        _patch_matrix(monkeypatch, entries)
        result = cli._compute_pass_rate_pct(tmp_path, None, [])
        assert result == 53.5

    def test_authored_only_count_in_denominator_not_numerator(
        self, monkeypatch, tmp_path: Path
    ) -> None:
        """Authored-only scenarios swell the denominator but never the numerator."""
        # 1 PASS + 1 authored-only → 1/2 = 50.0 (authored excluded from numerator).
        entries = [
            _entry("p0", "PASS", authored=False),
            _entry("a0", "AUTHORED", authored=True),
        ]
        _patch_matrix(monkeypatch, entries)
        assert cli._compute_pass_rate_pct(tmp_path, None, []) == 50.0

        # Adding more authored-only entries only lowers the rate.
        entries.append(_entry("a1", "AUTHORED", authored=True))
        _patch_matrix(monkeypatch, entries)
        assert cli._compute_pass_rate_pct(tmp_path, None, []) == round(1 / 3 * 100, 1)

    def test_zero_catalog_returns_zero(self, monkeypatch, tmp_path: Path) -> None:
        """An empty catalog yields 0.0 rather than a division error."""
        _patch_matrix(monkeypatch, [])
        assert cli._compute_pass_rate_pct(tmp_path, None, []) == 0.0
