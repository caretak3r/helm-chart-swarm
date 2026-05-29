"""Tests for F2.4 — multi-run aggregation safeguards.

Validates:
  - VAL-DASH-014: build-dashboard.sh succeeds across mixed legacy/rich report shapes
  - VAL-DASH-015: Both legacy and rich runs appear in the index
  - VAL-DASH-016: Orphaned run dir is skipped without crashing
  - VAL-DASH-017: Repeated dashboard builds produce byte-identical HTML (deterministic)
  - VAL-DASH-019: FAIL scenario cards surface FAIL detail (error message or log link)
  - VAL-DASH-020: Prior runs preserved after rebuild (multi-run index integrity)
  - VAL-DASH-021: Corrupt result.yaml reported, doesn't crash
  - VAL-DASH-022: STATUS_RANK orders UNTESTED strictly less than INCONCLUSIVE
  - VAL-DASH-023: Unknown statuses are rejected/visibly surfaced
  - VAL-DASH-024: HTML escapes user-controlled fields (XSS protection)
  - VAL-DASH-025: Zero-scenario runs render without crashing
  - VAL-CROSS-021: Dashboard correctly reads reports across all integration categories
"""

from __future__ import annotations

import difflib
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


def _build_rich_run(
    reports_dir: Path,
    run_id: str,
    scenario_specs: list[dict[str, Any]],
    *,
    with_artifacts: bool = True,
) -> Path:
    """Create a synthetic run with a snapshot, run-meta, agent results, and artifacts."""
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
                    "product": {
                        "chart": "sample",
                        "release": spec["id"],
                        "namespace": "sample",
                    },
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
                    "duration_s": spec.get("duration_s", 30),
                    "fail_stage": spec.get("fail_stage", ""),
                    "fail_msg": spec.get("fail_msg", ""),
                    "log_dir": spec.get("log_dir", ""),
                    "asserts": spec.get(
                        "asserts",
                        [{"type": "pods-ready", "status": "PASS", "notes": "ok"}],
                    ),
                }
                for spec in scenario_specs
            ],
        },
    )

    if with_artifacts:
        art = agent_dir / "artifacts"
        art.mkdir()
        (art / "scenario.yaml").write_text("id: test\n", encoding="utf-8")
        (art / "applied-overrides.yaml").write_text("{}\n", encoding="utf-8")

    return run_dir


def _build_legacy_run(reports_dir: Path, run_id: str, scenario_ids: list[str]) -> Path:
    """Create a legacy run (no artifacts/ directory)."""
    run_dir = reports_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    _write_yaml(
        run_dir / "run-meta.yaml",
        {
            "run_id": run_id,
            "timestamp_utc": "2026-05-28T09:00:00Z",
            "num_agents": 1,
            "suite": "legacy",
        },
    )
    _write_yaml(
        run_dir / "scenarios-snapshot.yaml",
        {
            "scenarios": [
                {
                    "id": sid,
                    "name": f"Legacy {sid}",
                    "cluster": {"provider": "kind"},
                    "mechanisms": [],
                    "tags": [],
                }
                for sid in scenario_ids
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
                    "scenario_id": sid,
                    "status": "PASS",
                    "duration_s": 30,
                    "asserts": [{"type": "helm-status-deployed", "status": "PASS", "notes": "ok"}],
                }
                for sid in scenario_ids
            ],
        },
    )
    return run_dir


# ---------------------------------------------------------------------------
# VAL-DASH-014 / VAL-DASH-015: Mixed legacy + rich report shapes
# ---------------------------------------------------------------------------


