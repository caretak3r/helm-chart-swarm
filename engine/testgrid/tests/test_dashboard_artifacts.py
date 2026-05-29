"""Tests for F2.1 — per-scenario artifact links in the dashboard.

Validates:
  - VAL-DASH-001: Scenario card exposes "Scenario YAML" link
  - VAL-DASH-002: Scenario card exposes "Applied Overrides" link
  - VAL-DASH-003: Every fixture file listed as a link
  - VAL-DASH-004: Every manifest file listed as a link; empty manifests/ has placeholder
  - VAL-DASH-005: Every artifact link href resolves to an existing file on disk
  - VAL-DASH-006: Legacy runs without artifacts/ omit artifact link sections
"""

from __future__ import annotations

import os
from pathlib import Path

import yaml

# repo root: engine/testgrid/tests/ -> engine/testgrid/ -> engine/ -> chart-test-swarm/
REPO_ROOT = Path(__file__).resolve().parents[3]
TESTGRID_DIR = REPO_ROOT / "engine" / "testgrid"


# ---------------------------------------------------------------------------
# Helpers — build synthetic report directories
# ---------------------------------------------------------------------------


def _write_yaml(path: Path, data: object) -> None:
    path.write_text(yaml.dump(data), encoding="utf-8")


def _make_artifacts_dir(
    agent_dir: Path, *, with_fixtures: bool = True, with_manifests: bool = True
) -> Path:
    """Create a synthetic artifacts/ bundle inside *agent_dir*."""
    art = agent_dir / "artifacts"
    art.mkdir(parents=True, exist_ok=True)
    (art / "scenario.yaml").write_text("id: test-scenario\n", encoding="utf-8")
    (art / "applied-overrides.yaml").write_text("{}\n", encoding="utf-8")
    if with_fixtures:
        fxt = art / "fixtures"
        fxt.mkdir()
        (fxt / "tls.crt").write_text("FAKE CERT\n", encoding="utf-8")
        (fxt / "tls.key").write_text("FAKE KEY\n", encoding="utf-8")
    if with_manifests:
        mf = art / "manifests"
        mf.mkdir()
        (mf / "deployment.yaml").write_text("kind: Deployment\n", encoding="utf-8")
        (mf / "service.yaml").write_text("kind: Service\n", encoding="utf-8")
    return art


def _build_rich_run(reports_dir: Path, run_id: str, scenario_ids: list[str]) -> Path:
    """Create a synthetic run-<run_id> with a snapshot, run-meta, and agent-1
    results including a full artifacts/ bundle."""
    run_dir = reports_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    _write_yaml(
        run_dir / "run-meta.yaml",
        {
            "run_id": run_id,
            "timestamp_utc": "2026-05-20T10:15:00Z",
            "num_agents": 1,
            "suite": "full",
        },
    )

    # Snapshot
    _write_yaml(
        run_dir / "scenarios-snapshot.yaml",
        {
            "scenarios": [
                {
                    "id": sid,
                    "name": f"Scenario {sid}",
                    "description": f"Description of {sid}",
                    "cluster": {"provider": "kind"},
                    "mechanisms": ["certificates:cert-manager"],
                    "tags": ["tls"],
                }
                for sid in scenario_ids
            ],
        },
    )

    # Agent-1 results
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
                    "duration_s": 42,
                    "asserts": [{"type": "pods-ready", "status": "PASS", "notes": "ok"}],
                }
                for sid in scenario_ids
            ],
        },
    )

    # Artifacts bundle
    _make_artifacts_dir(agent_dir)

    return run_dir


