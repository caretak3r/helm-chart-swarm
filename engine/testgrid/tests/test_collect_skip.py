"""Tests for SKIP as first-class status and depth_level ingestion in collect.py.

Validates:
  - VAL-CONTRACT-020: SKIP present in STATUS_RANK with a non-failing rank
  - VAL-CONTRACT-021: SKIP rank ordering is non-failing relative to FAIL
  - VAL-CONTRACT-022: SKIP in KNOWN_STATUSES — never normalized to UNKNOWN
  - VAL-CONTRACT-023: Per-assert SKIP status preserved by collector
  - VAL-CONTRACT-042: pytest collect roundtrip preserves SKIP in status_counts
  - VAL-CONTRACT-043: unknown/out-of-vocabulary scenario status still normalizes to UNKNOWN
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parents[3]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_yaml(path: Path, data: object) -> None:
    path.write_text(yaml.dump(data), encoding="utf-8")


def _build_run_with_skip(
    reports_dir: Path,
    run_id: str,
    scenario_specs: list[dict[str, Any]],
) -> Path:
    """Create a synthetic run directory with scenario result files.

    Each spec dict should have:
      - id: str (scenario_id)
      - status: str (e.g. PASS, SKIP, FAIL)
      - (optional) asserts: list of {type, status, notes, depth_level}
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

    # Build scenarios-snapshot.yaml
    snap_scenarios: list[dict[str, Any]] = []
    for spec in scenario_specs:
        snap_scenarios.append(
            {
                "id": spec["id"],
                "name": f"Scenario {spec['id']}",
                "cluster": {"provider": "kind", "preinstall": []},
            }
        )
    _write_yaml(
        run_dir / "scenarios-snapshot.yaml",
        {"scenarios": snap_scenarios},
    )

    # Build agent-1/result.yaml
    results: list[dict[str, Any]] = []
    for spec in scenario_specs:
        result_entry: dict[str, Any] = {
            "scenario_id": spec["id"],
            "status": spec["status"],
            "duration_s": 1.5,
            "log_dir": f"/tmp/{spec['id']}",
        }
        if "asserts" in spec:
            result_entry["asserts"] = spec["asserts"]
        results.append(result_entry)

    agent_dir = run_dir / "agent-1"
    agent_dir.mkdir(exist_ok=True)
    _write_yaml(
        agent_dir / "result.yaml",
        {"agent": 1, "results": results},
    )

    return run_dir


# ---------------------------------------------------------------------------
# VAL-CONTRACT-020: SKIP present in STATUS_RANK
# ---------------------------------------------------------------------------


class TestSkipInStatusRank:
    """VAL-CONTRACT-020: SKIP is present in STATUS_RANK with a non-failing rank."""

    def test_skip_in_status_rank(self) -> None:
        """SKIP is a key in STATUS_RANK."""
        from testgrid.collect import STATUS_RANK

        assert "SKIP" in STATUS_RANK, "STATUS_RANK missing SKIP key"

    def test_skip_rank_below_pass(self) -> None:
        """SKIP rank is below PASS (non-failing)."""
        from testgrid.collect import STATUS_RANK

        assert STATUS_RANK["SKIP"] < STATUS_RANK["PASS"], (
            f"SKIP rank {STATUS_RANK['SKIP']} should be below PASS rank {STATUS_RANK['PASS']}"
        )

    def test_skip_rank_not_equal_to_fail(self) -> None:
        """SKIP rank is different from FAIL rank."""
        from testgrid.collect import STATUS_RANK

        assert STATUS_RANK["SKIP"] != STATUS_RANK["FAIL"], (
            "SKIP must not have the same rank as FAIL"
        )


# ---------------------------------------------------------------------------
# VAL-CONTRACT-021: SKIP rank ordering is non-failing relative to FAIL
# ---------------------------------------------------------------------------