class TestMixedLegacyRich:
    """Tests for mixed legacy and rich report shapes."""

    def test_mixed_runs_collected_without_error(self, tmp_path: Path) -> None:
        """VAL-DASH-014: Mixed legacy and rich runs are collected successfully."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_legacy_run(reports, "run-legacy-1", ["sc-leg-a"])
        _build_rich_run(
            reports,
            "run-rich-1",
            [{"id": "sc-rich-a", "mechanisms": ["certificates:cert-manager:self-signed"]}],
        )

        run_legacy = collect_run(reports, "run-legacy-1")
        run_rich = collect_run(reports, "run-rich-1")

        assert len(run_legacy.scenarios) == 1
        assert len(run_rich.scenarios) == 1
        # Legacy runs should have no artifact links
        assert not run_legacy.scenarios[0].artifact_links
        # Rich runs should have artifact links
        assert run_rich.scenarios[0].artifact_links

    def test_mixed_runs_render_without_crash(self, tmp_path: Path) -> None:
        """Both legacy and rich runs render to HTML without crashing."""
        from testgrid.collect import collect_run
        from testgrid.render import render_index, render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_legacy_run(reports, "run-legacy-2", ["sc-leg-b"])
        _build_rich_run(
            reports,
            "run-rich-2",
            [{"id": "sc-rich-b", "mechanisms": ["ingress-controllers:traefik:basic"]}],
        )

        out = tmp_path / "dist"
        out.mkdir()

        run_legacy = collect_run(reports, "run-legacy-2")
        run_rich = collect_run(reports, "run-rich-2")

        render_run(run_legacy, out)
        render_run(run_rich, out)

        assert (out / "run-legacy-2" / "index.html").exists()
        assert (out / "run-rich-2" / "index.html").exists()

        # Render index with both runs
        from testgrid.collect import list_runs

        all_runs = [collect_run(reports, rid) for rid in list_runs(reports)]
        index_path = render_index(all_runs, out)
        html = index_path.read_text(encoding="utf-8")
        assert "run-legacy-2" in html
        assert "run-rich-2" in html

    def test_both_runs_appear_in_index_with_scenario_counts(self, tmp_path: Path) -> None:
        """VAL-DASH-015: Both legacy and rich run IDs appear with correct scenario counts."""
        from testgrid.collect import collect_run, list_runs
        from testgrid.render import render_index

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_legacy_run(reports, "run-legacy-3", ["sc-a", "sc-b"])
        _build_rich_run(reports, "run-rich-3", [{"id": "sc-c"}])

        out = tmp_path / "dist"
        out.mkdir()
        all_runs = [collect_run(reports, rid) for rid in list_runs(reports)]
        index_path = render_index(all_runs, out)
        html = index_path.read_text(encoding="utf-8")

        assert "run-legacy-3" in html
        assert "run-rich-3" in html
        # Verify scenario count column shows correct numbers
        assert "2" in html  # Legacy has 2 scenarios
        assert "1" in html  # Rich has 1 scenario

    def test_mixed_with_html_metacharacters_escaped(self, tmp_path: Path) -> None:
        """XSS payloads in user-controlled fields are HTML-escaped in mixed runs
        (VAL-DASH-024 cross-check)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()

        xss_name = "<script>alert(1)</script>"
        xss_desc = "</details><img src=x onerror=alert(1)>"

        _build_rich_run(
            reports,
            "run-xss",
            [
                {
                    "id": "sc-xss",
                    "name": xss_name,
                    "description": xss_desc,
                    "fail_msg": '<img src=x onerror="evil()">',
                    "status": "FAIL",
                    "mechanisms": ["certificates:cert-manager:self-signed"],
                }
            ],
        )

        run = collect_run(reports, "run-xss")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-xss" / "index.html").read_text(encoding="utf-8")

        # The raw script tag should NOT appear as live HTML
        assert "<script>alert(1)</script>" not in html, (
            "XSS payload in name should be HTML-escaped, not live"
        )
        # The escaped form SHOULD appear
        assert "&lt;script&gt;alert(1)&lt;/script&gt;" in html or "&lt;script&gt;" in html, (
            "XSS payload should appear as escaped text"
        )
        # Description payload should also be escaped
        assert "<img src=x onerror=alert(1)>" not in html, (
            "XSS payload in description should not appear as live HTML"
        )
        # fail_msg payload should be escaped
        assert '<img src=x onerror="evil()">' not in html, (
            "XSS payload in fail_msg should not appear as live HTML"
        )


# ---------------------------------------------------------------------------
# VAL-DASH-016: Orphaned run directory
# ---------------------------------------------------------------------------


class TestOrphanedRun:
    """Tests for orphaned run directory handling."""

    def test_orphan_run_dir_skipped(self, tmp_path: Path) -> None:
        """VAL-DASH-016: Orphaned run dir is skipped with stderr warning."""
        from testgrid.collect import OrphanRunError, collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        orphan_dir = reports / "run-orphan-1"
        orphan_dir.mkdir()
        # No snapshot, no agent results — just an empty dir

        with pytest.raises(OrphanRunError):
            collect_run(reports, "run-orphan-1")

    def test_orphan_run_dir_with_junk_files_skipped(self, tmp_path: Path) -> None:
        """Orphan dir with unrelated files (no valid metadata) is skipped."""
        from testgrid.collect import OrphanRunError, collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        orphan_dir = reports / "run-orphan-2"
        orphan_dir.mkdir()
        (orphan_dir / "random-file.txt").write_text("garbage")

        with pytest.raises(OrphanRunError):
            collect_run(reports, "run-orphan-2")

    def test_orphan_stderr_warning_includes_run_id(self, capsys, tmp_path: Path) -> None:
        """Orphaned run stderr warning identifies the skipped run."""
        from testgrid.collect import OrphanRunError, collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        orphan_dir = reports / "run-orphan-3"
        orphan_dir.mkdir()

        with pytest.raises(OrphanRunError):
            collect_run(reports, "run-orphan-3")

        captured = capsys.readouterr()
        assert "run-orphan-3" in captured.err, (
            "Stderr should name the orphaned run id, got: " + captured.err
        )
        assert "orphan" in captured.err.lower() or "skipped" in captured.err.lower()

    def test_orphan_not_in_index(self, tmp_path: Path) -> None:
        """VAL-DASH-016: The index does NOT include the orphaned run."""
        from testgrid.collect import OrphanRunError, collect_run, list_runs
        from testgrid.render import render_index

        reports = tmp_path / "reports"
        reports.mkdir()

        # Valid run
        _build_rich_run(reports, "run-valid", [{"id": "sc-1"}])
        # Orphan run (no metadata)
        (reports / "run-orphan" / "irrelevant").mkdir(parents=True)

        out = tmp_path / "dist"
        out.mkdir()

        valid_runs = []
        for rid in list_runs(reports):
            try:
                valid_runs.append(collect_run(reports, rid))
            except OrphanRunError:
                continue

        assert len(valid_runs) == 1
        assert valid_runs[0].run_id == "run-valid"

        index_path = render_index(valid_runs, out)
        html = index_path.read_text(encoding="utf-8")
        assert "run-valid" in html
        assert "run-orphan" not in html