def _build_legacy_run(reports_dir: Path, run_id: str, scenario_ids: list[str]) -> Path:
    """Create a synthetic legacy run (no artifacts/ directory)."""
    run_dir = reports_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    _write_yaml(
        run_dir / "run-meta.yaml",
        {
            "run_id": run_id,
            "timestamp_utc": "2026-05-19T09:00:00Z",
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
# Tests — collect artifacts
# ---------------------------------------------------------------------------


class TestArtifactCollection:
    """Unit tests for artifact link collection in collect.py."""

    def test_artifact_links_populated_from_run_dir(self, tmp_path: Path) -> None:
        """Given a run with artifacts/, collect populates artifact_links."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-test-001", ["sc-a"])

        run = collect_run(reports, "run-test-001")
        assert len(run.scenarios) >= 1
        sc = run.scenarios[0]
        assert sc.artifact_links, "artifact_links should not be empty"
        assert "scenario" in sc.artifact_links
        assert sc.artifact_links["scenario"].endswith("artifacts/scenario.yaml")
        assert os.path.isfile(sc.artifact_links["scenario"])

    def test_artifact_links_includes_overrides(self, tmp_path: Path) -> None:
        """artifact_links includes applied-overrides.yaml."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-test-002", ["sc-b"])

        run = collect_run(reports, "run-test-002")
        sc = run.scenarios[0]
        assert "overrides" in sc.artifact_links
        assert sc.artifact_links["overrides"].endswith("artifacts/applied-overrides.yaml")
        assert os.path.isfile(sc.artifact_links["overrides"])

    def test_artifact_links_includes_fixtures(self, tmp_path: Path) -> None:
        """artifact_links includes every fixture file."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-test-003", ["sc-c"])

        run = collect_run(reports, "run-test-003")
        sc = run.scenarios[0]
        assert "fixtures" in sc.artifact_links
        fixtures = sc.artifact_links["fixtures"]
        assert isinstance(fixtures, list)
        fixture_names = [os.path.basename(f) for f in fixtures]
        assert "tls.crt" in fixture_names
        assert "tls.key" in fixture_names

    def test_artifact_links_includes_manifests(self, tmp_path: Path) -> None:
        """artifact_links includes every manifest file."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-test-004", ["sc-d"])

        run = collect_run(reports, "run-test-004")
        sc = run.scenarios[0]
        assert "manifests" in sc.artifact_links
        manifests = sc.artifact_links["manifests"]
        assert isinstance(manifests, list)
        manifest_names = [os.path.basename(f) for f in manifests]
        assert "deployment.yaml" in manifest_names
        assert "service.yaml" in manifest_names

    def test_artifact_links_empty_for_legacy_run(self, tmp_path: Path) -> None:
        """Legacy runs without artifacts/ have empty artifact_links."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_legacy_run(reports, "run-legacy-001", ["sc-legacy"])

        run = collect_run(reports, "run-legacy-001")
        sc = run.scenarios[0]
        assert sc.artifact_links == {} or sc.artifact_links is None, (
            "Legacy runs should have empty artifact_links"
        )

    def test_artifact_links_empty_manifests_shows_placeholder(self, tmp_path: Path) -> None:
        """When manifests/ dir exists but is empty, manifests key is present but empty list."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        run_id = "run-test-empty-manifests"
        run_dir = reports / run_id
        run_dir.mkdir(parents=True)

        _write_yaml(run_dir / "run-meta.yaml", {"run_id": run_id})
        _write_yaml(
            run_dir / "scenarios-snapshot.yaml",
            {
                "scenarios": [
                    {
                        "id": "sc-empty",
                        "cluster": {"provider": "kind"},
                        "mechanisms": [],
                        "tags": [],
                    }
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
                    {"scenario_id": "sc-empty", "status": "PASS", "duration_s": 10, "asserts": []}
                ],
            },
        )

        # Create artifacts with empty manifests dir
        art = _make_artifacts_dir(agent_dir, with_manifests=False)
        empty_mf = art / "manifests"
        empty_mf.mkdir(exist_ok=True)  # exists but empty

        run = collect_run(reports, run_id)
        sc = run.scenarios[0]
        assert "manifests" in sc.artifact_links
        assert sc.artifact_links["manifests"] == [], "Empty manifests dir should yield empty list"


# ---------------------------------------------------------------------------
# Tests — render artifacts
# ---------------------------------------------------------------------------


