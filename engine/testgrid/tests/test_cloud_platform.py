"""Tests for F2.3 — cloud-platform column rendering.

Validates:
  - VAL-DASH-011: Cloud-platform scenarios render with a distinct visual marker
  - VAL-DASH-012: Cloud-platform scenario card surfaces "authored, not run locally" tooltip
  - VAL-DASH-013: Cloud-platform scenarios show "AUTHORED" status instead of PASS/FAIL/UNTESTED
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


CLOUD_PROVIDERS = ["gke", "eks", "aks"]
LOCAL_PROVIDERS = ["kind", "minikube", "k3d"]


def _build_run_with_cloud_scenarios(
    reports_dir: Path,
    run_id: str,
    scenario_specs: list[dict[str, Any]],
) -> Path:
    """Create a synthetic run with scenarios that may have cloud providers.

    Each spec dict should have:
      - id: str
      - cluster_provider: str (e.g. "gke", "eks", "aks", "kind", "minikube")
      - status: str (PASS, FAIL, etc.) — may be overridden by cloud logic
      - (optional) mechanisms, tags, labels, name, description
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
                    "cluster": {"provider": spec.get("cluster_provider", "kind")},
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
                    "duration_s": 30,
                    "asserts": [{"type": "pods-ready", "status": "PASS", "notes": "ok"}],
                }
                for spec in scenario_specs
            ],
        },
    )

    return run_dir


# ---------------------------------------------------------------------------
# collect.py tests — cloud scenarios get AUTHORED status
# ---------------------------------------------------------------------------


class TestCloudScenarioStatus:
    """VAL-DASH-013: Cloud-platform scenarios show AUTHORED status."""

    @pytest.mark.parametrize("provider", CLOUD_PROVIDERS)
    def test_cloud_provider_forces_authored_status(self, tmp_path: Path, provider: str) -> None:
        """A scenario with cluster_provider={gke,eks,aks} gets status AUTHORED
        even when the agent result says PASS."""
        from testgrid.collect import collect_run

        _build_run_with_cloud_scenarios(
            tmp_path,
            "run-test",
            [
                {"id": "cloud-scenario", "cluster_provider": provider, "status": "PASS"},
                {"id": "local-scenario", "cluster_provider": "kind", "status": "PASS"},
            ],
        )

        run = collect_run(tmp_path, "run-test")
        cloud = next(s for s in run.scenarios if s.id == "cloud-scenario")
        local = next(s for s in run.scenarios if s.id == "local-scenario")

        assert cloud.status == "AUTHORED", (
            f"Cloud scenario ({provider}) should be AUTHORED, got {cloud.status}"
        )
        assert local.status == "PASS", (
            f"Local scenario (kind) should retain PASS, got {local.status}"
        )

    @pytest.mark.parametrize("provider", CLOUD_PROVIDERS)
    def test_cloud_scenario_without_result_still_authored(
        self, tmp_path: Path, provider: str
    ) -> None:
        """When no result.yaml entry exists for a cloud scenario (agent results
        don't mention it), the scenario still gets AUTHORED, not UNTESTED."""
        from testgrid.collect import collect_run

        run_dir = tmp_path / "run-test"
        run_dir.mkdir(parents=True)

        _write_yaml(
            run_dir / "run-meta.yaml",
            {
                "run_id": "run-test",
                "timestamp_utc": "2026-05-29T10:00:00Z",
                "num_agents": 1,
            },
        )

        # Snapshot with a cloud scenario
        _write_yaml(
            run_dir / "scenarios-snapshot.yaml",
            {
                "scenarios": [
                    {
                        "id": "cloud-only",
                        "name": "Cloud Only Scenario",
                        "description": "A cloud-native scenario",
                        "cluster": {"provider": provider},
                        "mechanisms": ["cloud:gke"],
                        "tags": ["cloud"],
                        "product": {
                            "chart": "sample",
                            "release": "cloud-only",
                            "namespace": "sample",
                        },
                        "asserts": [{"type": "pods-ready", "status": "PASS", "notes": "ok"}],
                    },
                    {
                        "id": "local-scenario",
                        "name": "Local Scenario",
                        "description": "A local scenario",
                        "cluster": {"provider": "kind"},
                        "mechanisms": ["certificates:cert-manager"],
                        "tags": ["tls"],
                        "product": {
                            "chart": "sample",
                            "release": "local-scenario",
                            "namespace": "sample",
                        },
                        "asserts": [{"type": "pods-ready", "status": "PASS", "notes": "ok"}],
                    },
                ],
            },
        )

        # Agent-1 result only mentions the local scenario — cloud scenario has no result
        agent_dir = run_dir / "agent-1"
        agent_dir.mkdir()
        _write_yaml(
            agent_dir / "result.yaml",
            {
                "agent": 1,
                "results": [
                    {
                        "scenario_id": "local-scenario",
                        "status": "PASS",
                        "duration_s": 30,
                        "asserts": [{"type": "pods-ready", "status": "PASS", "notes": "ok"}],
                    },
                ],
            },
        )

        run = collect_run(tmp_path, "run-test")
        cloud = next(s for s in run.scenarios if s.id == "cloud-only")
        local = next(s for s in run.scenarios if s.id == "local-scenario")

        assert cloud.status == "AUTHORED", (
            f"Cloud scenario without agent result should be AUTHORED, got {cloud.status}"
        )
        assert local.status == "PASS", "Local scenario with agent result should retain PASS"

    @pytest.mark.parametrize("provider", LOCAL_PROVIDERS)
    def test_local_provider_preserves_original_status(self, tmp_path: Path, provider: str) -> None:
        """Local-backend scenarios (kind/minikube/k3d) retain their original
        status and are NOT forced to AUTHORED."""
        from testgrid.collect import collect_run

        _build_run_with_cloud_scenarios(
            tmp_path,
            "run-test",
            [
                {
                    "id": "local-scenario",
                    "cluster_provider": provider,
                    "status": "FAIL",
                },
            ],
        )

        run = collect_run(tmp_path, "run-test")
        scenario = run.scenarios[0]

        assert scenario.status == "FAIL", (
            f"Local provider ({provider}) should retain FAIL status, got {scenario.status}"
        )