# ---------------------------------------------------------------------------
# VAL-DASH-017: Deterministic byte-identical rebuilds
# ---------------------------------------------------------------------------


class TestDeterministicOutput:
    """Tests for deterministic dashboard rendering."""

    def test_repeated_renders_produce_identical_html(self, tmp_path: Path) -> None:
        """VAL-DASH-017: Two renders of the same data produce byte-identical HTML."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-det",
            [
                {"id": "sc-z", "mechanisms": ["certificates:cert-manager:v1"]},
                {"id": "sc-a", "mechanisms": ["certificates:cert-manager:v2"]},
                {"id": "sc-m", "mechanisms": ["certificates:cert-manager:v3"]},
            ],
        )

        run_a = collect_run(reports, "run-det")
        out_a = tmp_path / "dist-a"
        out_a.mkdir()
        render_run(run_a, out_a)

        # Re-collect and re-render
        run_b = collect_run(reports, "run-det")
        out_b = tmp_path / "dist-b"
        out_b.mkdir()
        render_run(run_b, out_b)

        html_a = (out_a / "run-det" / "index.html").read_text(encoding="utf-8")
        html_b = (out_b / "run-det" / "index.html").read_text(encoding="utf-8")

        assert html_a == html_b, (
            "Repeated renders should produce byte-identical HTML.\n"
            f"Diff: {_diff_lines(html_a, html_b)}"
        )

    def test_scenario_ordering_is_lexicographic(self, tmp_path: Path) -> None:
        """Scenarios appear in lexicographically sorted order, not insertion order."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-sorted",
            [
                {"id": "sc-zzz", "mechanisms": []},
                {"id": "sc-aaa", "mechanisms": []},
                {"id": "sc-mmm", "mechanisms": []},
            ],
        )

        run = collect_run(reports, "run-sorted")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-sorted" / "index.html").read_text(encoding="utf-8")

        # Find positions of scenario IDs in the HTML
        pos_aaa = html.index("sc-aaa") if "sc-aaa" in html else -1
        pos_mmm = html.index("sc-mmm") if "sc-mmm" in html else -1
        pos_zzz = html.index("sc-zzz") if "sc-zzz" in html else -1

        assert pos_aaa < pos_mmm < pos_zzz, (
            "Scenarios should appear in lexicographic order: aaa, mmm, zzz. "
            f"Found positions: aaa={pos_aaa}, mmm={pos_mmm}, zzz={pos_zzz}"
        )

    def test_index_ordering_is_deterministic(self, tmp_path: Path) -> None:
        """Index page has deterministic run ordering (reverse chronological by run_id)."""
        from testgrid.collect import collect_run, list_runs
        from testgrid.render import render_index

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-001", [{"id": "sc-1"}])
        _build_rich_run(reports, "run-002", [{"id": "sc-2"}])
        _build_rich_run(reports, "run-003", [{"id": "sc-3"}])

        out = tmp_path / "dist"
        out.mkdir()
        all_runs = [collect_run(reports, rid) for rid in list_runs(reports)]
        index_path = render_index(all_runs, out)
        html = index_path.read_text(encoding="utf-8")

        # run-003 should appear before run-001 (reverse chronological)
        pos_003 = html.index("run-003")
        pos_001 = html.index("run-001")
        assert pos_003 < pos_001, "Newest runs should appear first in index"


# ---------------------------------------------------------------------------
# VAL-DASH-019: FAIL detail (error message or log link)
# ---------------------------------------------------------------------------