class TestSkipRankOrdering:
    """VAL-CONTRACT-021: SKIP rank ordering per architecture requirement."""

    def test_skip_above_fail(self) -> None:
        """SKIP rank is strictly greater than FAIL (0)."""
        from testgrid.collect import STATUS_RANK

        assert STATUS_RANK["SKIP"] > STATUS_RANK["FAIL"], (
            f"SKIP rank {STATUS_RANK['SKIP']} should be > FAIL rank {STATUS_RANK['FAIL']}"
        )

    def test_skip_between_interrupted_and_authored(self) -> None:
        """SKIP is ranked below AUTHORED, above INTERRUPTED per architecture §3.A."""
        from testgrid.collect import STATUS_RANK

        assert STATUS_RANK["INTERRUPTED"] < STATUS_RANK["SKIP"], (
            f"SKIP {STATUS_RANK['SKIP']} should be > INTERRUPTED {STATUS_RANK['INTERRUPTED']}"
        )
        assert STATUS_RANK["SKIP"] < STATUS_RANK["AUTHORED"], (
            f"SKIP {STATUS_RANK['SKIP']} should be < AUTHORED {STATUS_RANK['AUTHORED']}"
        )

    def test_skip_non_failing_rollup(self) -> None:
        """SKIP + PASS scenarios: the worst rolled status is SKIP (not FAIL)."""
        from testgrid.collect import STATUS_RANK, Scenario

        scenarios = [
            Scenario(id="sc-1", status="PASS"),
            Scenario(id="sc-2", status="SKIP"),
        ]
        rolled = min(
            (s.status for s in scenarios),
            key=lambda st: STATUS_RANK.get(st, 99),
        )
        assert rolled == "SKIP", f"SKIP + PASS rollup should be SKIP, got {rolled}"

    def test_fail_still_worse_than_skip(self) -> None:
        """FAIL + SKIP: FAIL is worse than SKIP."""
        from testgrid.collect import STATUS_RANK, Scenario

        scenarios = [
            Scenario(id="sc-1", status="SKIP"),
            Scenario(id="sc-2", status="FAIL"),
        ]
        rolled = min(
            (s.status for s in scenarios),
            key=lambda st: STATUS_RANK.get(st, 99),
        )
        assert rolled == "FAIL", f"FAIL + SKIP rollup should be FAIL, got {rolled}"


# ---------------------------------------------------------------------------
# VAL-CONTRACT-022: SKIP in KNOWN_STATUSES — never normalized to UNKNOWN
# ---------------------------------------------------------------------------