class TestCloudStatusRank:
    """Validate STATUS_RANK includes AUTHORED in correct position."""

    def test_authored_between_untested_and_pass(self) -> None:
        """STATUS_RANK ordering: FAIL(0) < PARTIAL(1) < UNTESTED(2)
        < INCONCLUSIVE(3) < INTERRUPTED(4) < SKIP(5) < AUTHORED(6) < PASS(7)."""
        from testgrid.collect import STATUS_RANK

        assert "AUTHORED" in STATUS_RANK, "STATUS_RANK missing AUTHORED key"
        assert STATUS_RANK["FAIL"] < STATUS_RANK["PARTIAL"]
        assert STATUS_RANK["PARTIAL"] < STATUS_RANK["UNTESTED"]
        assert STATUS_RANK["UNTESTED"] < STATUS_RANK["INCONCLUSIVE"]
        assert STATUS_RANK["INCONCLUSIVE"] < STATUS_RANK["AUTHORED"]
        assert STATUS_RANK["AUTHORED"] < STATUS_RANK["PASS"]

    def test_authored_rollup_below_pass(self) -> None:
        """When rolling up AUTHORED + PASS scenarios, the worst is AUTHORED
        (AUTHORED rank 6 < PASS rank 7)."""
        from testgrid.collect import STATUS_RANK, Scenario

        scenarios = [
            Scenario(id="sc-1", status="AUTHORED"),
            Scenario(id="sc-2", status="PASS"),
        ]
        rolled = min(
            (s.status for s in scenarios),
            key=lambda st: STATUS_RANK.get(st, 99),
        )
        assert rolled == "AUTHORED"

    def test_authored_rollup_above_fail(self) -> None:
        """When rolling up AUTHORED + FAIL scenarios, the worst is FAIL
        (FAIL rank 0 < AUTHORED rank 6)."""
        from testgrid.collect import STATUS_RANK, Scenario

        scenarios = [
            Scenario(id="sc-1", status="AUTHORED"),
            Scenario(id="sc-2", status="FAIL"),
        ]
        rolled = min(
            (s.status for s in scenarios),
            key=lambda st: STATUS_RANK.get(st, 99),
        )
        assert rolled == "FAIL"