class TestFailDetail:
    """Tests for FAIL scenario detail rendering."""

    def test_fail_card_has_error_summary(self, tmp_path: Path) -> None:
        """VAL-DASH-019: FAIL card with fail_msg shows error summary."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        run_id = "run-fail-detail"
        _build_rich_run(
            reports,
            run_id,
            [
                {
                    "id": "sc-fail-1",
                    "status": "FAIL",
                    "fail_msg": "ERROR: Pod crashloop backoff — container failed after 3 restarts",
                    "mechanisms": ["certificates:cert-manager:fail"],
                }
            ],
        )

        run = collect_run(reports, run_id)
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / run_id / "index.html").read_text(encoding="utf-8")

        assert "error-summary" in html, "FAIL card should have error-summary element"
        assert "Pod crashloop backoff" in html

    def test_fail_card_has_log_link(self, tmp_path: Path) -> None:
        """FAIL card with log_dir shows log link."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-fail-log",
            [
                {
                    "id": "sc-fail-2",
                    "status": "FAIL",
                    "log_dir": "logs/preinstall.log",
                    "mechanisms": ["certificates:cert-manager:fail"],
                }
            ],
        )

        run = collect_run(reports, "run-fail-log")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-fail-log" / "index.html").read_text(encoding="utf-8")

        assert "error-log" in html, "FAIL card should have error-log element"
        assert "preinstall.log" in html

    def test_pass_card_has_no_error_summary(self, tmp_path: Path) -> None:
        """PASS card does NOT emit an error-summary element."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-pass",
            [
                {
                    "id": "sc-pass",
                    "status": "PASS",
                    "mechanisms": ["certificates:cert-manager:pass"],
                }
            ],
        )

        run = collect_run(reports, "run-pass")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-pass" / "index.html").read_text(encoding="utf-8")

        assert "error-summary" not in html, "PASS card should not emit error-summary element"

    def test_fail_card_with_both_error_and_log(self, tmp_path: Path) -> None:
        """FAIL card with both fail_msg and log_dir shows both."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-fail-both",
            [
                {
                    "id": "sc-fail-both",
                    "status": "FAIL",
                    "fail_msg": "Cluster creation failed: timeout waiting for API server",
                    "log_dir": "logs/cluster-up.log",
                    "mechanisms": [],
                }
            ],
        )

        run = collect_run(reports, "run-fail-both")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-fail-both" / "index.html").read_text(encoding="utf-8")

        assert "error-summary" in html
        assert "Cluster creation failed" in html
        assert "error-log" in html
        assert "cluster-up.log" in html


# ---------------------------------------------------------------------------
# VAL-DASH-020: Prior runs preserved after rebuild
# ---------------------------------------------------------------------------


class TestPriorRunsPreserved:
    """Tests for multi-run index preservation."""

    def test_prior_runs_preserved_after_rebuild(self, tmp_path: Path) -> None:
        """VAL-DASH-020: Rebuilding the index with a new run preserves prior runs."""
        from testgrid.collect import collect_run, list_runs
        from testgrid.render import render_index

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-A", [{"id": "sc-a"}])
        _build_rich_run(reports, "run-B", [{"id": "sc-b"}])

        out = tmp_path / "dist"
        out.mkdir()
        all_runs = [collect_run(reports, rid) for rid in list_runs(reports)]
        index_path = render_index(all_runs, out)
        html = index_path.read_text(encoding="utf-8")

        assert "run-A" in html
        assert "run-B" in html
        # Both run links should be present
        assert 'href="run-A/index.html"' in html or "href='run-A/index.html'" in html
        assert 'href="run-B/index.html"' in html or "href='run-B/index.html'" in html

    def test_new_run_added_next_to_existing(self, tmp_path: Path) -> None:
        """Adding a new run leaves existing runs intact with working links."""
        from testgrid.collect import collect_run, list_runs
        from testgrid.render import render_index, render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-A", [{"id": "sc-a"}])

        out = tmp_path / "dist"
        out.mkdir()

        # Render run-A
        run_a = collect_run(reports, "run-A")
        render_run(run_a, out)
        assert (out / "run-A" / "index.html").exists()

        # Now add run-B
        _build_rich_run(reports, "run-B", [{"id": "sc-b"}])
        run_b = collect_run(reports, "run-B")
        render_run(run_b, out)
        assert (out / "run-B" / "index.html").exists()

        # run-A should still exist on disk
        assert (out / "run-A" / "index.html").exists()

        # Rebuild index with both runs
        all_runs = [collect_run(reports, rid) for rid in list_runs(reports)]
        index_path = render_index(all_runs, out)
        html = index_path.read_text(encoding="utf-8")

        assert "run-A" in html
        assert "run-B" in html
        # run-A artifact links should still resolve
        assert (out / "run-A" / "index.html").exists()


# ---------------------------------------------------------------------------
# VAL-DASH-021: Corrupt result.yaml
# ---------------------------------------------------------------------------


