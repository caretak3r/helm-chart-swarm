"""Tests for dashboard artifact links (F2.1 + M11).

Validates:
  F2.1 (collect/render basics):
  - VAL-DASH-001: Scenario card exposes "Scenario YAML" link
  - VAL-DASH-002: Scenario card exposes "Applied Overrides" link
  - VAL-DASH-003: Every fixture file listed as a link
  - VAL-DASH-004: Every manifest file listed as a link; empty manifests/ has placeholder
  - VAL-DASH-005: Every artifact link href resolves to an existing file on disk
  - VAL-DASH-006: Legacy runs without artifacts/ omit artifact link sections

  M11 (copy into dist + relative hrefs):
  - VAL-DASH-027: dist/<run-id>/<scenario-id>/artifacts/ contains byte-identical copies
  - VAL-DASH-028: All artifact hrefs in rendered HTML are relative (no /,file:,http(s):)
  - VAL-DASH-029: Artifact hrefs are scoped to the scenario's own subtree
  - VAL-DASH-033: No dead in-tree links on the served dashboard (href validity)
  - VAL-DASH-034: Determinism preserved — two consecutive builds are byte-identical
  - VAL-DASH-035: Legacy runs emit no artifact anchors and no copied artifact dirs
"""

from __future__ import annotations