# ---------------------------------------------------------------------------
# render.py tests — cloud badge marker in HTML output
# ---------------------------------------------------------------------------


class TestCloudBadgeRendering:
    """VAL-DASH-011 + VAL-DASH-012: Cloud platform visual marker and tooltip."""

    @pytest.mark.parametrize("provider", CLOUD_PROVIDERS)
    def test_cloud_scenario_card_has_cloud_badge(self, tmp_path: Path, provider: str) -> None:
        """Rendered HTML for a cloud scenario contains a .badge.cloud element
        with accessible tooltip text."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        _build_run_with_cloud_scenarios(
            tmp_path,
            "run-test",
            [
                {"id": "cloud-sc", "cluster_provider": provider, "status": "PASS"},
                {"id": "local-sc", "cluster_provider": "kind", "status": "PASS"},
            ],
        )

        run = collect_run(tmp_path, "run-test")
        out_dir = tmp_path / "dist"
        out_dir.mkdir()
        render_run(run, out_dir)

        html_path = out_dir / "run-test" / "index.html"
        html = html_path.read_text(encoding="utf-8")

        # The cloud scenario card should have a .badge.cloud element
        assert '.badge.cloud"' in html or ".badge.cloud'" in html or 'class="badge cloud' in html, (
            f"HTML should contain a .badge.cloud element for cloud scenario ({provider})"
        )

        # The tooltip should be present on the cloud badge
        tooltip_text = "authored, not run locally"
        assert tooltip_text.lower() in html.lower(), (
            f"HTML should contain the tooltip text '{tooltip_text}'"
        )

    @pytest.mark.parametrize("provider", LOCAL_PROVIDERS)
    def test_local_scenario_card_has_no_cloud_badge(self, tmp_path: Path, provider: str) -> None:
        """Local-backend scenario cards do NOT have a cloud badge."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        _build_run_with_cloud_scenarios(
            tmp_path,
            "run-test",
            [
                {"id": "local-sc", "cluster_provider": provider, "status": "PASS"},
            ],
        )

        run = collect_run(tmp_path, "run-test")
        out_dir = tmp_path / "dist"
        out_dir.mkdir()
        render_run(run, out_dir)

        html_path = out_dir / "run-test" / "index.html"
        html = html_path.read_text(encoding="utf-8")

        # For a local-only run, the cloud badge should NOT appear
        # Check the scenario card details block - no cloud badge near it
        assert "AUTHORED ONLY" not in html, (
            f"Local provider ({provider}) should not emit 'AUTHORED ONLY' text"
        )

    @pytest.mark.parametrize("provider", CLOUD_PROVIDERS)
    def test_cloud_status_cell_shows_authored(self, tmp_path: Path, provider: str) -> None:
        """The matrix status column for a cloud scenario shows AUTHORED."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        _build_run_with_cloud_scenarios(
            tmp_path,
            "run-test",
            [
                {"id": "cloud-sc", "cluster_provider": provider, "status": "PASS"},
            ],
        )

        run = collect_run(tmp_path, "run-test")
        out_dir = tmp_path / "dist"
        out_dir.mkdir()
        render_run(run, out_dir)

        html_path = out_dir / "run-test" / "index.html"
        html = html_path.read_text(encoding="utf-8")

        # The status badge in the matrix row should show AUTHORED
        assert "AUTHORED" in html, (
            f"HTML should render AUTHORED status for cloud scenario ({provider})"
        )

    def test_cloud_badge_has_accessible_tooltip(self, tmp_path: Path) -> None:
        """The cloud badge marker carries an accessible tooltip via title or
        aria-label attribute."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        _build_run_with_cloud_scenarios(
            tmp_path,
            "run-test",
            [
                {"id": "cloud-sc", "cluster_provider": "gke", "status": "PASS"},
            ],
        )

        run = collect_run(tmp_path, "run-test")
        out_dir = tmp_path / "dist"
        out_dir.mkdir()
        render_run(run, out_dir)

        html_path = out_dir / "run-test" / "index.html"
        html = html_path.read_text(encoding="utf-8")

        # The tooltip must be exposed via an accessible attribute
        tooltip_text = "authored, not run locally"
        assert (
            f'title="{tooltip_text}"' in html.lower()
            or f"title='{tooltip_text}'" in html.lower()
            or f'aria-label="{tooltip_text}"' in html.lower()
            or f"aria-label='{tooltip_text}'" in html.lower()
        ), "Cloud badge should have accessible tooltip via title/aria-label"