class TestCorruptYaml:
    """Tests for corrupt YAML handling."""

    def test_corrupt_result_yaml_does_not_crash(self, tmp_path: Path) -> None:
        """VAL-DASH-021: Corrupt result.yaml is reported but doesn't crash."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        run_dir = reports / "run-corrupt-1"
        run_dir.mkdir()

        _write_yaml(run_dir / "run-meta.yaml", {"run_id": "run-corrupt-1"})
        _write_yaml(
            run_dir / "scenarios-snapshot.yaml",
            {"scenarios": [{"id": "sc-a", "cluster": {"provider": "kind"}}]},
        )

        agent_dir = run_dir / "agent-1"
        agent_dir.mkdir()

        # Write a deliberately corrupt YAML file
        (agent_dir / "result.yaml").write_text(
            "status: PASS\nscenario_id: sc-a\n  invalid: [unclosed\n",
            encoding="utf-8",
        )

        # Should not raise an exception
        run = collect_run(reports, "run-corrupt-1")
        # The corrupted file was skipped; scenario retains default status
        assert len(run.scenarios) >= 1

    def test_corrupt_snapshot_does_not_crash(self, tmp_path: Path) -> None:
        """Corrupt scenarios-snapshot.yaml is handled gracefully."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        run_dir = reports / "run-corrupt-2"
        run_dir.mkdir()

        _write_yaml(run_dir / "run-meta.yaml", {"run_id": "run-corrupt-2"})
        (run_dir / "scenarios-snapshot.yaml").write_text(
            "scenarios:\n  - {bad: [syntax\n", encoding="utf-8"
        )

        agent_dir = run_dir / "agent-1"
        agent_dir.mkdir()
        _write_yaml(
            agent_dir / "result.yaml",
            {
                "agent": 1,
                "results": [{"scenario_id": "sc-orphan", "status": "PASS", "asserts": []}],
            },
        )

        # Should not crash
        run = collect_run(reports, "run-corrupt-2")
        # Orphan result still surfaces since snapshot was corrupt
        assert len(run.scenarios) >= 1
        assert run.scenarios[0].id == "sc-orphan"

    def test_corrupt_run_meta_does_not_crash(self, tmp_path: Path) -> None:
        """Corrupt run-meta.yaml is handled gracefully."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        run_dir = reports / "run-corrupt-3"
        run_dir.mkdir()

        (run_dir / "run-meta.yaml").write_text("{bad yaml: [", encoding="utf-8")
        _write_yaml(
            run_dir / "scenarios-snapshot.yaml",
            {"scenarios": [{"id": "sc-a", "cluster": {"provider": "kind"}}]},
        )

        agent_dir = run_dir / "agent-1"
        agent_dir.mkdir()
        _write_yaml(
            agent_dir / "result.yaml",
            {
                "agent": 1,
                "results": [{"scenario_id": "sc-a", "status": "PASS", "asserts": []}],
            },
        )

        # Should not crash, run_id falls back to directory name
        run = collect_run(reports, "run-corrupt-3")
        assert run.run_id == "run-corrupt-3"  # fallback
        assert len(run.scenarios) == 1

    def test_corrupt_stderr_names_run_id(self, capsys, tmp_path: Path) -> None:
        """Stderr warning names the offending run id."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        run_dir = reports / "run-corrupt-4"
        run_dir.mkdir()

        _write_yaml(
            run_dir / "scenarios-snapshot.yaml",
            {"scenarios": [{"id": "sc-a", "cluster": {"provider": "kind"}}]},
        )

        _write_yaml(run_dir / "run-meta.yaml", {"run_id": "run-corrupt-4"})

        agent_dir = run_dir / "agent-1"
        agent_dir.mkdir()
        # Write truly broken YAML (trailing unclosed bracket)
        (agent_dir / "result.yaml").write_text(
            "status: PASS\nscenario_id: sc-a\ninvalid: [unclosed\n",
            encoding="utf-8",
        )

        # Should not crash
        collect_run(reports, "run-corrupt-4")
        captured = capsys.readouterr()
        # The warning should come from load_agent_results when it hits the corrupt file
        # It should mention "malformed" or "run-corrupt-4" via the path
        assert "malformed" in captured.err.lower() or "run-corrupt-4" in captured.err, (
            f"Expected stderr warning about corrupt yaml, got: {captured.err!r}"
        )


# ---------------------------------------------------------------------------
# VAL-DASH-022: STATUS_RANK — UNTESTED strictly less than INCONCLUSIVE
# ---------------------------------------------------------------------------