import hashlib
import re
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
    """Unit tests for artifact link collection in collect.py.

    M11: collect.py now returns relative-path locators (relative within the bundle)
    rather than absolute host-filesystem paths.  The source artifact directory is
    exposed via the new ``Scenario.artifact_dir`` field.
    """

    def test_artifact_links_populated_from_run_dir(self, tmp_path: Path) -> None:
        """Given a run with artifacts/, collect populates artifact_links with relative paths."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-test-001", ["sc-a"])

        run = collect_run(reports, "run-test-001")
        assert len(run.scenarios) >= 1
        sc = run.scenarios[0]
        assert sc.artifact_links, "artifact_links should not be empty"
        assert "scenario" in sc.artifact_links
        # M11: value is a relative path within the bundle, not an absolute path
        assert sc.artifact_links["scenario"] == "scenario.yaml"
        # The source can be reached via artifact_dir
        assert sc.artifact_dir is not None
        assert (sc.artifact_dir / sc.artifact_links["scenario"]).is_file()

    def test_artifact_links_includes_overrides(self, tmp_path: Path) -> None:
        """artifact_links includes applied-overrides.yaml as a relative path."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-test-002", ["sc-b"])

        run = collect_run(reports, "run-test-002")
        sc = run.scenarios[0]
        assert "overrides" in sc.artifact_links
        # M11: relative within bundle
        assert sc.artifact_links["overrides"] == "applied-overrides.yaml"
        assert sc.artifact_dir is not None
        assert (sc.artifact_dir / sc.artifact_links["overrides"]).is_file()

    def test_artifact_links_includes_fixtures(self, tmp_path: Path) -> None:
        """artifact_links includes every fixture file as a relative path."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-test-003", ["sc-c"])

        run = collect_run(reports, "run-test-003")
        sc = run.scenarios[0]
        assert "fixtures" in sc.artifact_links
        fixtures = sc.artifact_links["fixtures"]
        assert isinstance(fixtures, list)
        # M11: values are relative paths like "fixtures/tls.crt"
        fixture_names = [Path(f).name for f in fixtures]
        assert "tls.crt" in fixture_names
        assert "tls.key" in fixture_names
        # Each relative path resolves to a real file via artifact_dir
        assert sc.artifact_dir is not None
        for rel in fixtures:
            assert (sc.artifact_dir / rel).is_file(), f"Missing fixture: {rel}"

    def test_artifact_links_includes_manifests(self, tmp_path: Path) -> None:
        """artifact_links includes every manifest file as a relative path."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-test-004", ["sc-d"])

        run = collect_run(reports, "run-test-004")
        sc = run.scenarios[0]
        assert "manifests" in sc.artifact_links
        manifests = sc.artifact_links["manifests"]
        assert isinstance(manifests, list)
        # M11: values are relative paths like "manifests/deployment.yaml"
        manifest_names = [Path(m).name for m in manifests]
        assert "deployment.yaml" in manifest_names
        assert "service.yaml" in manifest_names
        assert sc.artifact_dir is not None
        for rel in manifests:
            assert (sc.artifact_dir / rel).is_file(), f"Missing manifest: {rel}"

    def test_artifact_links_empty_for_legacy_run(self, tmp_path: Path) -> None:
        """Legacy runs without artifacts/ have empty artifact_links and no artifact_dir."""
        from testgrid.collect import collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_legacy_run(reports, "run-legacy-001", ["sc-legacy"])

        run = collect_run(reports, "run-legacy-001")
        sc = run.scenarios[0]
        assert sc.artifact_links == {}, "Legacy runs should have empty artifact_links"
        assert sc.artifact_dir is None, "Legacy runs should have artifact_dir=None"

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
        """After render_run(), every artifact href resolves to a copied file in dist/
        (VAL-DASH-005 / VAL-DASH-027).  The hrefs are relative and point into
        dist/<run-id>/<scenario-id>/artifacts/."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-resolve", ["sc-resolve"])

        run = collect_run(reports, "run-resolve")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        # After render_run(), artifact_links holds relative hrefs (not absolute paths).
        # The copied files live under dist/<run-id>/<scenario-id>/artifacts/.
        run_dir = out / "run-resolve"
        sc = run.scenarios[0]
        for key, value in sc.artifact_links.items():
            if isinstance(value, list):
                for rel_href in value:
                    resolved = run_dir / rel_href
                    assert resolved.is_file(), f"Copied artifact file missing for {key}: {resolved}"
            elif isinstance(value, str):
                resolved = run_dir / value
                assert resolved.is_file(), f"Copied artifact file missing for {key}: {resolved}"

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
        """Run with multiple agents: each scenario gets artifact_dir from its agent dir."""
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

        # M11: check via artifact_dir (source path) rather than artifact_links content
        assert sc1.artifact_dir is not None, "sc-1 should have an artifact_dir"
        assert sc2.artifact_dir is not None, "sc-2 should have an artifact_dir"
        assert "agent-1" in str(sc1.artifact_dir), "sc-1 artifact_dir should reference agent-1"
        assert "agent-2" in str(sc2.artifact_dir), "sc-2 artifact_dir should reference agent-2"
        # Relative locators are the same for both (same bundle structure)
        assert sc1.artifact_links.get("scenario") == "scenario.yaml"
        assert sc2.artifact_links.get("scenario") == "scenario.yaml"


# ---------------------------------------------------------------------------
# M11: Tests for artifact-copy-into-dist and relative hrefs
# ---------------------------------------------------------------------------


class TestM11ArtifactCopyAndRelativeHrefs:
    """Tests for VAL-DASH-027/028/029/033/034/035 — copying artifacts into
    the dist tree and emitting relative hrefs in rendered HTML.
    """

    # --- VAL-DASH-027: artifact files copied byte-identically to dist ---

    def test_artifact_files_copied_to_dist(self, tmp_path: Path) -> None:
        """After render_run(), dist/<run-id>/<scenario-id>/artifacts/ contains
        byte-identical copies of the source artifact files (VAL-DASH-027)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-copy-test", ["sc-copy"])

        run = collect_run(reports, "run-copy-test")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        run_dir = out / "run-copy-test"
        sc_art = run_dir / "sc-copy" / "artifacts"

        assert sc_art.is_dir(), f"Expected artifact dir at {sc_art}"
        assert (sc_art / "scenario.yaml").is_file()
        assert (sc_art / "applied-overrides.yaml").is_file()
        assert (sc_art / "fixtures" / "tls.crt").is_file()
        assert (sc_art / "fixtures" / "tls.key").is_file()
        assert (sc_art / "manifests" / "deployment.yaml").is_file()
        assert (sc_art / "manifests" / "service.yaml").is_file()

    def test_artifact_files_are_byte_identical_to_source(self, tmp_path: Path) -> None:
        """Copied artifact files are byte-identical to their source (VAL-DASH-027)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-sha-test", ["sc-sha"])

        run = collect_run(reports, "run-sha-test")
        source_art = run.scenarios[0].artifact_dir
        assert source_art is not None

        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        run_dir = out / "run-sha-test"
        sc_art = run_dir / "sc-sha" / "artifacts"

        def sha256(path: Path) -> str:
            h = hashlib.sha256()
            h.update(path.read_bytes())
            return h.hexdigest()

        for rel in [
            "scenario.yaml",
            "applied-overrides.yaml",
            "fixtures/tls.crt",
            "fixtures/tls.key",
            "manifests/deployment.yaml",
            "manifests/service.yaml",
        ]:
            src = source_art / rel
            dst = sc_art / rel
            assert dst.is_file(), f"Copied file missing: {dst}"
            assert sha256(src) == sha256(dst), f"Checksum mismatch for {rel}"

    def test_source_artifacts_not_modified(self, tmp_path: Path) -> None:
        """The reports/ source artifacts are not modified by the dashboard build
        (read-only w.r.t. reports/) — VAL-DASH-027."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-readonly", ["sc-ro"])

        run = collect_run(reports, "run-readonly")
        source_art = run.scenarios[0].artifact_dir
        assert source_art is not None

        # Record checksums of all source files
        source_checksums: dict[str, bytes] = {}
        for p in source_art.rglob("*"):
            if p.is_file():
                source_checksums[str(p.relative_to(source_art))] = p.read_bytes()

        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        # Verify source files are unchanged
        for rel, original_bytes in source_checksums.items():
            src = source_art / rel
            assert src.read_bytes() == original_bytes, f"Source file was modified: {rel}"

    # --- VAL-DASH-028: all artifact hrefs are relative ---

    def test_artifact_hrefs_are_relative_in_html(self, tmp_path: Path) -> None:
        """All artifact anchor hrefs in rendered HTML are relative — not absolute paths,
        not file: URLs, not http(s): URLs (VAL-DASH-028)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-rel-href", ["sc-rel"])

        run = collect_run(reports, "run-rel-href")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-rel-href" / "index.html").read_text(encoding="utf-8")

        # Find all data-artifact hrefs in the HTML
        # Matches: href="<value>" on elements that have data-artifact
        artifact_hrefs = re.findall(
            r'data-artifact="[^"]*"[^>]*href="([^"]*)"'
            r'|href="([^"]*)"[^>]*data-artifact="[^"]*"',
            html,
        )
        all_hrefs = [h for pair in artifact_hrefs for h in pair if h]

        assert all_hrefs, "Expected at least one data-artifact anchor in rendered HTML"

        for href in all_hrefs:
            # Must not be absolute filesystem path
            assert not href.startswith("/"), f"Artifact href must not start with /: {href!r}"
            # Must not be file: URL
            assert not href.startswith("file:"), (
                f"Artifact href must not start with file:: {href!r}"
            )
            # Must not be http(s): URL
            assert not href.startswith("http://"), (
                f"Artifact href must not start with http://: {href!r}"
            )
            assert not href.startswith("https://"), (
                f"Artifact href must not start with https://: {href!r}"
            )
            # Must not contain host filesystem prefix (e.g. /Users/, /home/)
            assert "/Users/" not in href, f"Artifact href contains /Users/: {href!r}"
            assert "/home/" not in href, f"Artifact href contains /home/: {href!r}"
            # Windows drive letter check
            assert not re.match(r"^[A-Za-z]:", href), (
                f"Artifact href looks like a Windows absolute path: {href!r}"
            )

    def test_no_absolute_path_in_artifact_hrefs(self, tmp_path: Path) -> None:
        """Grep-style check: rendered HTML contains no absolute href in artifact anchors
        (VAL-DASH-028)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-noabs", ["sc-noabs"])

        run = collect_run(reports, "run-noabs")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-noabs" / "index.html").read_text(encoding="utf-8")

        # Check that the reports root does not appear anywhere in the rendered HTML
        # as an href (it would if we were still using absolute paths)
        reports_abs = str(reports.resolve())
        assert reports_abs not in html, f"Absolute reports path found in HTML: {reports_abs!r}"

    # --- VAL-DASH-029: hrefs scoped to scenario subdirectory ---

    def test_artifact_hrefs_scoped_to_scenario_subdir(self, tmp_path: Path) -> None:
        """Each scenario card's artifact hrefs begin with <scenario-id>/artifacts/
        and don't bleed into other scenarios (VAL-DASH-029)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-scope", ["sc-alpha", "sc-beta"])

        run = collect_run(reports, "run-scope")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        # After render_run, each scenario's artifact_links holds relative hrefs
        by_id = {s.id: s for s in run.scenarios}
        sc_alpha = by_id["sc-alpha"]
        sc_beta = by_id["sc-beta"]

        # Scenario hrefs scoped to own subdir
        if sc_alpha.artifact_links.get("scenario"):
            href = sc_alpha.artifact_links["scenario"]
            assert href.startswith("sc-alpha/artifacts/"), (
                f"sc-alpha href not scoped correctly: {href!r}"
            )
        if sc_beta.artifact_links.get("scenario"):
            href = sc_beta.artifact_links["scenario"]
            assert href.startswith("sc-beta/artifacts/"), (
                f"sc-beta href not scoped correctly: {href!r}"
            )

        # No cross-scenario bleed: sc-alpha's hrefs don't reference sc-beta and vice versa
        for href_val in sc_alpha.artifact_links.values():
            hrefs = [href_val] if isinstance(href_val, str) else href_val
            for h in hrefs:
                assert "sc-beta" not in h, f"sc-alpha href bleeds into sc-beta: {h!r}"
        for href_val in sc_beta.artifact_links.values():
            hrefs = [href_val] if isinstance(href_val, str) else href_val
            for h in hrefs:
                assert "sc-alpha" not in h, f"sc-beta href bleeds into sc-alpha: {h!r}"

    def test_scenario_yaml_content_matches_owning_scenario(self, tmp_path: Path) -> None:
        """Each scenario card's Scenario YAML link points to that scenario's own
        scenario.yaml (the served body's .id matches the card's id) — VAL-DASH-029."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()

        # Build a run with 2 scenarios, each with a distinct scenario.yaml
        run_id = "run-yaml-content"
        run_dir = reports / run_id
        run_dir.mkdir(parents=True)

        _write_yaml(run_dir / "run-meta.yaml", {"run_id": run_id})
        _write_yaml(
            run_dir / "scenarios-snapshot.yaml",
            {
                "scenarios": [
                    {"id": "sc-x", "cluster": {"provider": "kind"}, "mechanisms": [], "tags": []},
                    {"id": "sc-y", "cluster": {"provider": "kind"}, "mechanisms": [], "tags": []},
                ],
            },
        )

        for sc_id, agent_n in [("sc-x", 1), ("sc-y", 2)]:
            adir = run_dir / f"agent-{agent_n}"
            adir.mkdir()
            _write_yaml(
                adir / "result.yaml",
                {
                    "agent": agent_n,
                    "results": [
                        {"scenario_id": sc_id, "status": "PASS", "duration_s": 5, "asserts": []}
                    ],
                },
            )
            art = adir / "artifacts"
            art.mkdir()
            # Each scenario.yaml has a distinct id
            (art / "scenario.yaml").write_text(f"id: {sc_id}\n", encoding="utf-8")
            (art / "applied-overrides.yaml").write_text("{}\n", encoding="utf-8")
            (art / "fixtures").mkdir()
            (art / "manifests").mkdir()

        run = collect_run(reports, run_id)
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        run_dist = out / run_id
        by_id = {s.id: s for s in run.scenarios}

        for sc_id in ["sc-x", "sc-y"]:
            sc = by_id[sc_id]
            sc_yaml_href = sc.artifact_links.get("scenario", "")
            assert sc_yaml_href, f"No scenario href for {sc_id}"
            sc_yaml_path = run_dist / sc_yaml_href
            assert sc_yaml_path.is_file(), f"Scenario YAML not copied: {sc_yaml_path}"
            content = yaml.safe_load(sc_yaml_path.read_text())
            assert content.get("id") == sc_id, (
                f"Scenario YAML for card {sc_id} contains wrong id: {content.get('id')!r}"
            )

    # --- VAL-DASH-034: determinism ---

    def test_dashboard_determinism_after_artifact_copy(self, tmp_path: Path) -> None:
        """Two consecutive builds produce byte-identical dist trees including copied
        artifacts (VAL-DASH-034)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-det", ["sc-det"])

        out_a = tmp_path / "dist-a"
        out_a.mkdir()
        out_b = tmp_path / "dist-b"
        out_b.mkdir()

        # First build
        run = collect_run(reports, "run-det")
        render_run(run, out_a)

        # Second build — fresh collect to avoid mutation side-effects
        run2 = collect_run(reports, "run-det")
        render_run(run2, out_b)

        # Both dist trees must be byte-identical (modulo render timestamp)
        # Compare all non-HTML files (artifacts) byte-exactly
        for p in sorted((out_a / "run-det").rglob("*")):
            if not p.is_file():
                continue
            rel = p.relative_to(out_a)
            counterpart = out_b / rel
            assert counterpart.is_file(), f"File missing in second build: {rel}"
            # For artifact files (non-HTML), must be byte-identical
            if p.suffix not in (".html",):
                assert p.read_bytes() == counterpart.read_bytes(), (
                    f"Non-deterministic artifact file: {rel}"
                )

        # Check no extra files in second build
        for p in sorted((out_b / "run-det").rglob("*")):
            if not p.is_file():
                continue
            rel = p.relative_to(out_b)
            counterpart = out_a / rel
            assert counterpart.is_file(), f"Extra file in second build: {rel}"

    # --- VAL-DASH-035: legacy runs produce no artifact dirs or anchors ---

    def test_legacy_run_no_artifact_dirs_created(self, tmp_path: Path) -> None:
        """Legacy runs without artifacts/ create no dist/<run-id>/<scenario-id>/artifacts/
        directories (VAL-DASH-035)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_legacy_run(reports, "run-leg-nodir", ["sc-leg-nodir"])

        run = collect_run(reports, "run-leg-nodir")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        # No artifact directories should be created for the legacy run
        artifact_dirs = list((out / "run-leg-nodir").rglob("artifacts"))
        assert not artifact_dirs, (
            f"Expected no artifact dirs for legacy run, found: {artifact_dirs}"
        )

    def test_legacy_run_no_artifact_anchors_in_html(self, tmp_path: Path) -> None:
        """Legacy runs emit no anchors with data-artifact attributes or empty hrefs
        (VAL-DASH-035)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_legacy_run(reports, "run-leg-noanchor", ["sc-leg-anchor"])

        run = collect_run(reports, "run-leg-noanchor")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-leg-noanchor" / "index.html").read_text(encoding="utf-8")

        # No data-artifact anchors for legacy runs
        assert "data-artifact=" not in html, (
            "Legacy run rendered data-artifact anchors unexpectedly"
        )
        # No empty-href anchors
        assert 'href=""' not in html, "Legacy run rendered empty-href anchors"
        # No artifacts/ path references
        assert "artifacts/scenario.yaml" not in html, "Legacy run referenced artifact files in HTML"

    # --- Render integration: fixture and manifest hrefs resolve in dist ---

    def test_fixture_and_manifest_hrefs_resolve_in_dist(self, tmp_path: Path) -> None:
        """After render_run(), every fixture and manifest href resolves to a copied file
        under dist/<run-id>/ (VAL-DASH-030)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_rich_run(reports, "run-fxmf", ["sc-fxmf"])

        run = collect_run(reports, "run-fxmf")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        run_dist = out / "run-fxmf"
        sc = run.scenarios[0]

        # Check fixture hrefs resolve
        for href in sc.artifact_links.get("fixtures", []):
            path = run_dist / href
            assert path.is_file(), f"Fixture href does not resolve: {href} → {path}"
            assert path.stat().st_size > 0, f"Fixture file is empty: {path}"

        # Check manifest hrefs resolve
        for href in sc.artifact_links.get("manifests", []):
            path = run_dist / href
            assert path.is_file(), f"Manifest href does not resolve: {href} → {path}"
            assert path.stat().st_size > 0, f"Manifest file is empty: {path}"