class TestSkipKnownStatus:
    """VAL-CONTRACT-022: SKIP in KNOWN_STATUSES."""

    def test_skip_in_known_statuses(self) -> None:
        """SKIP is in KNOWN_STATUSES (computed from STATUS_RANK keys)."""
        from testgrid.collect import KNOWN_STATUSES

        assert "SKIP" in KNOWN_STATUSES, "SKIP missing from KNOWN_STATUSES"

    def test_skip_not_normalized_to_unknown(self) -> None:
        """A scenario with status: SKIP is NOT coerced to UNKNOWN."""
        from testgrid.collect import KNOWN_STATUSES

        # Simulate what _scenario_from_result does
        raw_status = "SKIP"
        if raw_status not in KNOWN_STATUSES:
            raw_status = "UNKNOWN"
        assert raw_status == "SKIP", "SKIP should not be normalized to UNKNOWN"

    def test_skip_scenario_parsed_as_skip(self, tmp_path: Path) -> None:
        """A result.yaml with scenario status: SKIP yields Scenario.status == 'SKIP'."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_skip(
            reports,
            "run-skip-status",
            [{"id": "sc-skip", "status": "SKIP"}],
        )
        run = collect_run(reports, "run-skip-status")
        assert len(run.scenarios) == 1
        assert run.scenarios[0].status == "SKIP", f"Expected SKIP, got {run.scenarios[0].status}"


# ---------------------------------------------------------------------------
# VAL-CONTRACT-023: Per-assert SKIP status preserved by collector
# ---------------------------------------------------------------------------


class TestPerAssertSkip:
    """VAL-CONTRACT-023: Per-assert SKIP preserved in Assertion objects."""

    def test_per_assert_skip_preserved(self, tmp_path: Path) -> None:
        """Assert entries with status: SKIP load as Assertion with status == 'SKIP'."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_skip(
            reports,
            "run-assert-skip",
            [
                {
                    "id": "sc-assert-skip",
                    "status": "PASS",
                    "asserts": [
                        {"type": "pods-ready", "status": "SKIP", "notes": "no pods to check"},
                        {"type": "service-reachable", "status": "PASS", "notes": "200 OK"},
                    ],
                }
            ],
        )
        run = collect_run(reports, "run-assert-skip")
        assert len(run.scenarios) == 1
        scenario = run.scenarios[0]
        assert len(scenario.asserts) == 2
        assert scenario.asserts[0].status == "SKIP", (
            f"Expected SKIP, got {scenario.asserts[0].status}"
        )
        assert scenario.asserts[1].status == "PASS"

    def test_skip_assert_not_counted_as_pass(self, tmp_path: Path) -> None:
        """asserts_passed excludes SKIP asserts."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_skip(
            reports,
            "run-skip-pass-count",
            [
                {
                    "id": "sc-skip-count",
                    "status": "PASS",
                    "asserts": [
                        {"type": "pods-ready", "status": "SKIP", "notes": ""},
                        {"type": "service-reachable", "status": "PASS", "notes": ""},
                    ],
                }
            ],
        )
        run = collect_run(reports, "run-skip-pass-count")
        scenario = run.scenarios[0]
        assert scenario.asserts_passed == 1, (
            f"Expected 1 passed assert (SKIP excluded), got {scenario.asserts_passed}"
        )
        assert scenario.asserts_total == 2


# ---------------------------------------------------------------------------
# depth_level on Assertion
# ---------------------------------------------------------------------------


class TestDepthLevelIngestion:
    """depth_level is ingested from result.yaml onto the Assertion dataclass."""

    def test_depth_level_field_exists_on_assertion(self) -> None:
        """Assertion dataclass has a depth_level attribute with a default."""
        from testgrid.collect import Assertion

        a = Assertion(type="test", status="PASS")
        assert hasattr(a, "depth_level"), "Assertion missing depth_level field"
        # Default should be empty string (backward-compatible, additive)
        assert a.depth_level == ""

    def test_depth_level_parsed_from_result_yaml(self, tmp_path: Path) -> None:
        """depth_level values from result.yaml are stored on Assertion objects."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_skip(
            reports,
            "run-depth",
            [
                {
                    "id": "sc-depth",
                    "status": "PASS",
                    "asserts": [
                        {
                            "type": "pods-ready",
                            "status": "PASS",
                            "notes": "",
                            "depth_level": "L2",
                        },
                        {
                            "type": "smoke-script",
                            "status": "PASS",
                            "notes": "",
                            "depth_level": "L0",
                        },
                    ],
                }
            ],
        )
        run = collect_run(reports, "run-depth")
        scenario = run.scenarios[0]
        assert scenario.asserts[0].depth_level == "L2", (
            f"Expected L2, got {scenario.asserts[0].depth_level}"
        )
        assert scenario.asserts[1].depth_level == "L0", (
            f"Expected L0, got {scenario.asserts[1].depth_level}"
        )

    def test_depth_level_absent_defaults_to_empty(self, tmp_path: Path) -> None:
        """When depth_level is absent from result.yaml, it defaults to empty string."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_skip(
            reports,
            "run-no-depth",
            [
                {
                    "id": "sc-no-depth",
                    "status": "PASS",
                    "asserts": [
                        {"type": "pods-ready", "status": "PASS", "notes": ""},
                    ],
                }
            ],
        )
        run = collect_run(reports, "run-no-depth")
        scenario = run.scenarios[0]
        assert scenario.asserts[0].depth_level == "", (
            f"Expected empty default, got {scenario.asserts[0].depth_level!r}"
        )

    def test_depth_level_unknown_value_preserved(self, tmp_path: Path) -> None:
        """Non-standard depth_level values are preserved as-is (no normalization)."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_skip(
            reports,
            "run-depth-weird",
            [
                {
                    "id": "sc-depth-weird",
                    "status": "PASS",
                    "asserts": [
                        {
                            "type": "custom-assert",
                            "status": "PASS",
                            "notes": "",
                            "depth_level": "L5-experimental",
                        },
                    ],
                }
            ],
        )
        run = collect_run(reports, "run-depth-weird")
        scenario = run.scenarios[0]
        # depth_level is additive and passed through without validation
        assert scenario.asserts[0].depth_level == "L5-experimental", (
            f"Expected 'L5-experimental', got {scenario.asserts[0].depth_level!r}"
        )


# ---------------------------------------------------------------------------
# VAL-CONTRACT-043: Unknown status still normalizes to UNKNOWN
# ---------------------------------------------------------------------------