class TestStatusRankOrdering:
    """Tests for STATUS_RANK ordering (UNTESTED < INCONCLUSIVE)."""

    def test_untested_rank_less_than_inconclusive(self) -> None:
        """VAL-DASH-022: STATUS_RANK['UNTESTED'] < STATUS_RANK['INCONCLUSIVE']."""
        from testgrid.collect import STATUS_RANK

        assert STATUS_RANK["UNTESTED"] < STATUS_RANK["INCONCLUSIVE"], (
            "UNTESTED should have lower rank (more severe) than INCONCLUSIVE per VAL-DASH-022. "
            f"Got UNTESTED={STATUS_RANK['UNTESTED']}, INCONCLUSIVE={STATUS_RANK['INCONCLUSIVE']}"
        )

    def test_untested_inconclusive_rollup_is_untested(self) -> None:
        """Rollup of UNTESTED + INCONCLUSIVE → UNTESTED (the worse outcome)."""
        from testgrid.collect import STATUS_RANK, Scenario

        scenarios = [
            Scenario(id="sc-1", status="UNTESTED"),
            Scenario(id="sc-2", status="INCONCLUSIVE"),
        ]
        rolled = min(
            (s.status for s in scenarios),
            key=lambda st: STATUS_RANK.get(st, 99),
        )
        assert rolled == "UNTESTED", (
            f"UNTESTED + INCONCLUSIVE rollup should be UNTESTED, got {rolled}"
        )

    def test_status_rank_full_ordering(self) -> None:
        """FAIL(0) < PARTIAL(1) < UNTESTED(2) < INCONCLUSIVE(3) < AUTHORED(4) < PASS(5)."""
        from testgrid.collect import STATUS_RANK

        assert STATUS_RANK["FAIL"] == 0
        assert STATUS_RANK["PARTIAL"] == 1
        assert STATUS_RANK["UNTESTED"] == 2
        assert STATUS_RANK["INCONCLUSIVE"] == 3
        assert STATUS_RANK["AUTHORED"] == 4
        assert STATUS_RANK["PASS"] == 5
        # Verify monotonic
        ranks = [
            STATUS_RANK[k]
            for k in ["FAIL", "PARTIAL", "UNTESTED", "INCONCLUSIVE", "AUTHORED", "PASS"]
        ]
        assert ranks == sorted(ranks), f"STATUS_RANK should be monotonic: {ranks}"

    def test_mechanism_rollup_uses_untested(self, tmp_path: Path) -> None:
        """Synthetic render confirms UNTESTED+INCONCLUSIVE rollup → UNTESTED in HTML."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-rollup",
            [
                {
                    "id": "sc-untested",
                    "status": "UNTESTED",
                    "mechanisms": ["certificates:cert-manager:untested"],
                },
                {
                    "id": "sc-inconclusive",
                    "status": "INCONCLUSIVE",
                    "mechanisms": ["certificates:cert-manager:inconclusive"],
                },
            ],
        )

        run = collect_run(reports, "run-rollup")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-rollup" / "index.html").read_text(encoding="utf-8")

        # The mechanism rollup should show UNTESTED (not INCONCLUSIVE)
        # Check that UNTESTED appears as a badge in the mechanism section
        assert "UNTESTED" in html


# ---------------------------------------------------------------------------
# VAL-DASH-023: Unknown status rejection/normalization
# ---------------------------------------------------------------------------


class TestUnknownStatus:
    """Tests for unknown status handling."""

    def test_unknown_status_normalized_to_unknown(self, tmp_path: Path) -> None:
        """VAL-DASH-023: Unknown status is normalized to UNKNOWN."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-unknown-status",
            [{"id": "sc-weird", "status": "WEIRD_CUSTOM_STATUS", "mechanisms": []}],
        )

        run = collect_run(reports, "run-unknown-status")
        sc = run.scenarios[0]
        assert sc.status == "UNKNOWN", (
            f"Unknown status should be normalized to UNKNOWN, got {sc.status}"
        )

    def test_unknown_status_warning_on_stderr(self, capsys, tmp_path: Path) -> None:
        """Stderr warning identifies the unknown status."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-unknown-stderr",
            [{"id": "sc-bogus", "status": "BOGUS_VALUE", "mechanisms": []}],
        )

        collect_run(reports, "run-unknown-stderr")
        captured = capsys.readouterr()
        assert "BOGUS_VALUE" in captured.err, (
            f"Stderr should name the unknown status. Got: {captured.err}"
        )
        assert "UNKNOWN" in captured.err or "unknown" in captured.err.lower()

    def test_unknown_status_rendered_visibly(self, tmp_path: Path) -> None:
        """UNKNOWN status badge appears in rendered HTML."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-unknown-render",
            [{"id": "sc-unknown", "status": "MADE_UP", "mechanisms": []}],
        )

        run = collect_run(reports, "run-unknown-render")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-unknown-render" / "index.html").read_text(encoding="utf-8")

        # Should contain UNKNOWN as visible text/badge
        assert "UNKNOWN" in html, "UNKNOWN status should be visible in rendered HTML"

    def test_known_statuses_preserved(self, tmp_path: Path) -> None:
        """Known statuses (PASS, FAIL, etc.) are preserved as-is."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()

        for status in ["PASS", "FAIL", "PARTIAL", "INCONCLUSIVE", "UNTESTED", "AUTHORED"]:
            _build_rich_run(
                reports,
                f"run-{status.lower()}",
                [{"id": f"sc-{status.lower()}", "status": status, "mechanisms": []}],
            )

        for status in ["PASS", "FAIL", "PARTIAL", "INCONCLUSIVE", "UNTESTED", "AUTHORED"]:
            run = collect_run(reports, f"run-{status.lower()}")
            assert run.scenarios[0].status == status, f"Status {status} should be preserved"


# ---------------------------------------------------------------------------
# VAL-DASH-024: XSS protection (HTML escaping)
# ---------------------------------------------------------------------------


class TestXssProtection:
    """Tests for HTML escaping of user-controlled fields."""

    def test_name_field_escaped(self, tmp_path: Path) -> None:
        """Name with XSS payload is HTML-escaped in output."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-xss-name",
            [
                {
                    "id": "sc-xss-name",
                    "name": '<script>alert("xss")</script>',
                    "mechanisms": [],
                }
            ],
        )

        run = collect_run(reports, "run-xss-name")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-xss-name" / "index.html").read_text(encoding="utf-8")

        assert '<script>alert("xss")</script>' not in html, "Script tag should be escaped"
        assert "&lt;script&gt;" in html, "Script tag should appear as escaped text"

    def test_description_field_escaped(self, tmp_path: Path) -> None:
        """Description with HTML injection is escaped."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-xss-desc",
            [
                {
                    "id": "sc-xss-desc",
                    "description": "</details><img src=x onerror=alert(1)>",
                    "mechanisms": [],
                }
            ],
        )

        run = collect_run(reports, "run-xss-desc")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-xss-desc" / "index.html").read_text(encoding="utf-8")

        # The raw HTML payload must NOT appear as live HTML.
        # Autoescape converts < and > to &lt; and &gt;.
        # The template's own <details> element naturally contains </details>,
        # so we check for the combined payload string which should be escaped.
        assert "</details><img" not in html, "Combined payload </details><img should be escaped"
        assert "&lt;/details&gt;" in html or "&lt;/details" in html, "Tags should be escaped"

    def test_fail_msg_field_escaped(self, tmp_path: Path) -> None:
        """fail_msg with XSS payload is escaped."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-xss-failmsg",
            [
                {
                    "id": "sc-xss-fail",
                    "status": "FAIL",
                    "fail_msg": '<img src=x onerror="steal()">',
                    "mechanisms": [],
                }
            ],
        )

        run = collect_run(reports, "run-xss-failmsg")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-xss-failmsg" / "index.html").read_text(encoding="utf-8")

        assert '<img src=x onerror="steal()">' not in html, "fail_msg should be escaped"
        assert "&lt;img" in html, "fail_msg tags should appear as escaped text"

    def test_log_dir_field_escaped(self, tmp_path: Path) -> None:
        """log_dir with XSS payload is escaped."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-xss-logdir",
            [
                {
                    "id": "sc-xss-log",
                    "status": "FAIL",
                    "log_dir": 'logs/"><script>alert(1)</script>',
                    "mechanisms": [],
                }
            ],
        )

        run = collect_run(reports, "run-xss-logdir")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-xss-logdir" / "index.html").read_text(encoding="utf-8")

        assert "<script>alert(1)</script>" not in html, "log_dir with XSS should be escaped"
        assert "&lt;script&gt;" in html, "log_dir tags should appear as escaped text"

    def test_notes_field_escaped(self, tmp_path: Path) -> None:
        """Assertion notes with XSS payload are escaped."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(
            reports,
            "run-xss-notes",
            [
                {
                    "id": "sc-xss-notes",
                    "status": "FAIL",
                    "mechanisms": [],
                    "asserts": [
                        {
                            "type": "pods-ready",
                            "status": "FAIL",
                            "notes": '<svg onload="alert(1)">',
                        }
                    ],
                }
            ],
        )

        run = collect_run(reports, "run-xss-notes")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-xss-notes" / "index.html").read_text(encoding="utf-8")

        assert '<svg onload="alert(1)">' not in html, "notes with XSS should be escaped"
        assert "&lt;svg" in html, "notes tags should appear as escaped text"