class TestArtifactRender:
    """Integration tests for artifact link rendering in the dashboard HTML."""

    def test_render_includes_scenario_yaml_anchor(self, tmp_path: Path) -> None:
        """Rendered HTML contains a 'Scenario YAML' anchor whose href ends
        with artifacts/scenario.yaml (VAL-DASH-001)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-render-001", ["sc-x"])

        run = collect_run(reports, "run-render-001")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-render-001" / "index.html").read_text(encoding="utf-8")
        assert "artifacts/scenario.yaml" in html
        assert "Scenario YAML" in html or "scenario.yaml" in html

    def test_render_includes_applied_overrides_anchor(self, tmp_path: Path) -> None:
        """Rendered HTML contains an 'Applied Overrides' anchor (VAL-DASH-002)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-render-002", ["sc-y"])

        run = collect_run(reports, "run-render-002")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-render-002" / "index.html").read_text(encoding="utf-8")
        assert "artifacts/applied-overrides.yaml" in html
        assert "Applied Overrides" in html

    def test_render_includes_fixture_links(self, tmp_path: Path) -> None:
        """Rendered HTML lists every fixture file (VAL-DASH-003)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-render-003", ["sc-z"])

        run = collect_run(reports, "run-render-003")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-render-003" / "index.html").read_text(encoding="utf-8")
        assert "tls.crt" in html
        assert "tls.key" in html

    def test_render_includes_manifest_links(self, tmp_path: Path) -> None:
        """Rendered HTML lists every manifest file (VAL-DASH-004)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-render-004", ["sc-m"])

        run = collect_run(reports, "run-render-004")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-render-004" / "index.html").read_text(encoding="utf-8")
        assert "deployment.yaml" in html
        assert "service.yaml" in html

    def test_render_legacy_no_artifacts_section(self, tmp_path: Path) -> None:
        """Legacy runs without artifacts/ omit the artifact section entirely
        and have no dead links (VAL-DASH-006)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_legacy_run(reports, "run-legacy-render", ["sc-leg"])

        run = collect_run(reports, "run-legacy-render")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-legacy-render" / "index.html").read_text(encoding="utf-8")
        # Should not contain artifact links from a legacy run
        assert "artifacts/scenario.yaml" not in html, "Legacy runs should not render artifact links"

    def test_all_artifact_hrefs_resolve(self, tmp_path: Path) -> None:
        """Every artifact link href resolves to an existing file (VAL-DASH-005)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-resolve", ["sc-resolve"])

        run = collect_run(reports, "run-resolve")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        # Walk the scenario's artifact_links and verify each file exists
        sc = run.scenarios[0]
        for key, value in sc.artifact_links.items():
            if isinstance(value, list):
                for path in value:
                    assert os.path.isfile(path), f"Artifact {key} file missing: {path}"
            elif isinstance(value, str):
                assert os.path.isfile(value), f"Artifact {key} file missing: {value}"

    def test_render_empty_manifests_placeholder(self, tmp_path: Path) -> None:
        """Empty manifests/ renders a placeholder in the HTML (VAL-DASH-004)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        run_id = "run-empty-mf-render"
        run_dir = reports / run_id
        run_dir.mkdir(parents=True)

        _write_yaml(run_dir / "run-meta.yaml", {"run_id": run_id})
        _write_yaml(
            run_dir / "scenarios-snapshot.yaml",
            {
                "scenarios": [
                    {
                        "id": "sc-empty-mf",
                        "cluster": {"provider": "kind"},
                        "mechanisms": [],
                        "tags": [],
                    }
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
                        "scenario_id": "sc-empty-mf",
                        "status": "PASS",
                        "duration_s": 10,
                        "asserts": [],
                    }
                ],
            },
        )

        art = _make_artifacts_dir(agent_dir, with_manifests=False)
        (art / "manifests").mkdir(exist_ok=True)

        run = collect_run(reports, run_id)
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / run_id / "index.html").read_text(encoding="utf-8")
        # Empty manifests should still show the section header but indicate empty
        assert "manifests" in html.lower()
        assert "empty" in html.lower() or "none" in html.lower() or "no manifest" in html.lower(), (
            "Empty manifests should have a visible placeholder, not silent omission"
        )

    def test_fixtures_none_omitted(self, tmp_path: Path) -> None:
        """Every fixture file in the artifacts/fixtures/ dir appears in the HTML."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-fxt-all", ["sc-fxt"])

        run = collect_run(reports, "run-fxt-all")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-fxt-all" / "index.html").read_text(encoding="utf-8")
        # Both fixture files must appear
        assert "tls.crt" in html
        assert "tls.key" in html


# ---------------------------------------------------------------------------
# Tests — multi-run aggregation
# ---------------------------------------------------------------------------


class TestMultiRunArtifacts:
    """Tests for multiple runs with mixed artifact presence."""

    def test_mixed_rich_and_legacy_runs(self, tmp_path: Path) -> None:
        """Building dashboard against mixed rich + legacy runs succeeds."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-rich", ["sc-1"])
        _build_legacy_run(reports, "run-legacy", ["sc-2"])

        run_rich = collect_run(reports, "run-rich")
        run_legacy = collect_run(reports, "run-legacy")

        assert run_rich.scenarios[0].artifact_links, "Rich run should have artifact links"
        assert not run_legacy.scenarios[0].artifact_links, (
            "Legacy run should have no artifact links"
        )

    def test_render_mixed_runs_no_crash(self, tmp_path: Path) -> None:
        """Rendering mixed rich + legacy runs does not crash."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-rich-2", ["sc-a"])
        _build_legacy_run(reports, "run-legacy-2", ["sc-b"])

        out = tmp_path / "dist"
        out.mkdir()

        for rid in ["run-rich-2", "run-legacy-2"]:
            run = collect_run(reports, rid)
            render_run(run, out)
            assert (out / rid / "index.html").exists()