class TestUnknownStatusNormalization:
    """VAL-CONTRACT-043: Out-of-vocabulary statuses still normalize to UNKNOWN."""

    def test_bogus_status_normalized_to_unknown(self, tmp_path: Path) -> None:
        """A result.yaml with status: BOGUS is normalized to UNKNOWN."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_skip(
            reports,
            "run-bogus",
            [{"id": "sc-bogus", "status": "BOGUS"}],
        )
        run = collect_run(reports, "run-bogus")
        assert run.scenarios[0].status == "UNKNOWN", (
            f"Expected UNKNOWN, got {run.scenarios[0].status}"
        )

    def test_skip_not_affected_by_bogus_normalization(self, tmp_path: Path) -> None:
        """SKIP + BOGUS in the same run: SKIP stays SKIP, BOGUS becomes UNKNOWN."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_skip(
            reports,
            "run-mixed",
            [
                {"id": "sc-skip", "status": "SKIP"},
                {"id": "sc-bogus", "status": "BOGUS"},
            ],
        )
        run = collect_run(reports, "run-mixed")
        statuses = {s.id: s.status for s in run.scenarios}
        assert statuses["sc-skip"] == "SKIP", f"Expected SKIP, got {statuses['sc-skip']}"
        assert statuses["sc-bogus"] == "UNKNOWN", f"Expected UNKNOWN, got {statuses['sc-bogus']}"

    def test_empty_status_falls_back_to_untested(self, tmp_path: Path) -> None:
        """Empty/missing scenario status defaults to UNTESTED."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_skip(
            reports,
            "run-empty-status",
            [{"id": "sc-empty", "status": ""}],
        )
        run = collect_run(reports, "run-empty-status")
        assert run.scenarios[0].status == "UNTESTED", (
            f"Expected UNTESTED, got {run.scenarios[0].status}"
        )


# ---------------------------------------------------------------------------
# VAL-CONTRACT-042: Collect roundtrip preserves SKIP in status_counts
# ---------------------------------------------------------------------------


class TestSkipInStatusCounts:
    """VAL-CONTRACT-042: Run.status_counts includes a SKIP bucket."""

    def test_status_counts_includes_skip(self, tmp_path: Path) -> None:
        """status_counts dict has a 'SKIP' key when SKIP scenarios exist."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_skip(
            reports,
            "run-counts",
            [
                {"id": "sc-pass", "status": "PASS"},
                {"id": "sc-skip-1", "status": "SKIP"},
                {"id": "sc-skip-2", "status": "SKIP"},
                {"id": "sc-fail", "status": "FAIL"},
            ],
        )
        run = collect_run(reports, "run-counts")
        counts = run.status_counts
        assert counts["SKIP"] == 2, f"Expected 2 SKIP, got {counts}"
        assert counts["PASS"] == 1
        assert counts["FAIL"] == 1

    def test_status_counts_no_skip_when_none(self, tmp_path: Path) -> None:
        """status_counts does NOT include SKIP when no SKIP scenarios exist."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_skip(
            reports,
            "run-no-skip",
            [
                {"id": "sc-1", "status": "PASS"},
                {"id": "sc-2", "status": "FAIL"},
            ],
        )
        run = collect_run(reports, "run-no-skip")
        counts = run.status_counts
        assert "SKIP" not in counts, f"SKIP should not appear when no SKIP scenarios, got {counts}"

    def test_status_counts_skip_not_under_unknown(self, tmp_path: Path) -> None:
        """SKIP scenarios are counted under 'SKIP', not 'UNKNOWN'."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_run_with_skip(
            reports,
            "run-skip-vs-unknown",
            [
                {"id": "sc-skip", "status": "SKIP"},
            ],
        )
        run = collect_run(reports, "run-skip-vs-unknown")
        counts = run.status_counts
        assert "SKIP" in counts, "SKIP should be its own bucket"
        assert "UNKNOWN" not in counts, "No UNKNOWN scenarios expected"
        assert counts["SKIP"] == 1


# ---------------------------------------------------------------------------
# VAL-CROSS-002: Bundle mirror byte-identical after collect.py changes
# ---------------------------------------------------------------------------


class TestBundleMirror:
    """VAL-CROSS-002: The sync script exists and the bundled engine mirror is
    structurally present (byte-level drift checked during handoff)."""

    def test_sync_script_exists(self) -> None:
        """sync-engine.sh exists in the expected location."""
        sync_script = (
            REPO_ROOT / "engine" / "skills" / "chart-test-swarm" / "scripts" / "sync-engine.sh"
        )
        assert sync_script.is_file(), f"sync-engine.sh not found at {sync_script}"

    def test_collect_py_in_bundled_mirror(self) -> None:
        """collect.py exists in the bundled engine mirror."""
        bundled = (
            REPO_ROOT
            / "engine"
            / "skills"
            / "chart-test-swarm"
            / "engine"
            / "testgrid"
            / "src"
            / "testgrid"
            / "collect.py"
        )
        assert bundled.is_file(), f"Bundled collect.py not found at {bundled}"