# ---------------------------------------------------------------------------
# Integration tests — full rendering pipeline
# ---------------------------------------------------------------------------


class TestCloudPlatformIntegration:
    """End-to-end rendering tests for mixed cloud + local scenario sets."""

    def test_mixed_cloud_and_local_rendering(self, tmp_path: Path) -> None:
        """A mixed run with cloud and local scenarios renders both correctly:
        cloud cards have AUTHORED status and cloud badge; local cards have
        normal status and no cloud badge."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        _build_run_with_cloud_scenarios(
            tmp_path,
            "run-mixed",
            [
                {"id": "cloud-gke", "cluster_provider": "gke", "status": "PASS"},
                {"id": "cloud-eks", "cluster_provider": "eks", "status": "FAIL"},
                {"id": "cloud-aks", "cluster_provider": "aks", "status": "UNTESTED"},
                {"id": "local-kind", "cluster_provider": "kind", "status": "PASS"},
                {"id": "local-minikube", "cluster_provider": "minikube", "status": "FAIL"},
            ],
        )

        run = collect_run(tmp_path, "run-mixed")

        # Verify statuses
        for sid, expected_status in [
            ("cloud-gke", "AUTHORED"),
            ("cloud-eks", "AUTHORED"),
            ("cloud-aks", "AUTHORED"),
            ("local-kind", "PASS"),
            ("local-minikube", "FAIL"),
        ]:
            scenario = next(s for s in run.scenarios if s.id == sid)
            assert scenario.status == expected_status, (
                f"{sid}: expected {expected_status}, got {scenario.status}"
            )

        # Render and verify HTML
        out_dir = tmp_path / "dist"
        out_dir.mkdir()
        render_run(run, out_dir)

        html_path = out_dir / "run-mixed" / "index.html"
        html = html_path.read_text(encoding="utf-8")

        # Cloud badge should appear (at least 3 times for 3 cloud scenarios)
        tooltip_text = "authored, not run locally"
        assert html.lower().count(tooltip_text.lower()) >= 3, (
            "Expected at least 3 tooltip occurrences for 3 cloud scenarios"
        )

        # Status badges should show AUTHORED for cloud scenarios
        assert html.count("AUTHORED") >= 3, "Expected at least 3 AUTHORED badge occurrences"

        # Local scenarios should still show PASS/FAIL
        assert "PASS" in html
        assert "FAIL" in html


class TestCloudScenarioVariantGrouping:
    """Cloud scenarios should work correctly with variant grouping (F2.2)."""

    def test_cloud_scenarios_in_variant_groups_get_authored_status(self, tmp_path: Path) -> None:
        """When cloud scenarios share a mechanism with 3+ variants, they
        are grouped and each gets AUTHORED status."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        specs = [
            {
                "id": "cloud-gke-v1",
                "cluster_provider": "gke",
                "mechanisms": ["cloud:gke:variant1"],
                "status": "PASS",
            },
            {
                "id": "cloud-gke-v2",
                "cluster_provider": "gke",
                "mechanisms": ["cloud:gke:variant2"],
                "status": "PASS",
            },
            {
                "id": "cloud-gke-v3",
                "cluster_provider": "gke",
                "mechanisms": ["cloud:gke:variant3"],
                "status": "PASS",
            },
        ]

        _build_run_with_cloud_scenarios(tmp_path, "run-grouped", specs)

        run = collect_run(tmp_path, "run-grouped")
        for s in run.scenarios:
            assert s.status == "AUTHORED", (
                f"Cloud scenario {s.id} should be AUTHORED, got {s.status}"
            )

        # Render and verify grouping still works
        out_dir = tmp_path / "dist"
        out_dir.mkdir()
        render_run(run, out_dir)
        html_path = out_dir / "run-grouped" / "index.html"
        html = html_path.read_text(encoding="utf-8")

        # The variant group header should show AUTHORED as worst status
        assert "AUTHORED" in html