# ---------------------------------------------------------------------------
# Tests — scenario without agent (UNTESTED)
# ---------------------------------------------------------------------------


class TestArtifactEdgeCases:
    """Edge cases for artifact link collection."""

    def test_untested_scenario_no_artifacts(self, tmp_path: Path) -> None:
        """Scenario with no agent result (UNTESTED) has empty artifact_links."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        run_id = "run-untested"
        run_dir = reports / run_id
        run_dir.mkdir()

        _write_yaml(run_dir / "run-meta.yaml", {"run_id": run_id})
        _write_yaml(
            run_dir / "scenarios-snapshot.yaml",
            {
                "scenarios": [
                    {
                        "id": "sc-untested",
                        "cluster": {"provider": "kind"},
                        "mechanisms": [],
                        "tags": [],
                    },
                ],
            },
        )
        # No agent results — scenario stays UNTESTED

        run = collect_run(reports, run_id)
        sc = run.scenarios[0]
        assert sc.status == "UNTESTED"
        assert not sc.artifact_links, "UNTESTED scenarios should have no artifact links"

    def test_orphan_result_has_artifacts(self, tmp_path: Path) -> None:
        """Orphan result (no snapshot entry) still gets artifact links from its agent dir."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        run_id = "run-orphan"
        run_dir = reports / run_id
        run_dir.mkdir()

        _write_yaml(run_dir / "run-meta.yaml", {"run_id": run_id})
        _write_yaml(
            run_dir / "scenarios-snapshot.yaml",
            {
                "scenarios": [],
            },
        )

        agent_dir = run_dir / "agent-1"
        agent_dir.mkdir()
        _write_yaml(
            agent_dir / "result.yaml",
            {
                "agent": 1,
                "results": [
                    {"scenario_id": "orphan-1", "status": "PASS", "duration_s": 5, "asserts": []}
                ],
            },
        )
        _make_artifacts_dir(agent_dir)

        run = collect_run(reports, run_id)
        assert len(run.scenarios) == 1
        sc = run.scenarios[0]
        assert sc.id == "orphan-1"
        assert sc.artifact_links, "Orphan scenario should still get artifact links"
        assert "scenario" in sc.artifact_links

    def test_multi_agent_run_artifacts_per_agent(self, tmp_path: Path) -> None:
        """Run with multiple agents: each scenario gets artifacts from its agent dir."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        run_id = "run-multi-agent"
        run_dir = reports / run_id
        run_dir.mkdir()

        _write_yaml(run_dir / "run-meta.yaml", {"run_id": run_id, "num_agents": 2})
        _write_yaml(
            run_dir / "scenarios-snapshot.yaml",
            {
                "scenarios": [
                    {"id": "sc-1", "cluster": {"provider": "kind"}, "mechanisms": [], "tags": []},
                    {"id": "sc-2", "cluster": {"provider": "kind"}, "mechanisms": [], "tags": []},
                ],
            },
        )

        # Agent 1
        a1 = run_dir / "agent-1"
        a1.mkdir()
        _write_yaml(
            a1 / "result.yaml",
            {
                "agent": 1,
                "results": [
                    {"scenario_id": "sc-1", "status": "PASS", "duration_s": 10, "asserts": []}
                ],
            },
        )
        _make_artifacts_dir(a1)

        # Agent 2
        a2 = run_dir / "agent-2"
        a2.mkdir()
        _write_yaml(
            a2 / "result.yaml",
            {
                "agent": 2,
                "results": [
                    {"scenario_id": "sc-2", "status": "PASS", "duration_s": 20, "asserts": []}
                ],
            },
        )
        _make_artifacts_dir(a2)

        run = collect_run(reports, run_id)
        by_id = {s.id: s for s in run.scenarios}

        sc1 = by_id["sc-1"]
        sc2 = by_id["sc-2"]

        assert sc1.artifact_links.get("scenario", "").find("agent-1") != -1, (
            "sc-1 should reference agent-1 artifacts"
        )
        assert sc2.artifact_links.get("scenario", "").find("agent-2") != -1, (
            "sc-2 should reference agent-2 artifacts"
        )