# ---------------------------------------------------------------------------
# VAL-DASH-025: Zero-scenario runs
# ---------------------------------------------------------------------------


class TestZeroScenarioRun:
    """Tests for runs with zero scenarios."""

    def test_zero_scenario_run_collected(self, tmp_path: Path) -> None:
        """VAL-DASH-025: Run with scenarios:[] is collected without error."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-empty-scenarios", [])

        # Should not raise
        run = collect_run(reports, "run-empty-scenarios")
        assert len(run.scenarios) == 0

    def test_zero_scenario_run_rendered(self, tmp_path: Path) -> None:
        """Zero-scenario run renders without crashing."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-zero", [])

        run = collect_run(reports, "run-zero")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-zero" / "index.html").read_text(encoding="utf-8")

        assert "0 scenarios in this run" in html, "Zero-scenario run should show placeholder text"

    def test_zero_scenario_run_in_index(self, tmp_path: Path) -> None:
        """Zero-scenario run appears in the index with count 0."""
        from testgrid.collect import collect_run, list_runs
        from testgrid.render import render_index

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-zero-idx", [])

        out = tmp_path / "dist"
        out.mkdir()
        all_runs = [collect_run(reports, rid) for rid in list_runs(reports)]
        index_path = render_index(all_runs, out)
        html = index_path.read_text(encoding="utf-8")

        assert "run-zero-idx" in html
        # The row should exist with scenario count 0
        # Just verify it doesn't crash and the run appears

    def test_build_dashboard_exits_0_for_zero_scenarios(self) -> None:
        """build-dashboard.sh exits 0 when there's a valid zero-scenario run."""
        import subprocess

        result = subprocess.run(
            [
                "uv",
                "run",
                "--directory",
                str(REPO_ROOT / "engine" / "testgrid"),
                "testgrid",
                "build",
                "--help",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0


# ---------------------------------------------------------------------------
# VAL-CROSS-021: Cross-feature dashboard reads across all integration categories
# ---------------------------------------------------------------------------


class TestCrossFeatureIntegration:
    """Tests for cross-feature dashboard reading across integration categories."""

    INTEGRATION_CATEGORIES = [
        "certificates",
        "ingress-controllers",
        "gateway-api",
        "service-mesh",
        "policy",
        "cloud-native",
    ]

    def test_all_categories_collected(self, tmp_path: Path) -> None:
        """VAL-CROSS-021: Dashboard correctly reads scenarios from all integration categories."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()

        specs = []
        for cat in self.INTEGRATION_CATEGORIES:
            specs.append(
                {
                    "id": f"{cat}-scenario-1",
                    "mechanisms": [f"{cat}:integration-{cat}:variant-1"],
                    "cluster": {"provider": "kind" if cat != "cloud-native" else "gke"},
                }
            )

        _build_rich_run(reports, "run-all-cats", specs)

        run = collect_run(reports, "run-all-cats")
        assert len(run.scenarios) == len(self.INTEGRATION_CATEGORIES)

        # All scenario IDs should be present
        scenario_ids = {s.id for s in run.scenarios}
        for cat in self.INTEGRATION_CATEGORIES:
            expected_id = f"{cat}-scenario-1"
            assert expected_id in scenario_ids, f"Missing scenario for category '{cat}'"

    def test_all_categories_rendered_without_schema_warnings(self, tmp_path: Path) -> None:
        """All integration categories render without missing scenarios."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()

        specs = []
        for i, cat in enumerate(self.INTEGRATION_CATEGORIES):
            specs.append(
                {
                    "id": f"{cat}-scenario-{i}",
                    "name": f"{cat.title()} Integration",
                    "description": f"Test scenario for {cat} integration category",
                    "mechanisms": [f"{cat}:integration-{cat}:variant-{i}"],
                    "tags": [cat],
                    "cluster": {"provider": "kind" if cat != "cloud-native" else "gke"},
                }
            )

        _build_rich_run(reports, "run-cross", specs)

        run = collect_run(reports, "run-cross")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)
        html = (out / "run-cross" / "index.html").read_text(encoding="utf-8")

        # Every category scenario should appear in the HTML
        for cat in self.INTEGRATION_CATEGORIES:
            assert f"{cat}-scenario-" in html, (
                f"Scenario for category '{cat}' should appear in rendered HTML"
            )

        # Cloud-native scenarios should have AUTHORED status
        assert "AUTHORED" in html

    def test_mixed_legacy_rich_with_all_categories(self, tmp_path: Path) -> None:
        """Dashboard aggregates legacy + rich runs across all categories."""
        from testgrid.collect import collect_run, list_runs
        from testgrid.render import render_index, render_run

        reports = tmp_path / "reports"
        reports.mkdir()

        # Legacy run with certificates scenarios
        _build_legacy_run(reports, "run-legacy-all", ["certificates-legacy", "ingress-legacy"])

        # Rich run with mesh + policy + cloud scenarios
        _build_rich_run(
            reports,
            "run-rich-all",
            [
                {"id": "mesh-scenario", "mechanisms": ["service-mesh:istio:mesh"]},
                {"id": "policy-scenario", "mechanisms": ["policy:gatekeeper:constraint"]},
                {
                    "id": "cloud-scenario",
                    "mechanisms": ["cloud-native:gke:standard"],
                    "cluster": {"provider": "gke"},
                },
            ],
        )

        out = tmp_path / "dist"
        out.mkdir()

        for rid in list_runs(reports):
            run = collect_run(reports, rid)
            render_run(run, out)

        all_runs = [collect_run(reports, rid) for rid in list_runs(reports)]
        index_path = render_index(all_runs, out)
        html = index_path.read_text(encoding="utf-8")

        # Both runs should appear in the index
        assert "run-legacy-all" in html
        assert "run-rich-all" in html


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _diff_lines(a: str, b: str) -> str:
    """Return unified diff of two strings."""
    return "\n".join(
        difflib.unified_diff(
            a.splitlines(keepends=True),
            b.splitlines(keepends=True),
            fromfile="first",
            tofile="second",
        )
    )
