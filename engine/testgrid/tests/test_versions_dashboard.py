"""Tests for the versions dashboard page (f2-3-versions-dashboard-page).

Covers:
  VAL-VER-007: Versions dashboard page displays merged config (render, sections, sources)
  VAL-VER-008: Version edit writes to project versions.yaml only, never engine/defaults/
  VAL-VER-009: Version edit triggers dashboard rebuild
  VAL-VER-010: Version edit history recorded in reports/versions-history.json
  VAL-VER-011: Old runs preserve their original version info
  VAL-VER-012: Nav bar includes Versions link on all pages

Test categories:
  - TestRenderVersionsPage: template rendering, sections, source display
  - TestBuildVersionRows: VersionRow construction and source labeling
  - TestWriteVersionEdit: file write, engine-defaults protection, project-only writes
  - TestLogVersionHistory: history file creation, appending, field validation
  - TestVersionsNavBar: Versions link in nav on all pages
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
import yaml

from testgrid.versions import (
    VersionRow,
    build_version_rows,
    get_resolved_config,
    load_engine_defaults,
    load_project_overrides,
    log_version_history,
    write_version_edit,
)
from testgrid.render import HomeSummary, render_home, render_runs, render_versions

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _minimal_engine_defaults() -> dict[str, Any]:
    """Return a minimal engine-defaults config for testing."""
    return {
        "kubernetes": {
            "kind": "1.31",
            "minikube": "1.31",
            "gke": "1.30",
            "eks": "1.30",
            "aks": "1.30",
        },
        "cli_tools": {
            "helm": "3.17",
            "kubectl": "1.31",
            "kind": "0.27",
            "minikube": "1.35",
        },
        "preinstalls": {
            "cert-manager": {
                "chart": "cert-manager",
                "version": "v1.17",
                "repo": "https://charts.jetstack.io",
            },
            "traefik": {
                "chart": "traefik",
                "version": "34.0.0",
                "repo": "https://traefik.github.io/charts",
            },
        },
        "product": {"chart": "sample", "version": "0.1.0"},
        "cloud": {
            "gke": {"k8s_version": "1.30", "region": "us-central1"},
            "eks": {"k8s_version": "1.30", "region": "us-east-1"},
            "aks": {"k8s_version": "1.30", "region": "eastus"},
        },
    }


def _write_project_versions(tmp_path: Path, data: dict[str, Any]) -> Path:
    """Write *data* to tmp_path/chart-test/versions.yaml; return tmp_path."""
    chart_test_dir = tmp_path / "chart-test"
    chart_test_dir.mkdir(parents=True, exist_ok=True)
    (chart_test_dir / "versions.yaml").write_text(
        yaml.dump(data, default_flow_style=False), encoding="utf-8"
    )
    return tmp_path


def _write_engine_defaults(tmp_path: Path, data: dict[str, Any]) -> Path:
    """Write *data* to tmp_path/defaults/versions.yaml; return path."""
    defaults_dir = tmp_path / "defaults"
    defaults_dir.mkdir(parents=True, exist_ok=True)
    path = defaults_dir / "versions.yaml"
    path.write_text(yaml.dump(data, default_flow_style=False), encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# TestBuildVersionRows
# ---------------------------------------------------------------------------


class TestBuildVersionRows:
    """Tests for build_version_rows() — VersionRow construction and source labeling."""

    def test_returns_all_five_sections(self) -> None:
        """build_version_rows() must return rows for all five config sections."""
        defaults = _minimal_engine_defaults()
        rows = build_version_rows(defaults, project_overrides=None)
        assert set(rows.keys()) == {"kubernetes", "cli_tools", "preinstalls", "product", "cloud"}

    def test_engine_defaults_labeled_as_engine_default(self) -> None:
        """Rows from engine defaults only must have source='engine-default'."""
        defaults = _minimal_engine_defaults()
        rows = build_version_rows(defaults, project_overrides=None)
        for row in rows["kubernetes"]:
            assert row.source == "engine-default", (
                f"Expected engine-default for {row.key}, got {row.source}"
            )

    def test_project_override_labeled_as_project_override(self) -> None:
        """Rows that come from project overrides must have source='project-override'."""
        from testgrid.versions import merge_configs

        defaults = _minimal_engine_defaults()
        overrides = {"kubernetes": {"kind": "1.29"}}
        # merged_config must be the merged result; build_version_rows uses it for values
        merged = merge_configs(defaults, overrides)
        rows = build_version_rows(merged, project_overrides=overrides)
        kind_row = next(r for r in rows["kubernetes"] if r.key == "kind")
        assert kind_row.source == "project-override", (
            f"Expected project-override for kind, got {kind_row.source}"
        )
        assert kind_row.version == "1.29"

    def test_non_overridden_keys_still_engine_default(self) -> None:
        """Keys not in project overrides remain labeled engine-default."""
        defaults = _minimal_engine_defaults()
        overrides = {"kubernetes": {"kind": "1.29"}}
        rows = build_version_rows(defaults, project_overrides=overrides)
        minikube_row = next(r for r in rows["kubernetes"] if r.key == "minikube")
        assert minikube_row.source == "engine-default"

    def test_cli_tools_rows_have_correct_versions(self) -> None:
        """cli_tools rows must reflect the merged version values."""
        defaults = _minimal_engine_defaults()
        rows = build_version_rows(defaults, project_overrides=None)
        helm_row = next(r for r in rows["cli_tools"] if r.key == "helm")
        assert helm_row.version == "3.17"

    def test_preinstalls_rows_include_extra_fields(self) -> None:
        """Preinstall rows must include chart name and repo in extra metadata."""
        defaults = _minimal_engine_defaults()
        rows = build_version_rows(defaults, project_overrides=None)
        cm_row = next(r for r in rows["preinstalls"] if r.key == "cert-manager")
        assert cm_row.version == "v1.17"
        # extra metadata available via the row
        assert cm_row.extra.get("chart") == "cert-manager"
        assert "jetstack" in cm_row.extra.get("repo", "")

    def test_cloud_rows_use_dotted_key_format(self) -> None:
        """Cloud rows must use provider.key format for the row key."""
        defaults = _minimal_engine_defaults()
        rows = build_version_rows(defaults, project_overrides=None)
        keys = [r.key for r in rows["cloud"]]
        assert any("gke." in k for k in keys), "Expected gke.* keys in cloud section"
        assert any("eks." in k for k in keys), "Expected eks.* keys in cloud section"

    def test_version_row_dataclass_fields(self) -> None:
        """VersionRow must have section, key, version, source fields."""
        row = VersionRow(section="kubernetes", key="kind", version="1.31", source="engine-default")
        assert row.section == "kubernetes"
        assert row.key == "kind"
        assert row.version == "1.31"
        assert row.source == "engine-default"


# ---------------------------------------------------------------------------
# TestRenderVersionsPage
# ---------------------------------------------------------------------------


class TestRenderVersionsPage:
    """Tests for render_versions() — template rendering with merged config."""

    def test_produces_versions_html(self, tmp_path: Path) -> None:
        """render_versions() must write versions.html to the output directory."""
        defaults = _minimal_engine_defaults()
        result = render_versions(out_dir=tmp_path, merged_config=defaults, project_overrides=None)
        assert result == tmp_path / "versions.html"
        assert result.is_file()

    def test_versions_html_has_all_five_section_headers(self, tmp_path: Path) -> None:
        """versions.html must contain table headers for all five config sections (VAL-VER-007)."""
        defaults = _minimal_engine_defaults()
        render_versions(out_dir=tmp_path, merged_config=defaults, project_overrides=None)
        html = (tmp_path / "versions.html").read_text(encoding="utf-8")
        # All five sections must appear in the page
        assert "Kubernetes" in html
        assert "CLI Tools" in html or "cli_tools" in html.lower()
        assert "Preinstalls" in html
        assert "Product" in html
        assert "Cloud" in html

    def test_versions_html_shows_version_values(self, tmp_path: Path) -> None:
        """versions.html must display actual version values from the merged config."""
        defaults = _minimal_engine_defaults()
        render_versions(out_dir=tmp_path, merged_config=defaults, project_overrides=None)
        html = (tmp_path / "versions.html").read_text(encoding="utf-8")
        assert "1.31" in html  # kubernetes kind/minikube version
        assert "3.17" in html  # helm version
        assert "v1.17" in html  # cert-manager version

    def test_versions_html_shows_source_badges(self, tmp_path: Path) -> None:
        """versions.html must display the source for each row (VAL-VER-007)."""
        defaults = _minimal_engine_defaults()
        render_versions(out_dir=tmp_path, merged_config=defaults, project_overrides=None)
        html = (tmp_path / "versions.html").read_text(encoding="utf-8")
        assert "engine-default" in html or "engine default" in html.lower()

    def test_project_overrides_visually_distinct(self, tmp_path: Path) -> None:
        """Project overrides must have a distinct visual class or style (VAL-VER-007)."""
        defaults = _minimal_engine_defaults()
        overrides = {"kubernetes": {"kind": "1.29"}}
        render_versions(out_dir=tmp_path, merged_config=defaults, project_overrides=overrides)
        html = (tmp_path / "versions.html").read_text(encoding="utf-8")
        # Must contain project-override CSS class or visual distinction
        assert "project-override" in html

    def test_versions_html_has_edit_buttons(self, tmp_path: Path) -> None:
        """versions.html must have Edit buttons per row for inline editing."""
        defaults = _minimal_engine_defaults()
        render_versions(out_dir=tmp_path, merged_config=defaults, project_overrides=None)
        html = (tmp_path / "versions.html").read_text(encoding="utf-8")
        assert "Edit" in html
        # Must have multiple edit buttons (one per row)
        assert html.count("Edit") >= 3

    def test_versions_html_has_nav_bar(self, tmp_path: Path) -> None:
        """versions.html must include the nav bar (VAL-VER-012)."""
        defaults = _minimal_engine_defaults()
        render_versions(out_dir=tmp_path, merged_config=defaults, project_overrides=None)
        html = (tmp_path / "versions.html").read_text(encoding="utf-8")
        assert "top-nav" in html or "nav-item" in html

    def test_versions_html_nav_has_versions_link(self, tmp_path: Path) -> None:
        """The nav bar must include a Versions link (VAL-VER-012)."""
        defaults = _minimal_engine_defaults()
        render_versions(out_dir=tmp_path, merged_config=defaults, project_overrides=None)
        html = (tmp_path / "versions.html").read_text(encoding="utf-8")
        assert "versions.html" in html
        assert "Versions" in html

    def test_render_versions_without_config_uses_engine_defaults(self, tmp_path: Path) -> None:
        """render_versions() with no merged_config arg still produces valid HTML."""
        result = render_versions(out_dir=tmp_path)
        assert result.is_file()
        html = result.read_text(encoding="utf-8")
        assert "<html" in html


# ---------------------------------------------------------------------------
# TestWriteVersionEdit
# ---------------------------------------------------------------------------


class TestWriteVersionEdit:
    """Tests for write_version_edit() — project-only writes, engine-defaults protection."""

    def test_write_creates_project_versions_yaml(self, tmp_path: Path) -> None:
        """write_version_edit() must create chart-test/versions.yaml when absent."""
        project_dir = tmp_path / "project"
        project_dir.mkdir()
        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()
        engine_defaults_path = _write_engine_defaults(tmp_path, _minimal_engine_defaults())

        write_version_edit(
            section="kubernetes",
            key="kind",
            new_value="1.29",
            project_dir=project_dir,
            reports_dir=reports_dir,
            engine_defaults_path=engine_defaults_path,
        )
        versions_file = project_dir / "chart-test" / "versions.yaml"
        assert versions_file.is_file(), "chart-test/versions.yaml must be created"

    def test_write_stores_new_value_in_project_yaml(self, tmp_path: Path) -> None:
        """write_version_edit() must store the new value in the project versions.yaml."""
        project_dir = tmp_path / "project"
        project_dir.mkdir()
        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()
        engine_defaults_path = _write_engine_defaults(tmp_path, _minimal_engine_defaults())

        write_version_edit(
            section="kubernetes",
            key="kind",
            new_value="1.29",
            project_dir=project_dir,
            reports_dir=reports_dir,
            engine_defaults_path=engine_defaults_path,
        )

        versions_file = project_dir / "chart-test" / "versions.yaml"
        data = yaml.safe_load(versions_file.read_text(encoding="utf-8"))
        assert data["kubernetes"]["kind"] == "1.29"

    def test_write_does_not_modify_engine_defaults(self, tmp_path: Path) -> None:
        """write_version_edit() must NEVER modify engine/defaults/versions.yaml (VAL-VER-008)."""
        project_dir = tmp_path / "project"
        project_dir.mkdir()
        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()
        defaults_data = _minimal_engine_defaults()
        engine_defaults_path = _write_engine_defaults(tmp_path, defaults_data)
        original_content = engine_defaults_path.read_text(encoding="utf-8")

        write_version_edit(
            section="kubernetes",
            key="kind",
            new_value="1.29",
            project_dir=project_dir,
            reports_dir=reports_dir,
            engine_defaults_path=engine_defaults_path,
        )

        # Engine defaults must be unchanged
        after_content = engine_defaults_path.read_text(encoding="utf-8")
        assert after_content == original_content, (
            "engine/defaults/versions.yaml must not be modified by write_version_edit()"
        )

    def test_write_updates_existing_project_yaml(self, tmp_path: Path) -> None:
        """write_version_edit() must update existing project YAML without losing other keys."""
        project_dir = _write_project_versions(
            tmp_path / "project",
            {"kubernetes": {"kind": "1.28"}, "product": {"chart": "my-chart", "version": "1.0"}},
        )
        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()
        engine_defaults_path = _write_engine_defaults(tmp_path, _minimal_engine_defaults())

        write_version_edit(
            section="kubernetes",
            key="kind",
            new_value="1.30",
            project_dir=project_dir,
            reports_dir=reports_dir,
            engine_defaults_path=engine_defaults_path,
        )

        versions_file = project_dir / "chart-test" / "versions.yaml"
        data = yaml.safe_load(versions_file.read_text(encoding="utf-8"))
        assert data["kubernetes"]["kind"] == "1.30"
        # Other keys preserved
        assert data["product"]["chart"] == "my-chart"

    def test_write_preinstall_version(self, tmp_path: Path) -> None:
        """write_version_edit() must handle preinstalls section correctly."""
        project_dir = tmp_path / "project"
        project_dir.mkdir()
        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()
        engine_defaults_path = _write_engine_defaults(tmp_path, _minimal_engine_defaults())

        write_version_edit(
            section="preinstalls",
            key="cert-manager",
            new_value="v1.15",
            project_dir=project_dir,
            reports_dir=reports_dir,
            engine_defaults_path=engine_defaults_path,
        )

        versions_file = project_dir / "chart-test" / "versions.yaml"
        data = yaml.safe_load(versions_file.read_text(encoding="utf-8"))
        assert data["preinstalls"]["cert-manager"]["version"] == "v1.15"

    def test_write_returns_old_value(self, tmp_path: Path) -> None:
        """write_version_edit() must return the old value that was replaced."""
        project_dir = _write_project_versions(
            tmp_path / "project",
            {"kubernetes": {"kind": "1.28"}},
        )
        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()
        defaults_data = _minimal_engine_defaults()
        engine_defaults_path = _write_engine_defaults(tmp_path, defaults_data)

        old_value = write_version_edit(
            section="kubernetes",
            key="kind",
            new_value="1.30",
            project_dir=project_dir,
            reports_dir=reports_dir,
            engine_defaults_path=engine_defaults_path,
        )
        # Old value was "1.28" (from existing project override)
        assert old_value == "1.28"

    def test_write_old_value_from_engine_defaults_when_no_project_override(
        self, tmp_path: Path
    ) -> None:
        """write_version_edit() old_value comes from engine defaults when no project override."""
        project_dir = tmp_path / "project"
        project_dir.mkdir()
        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()
        defaults_data = _minimal_engine_defaults()
        engine_defaults_path = _write_engine_defaults(tmp_path, defaults_data)

        old_value = write_version_edit(
            section="kubernetes",
            key="kind",
            new_value="1.29",
            project_dir=project_dir,
            reports_dir=reports_dir,
            engine_defaults_path=engine_defaults_path,
        )
        # Old value from engine defaults is "1.31"
        assert old_value == "1.31"


# ---------------------------------------------------------------------------
# TestLogVersionHistory
# ---------------------------------------------------------------------------


class TestLogVersionHistory:
    """Tests for log_version_history() — history.json creation, appending, fields."""

    def test_creates_versions_history_json(self, tmp_path: Path) -> None:
        """log_version_history() must create reports/versions-history.json."""
        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()

        log_version_history(
            section="kubernetes",
            key="kind",
            old_value="1.31",
            new_value="1.29",
            source_file="chart-test/versions.yaml",
            reports_dir=reports_dir,
        )

        history_file = reports_dir / "versions-history.json"
        assert history_file.is_file(), "versions-history.json must be created"

    def test_history_entry_has_required_fields(self, tmp_path: Path) -> None:
        """History entries must have: timestamp, component, old_value, new_value, source_file (VAL-VER-010)."""
        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()

        log_version_history(
            section="kubernetes",
            key="kind",
            old_value="1.31",
            new_value="1.29",
            source_file="chart-test/versions.yaml",
            reports_dir=reports_dir,
        )

        history_file = reports_dir / "versions-history.json"
        data = json.loads(history_file.read_text(encoding="utf-8"))
        assert "history" in data
        entry = data["history"][-1]
        assert "timestamp" in entry, "Entry must have 'timestamp'"
        assert "component" in entry, "Entry must have 'component'"
        assert "old_value" in entry, "Entry must have 'old_value'"
        assert "new_value" in entry, "Entry must have 'new_value'"
        assert "source_file" in entry, "Entry must have 'source_file'"

    def test_history_entry_values_correct(self, tmp_path: Path) -> None:
        """History entry values must match what was logged."""
        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()

        log_version_history(
            section="kubernetes",
            key="kind",
            old_value="1.31",
            new_value="1.29",
            source_file="chart-test/versions.yaml",
            reports_dir=reports_dir,
        )

        history_file = reports_dir / "versions-history.json"
        data = json.loads(history_file.read_text(encoding="utf-8"))
        entry = data["history"][-1]
        assert entry["component"] == "kubernetes.kind"
        assert entry["old_value"] == "1.31"
        assert entry["new_value"] == "1.29"
        assert entry["source_file"] == "chart-test/versions.yaml"

    def test_history_appends_multiple_entries(self, tmp_path: Path) -> None:
        """Multiple calls to log_version_history() must append entries."""
        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()

        log_version_history(
            section="kubernetes",
            key="kind",
            old_value="1.31",
            new_value="1.29",
            source_file="chart-test/versions.yaml",
            reports_dir=reports_dir,
        )
        log_version_history(
            section="cli_tools",
            key="helm",
            old_value="3.17",
            new_value="3.16",
            source_file="chart-test/versions.yaml",
            reports_dir=reports_dir,
        )

        history_file = reports_dir / "versions-history.json"
        data = json.loads(history_file.read_text(encoding="utf-8"))
        assert len(data["history"]) == 2

    def test_history_timestamp_is_iso_format(self, tmp_path: Path) -> None:
        """History entry timestamp must be in ISO 8601 format."""
        import datetime

        reports_dir = tmp_path / "reports"
        reports_dir.mkdir()

        log_version_history(
            section="kubernetes",
            key="kind",
            old_value="1.31",
            new_value="1.29",
            source_file="chart-test/versions.yaml",
            reports_dir=reports_dir,
        )

        history_file = reports_dir / "versions-history.json"
        data = json.loads(history_file.read_text(encoding="utf-8"))
        timestamp_str = data["history"][-1]["timestamp"]
        # Must be parseable as ISO datetime
        dt = datetime.datetime.fromisoformat(timestamp_str)
        assert dt is not None


# ---------------------------------------------------------------------------
# TestVersionsNavBar
# ---------------------------------------------------------------------------


class TestVersionsNavBar:
    """Tests ensuring Versions link appears in nav on all pages (VAL-VER-012)."""

    def test_home_html_nav_has_versions_link(self, tmp_path: Path) -> None:
        """home.html nav must include a Versions link."""
        summary = HomeSummary(run_count=1, pass_rate_pct=50.0, open_rec_count=0)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert "versions.html" in html
        assert "Versions" in html

    def test_runs_html_nav_has_versions_link(self, tmp_path: Path) -> None:
        """runs.html nav must include a Versions link."""
        render_runs([], tmp_path)
        html = (tmp_path / "runs.html").read_text(encoding="utf-8")
        assert "versions.html" in html
        assert "Versions" in html

    def test_versions_html_nav_active_state(self, tmp_path: Path) -> None:
        """versions.html nav must mark Versions as active when on the Versions page."""
        defaults = _minimal_engine_defaults()
        render_versions(out_dir=tmp_path, merged_config=defaults, project_overrides=None)
        html = (tmp_path / "versions.html").read_text(encoding="utf-8")
        # nav-active class must be on the Versions link
        assert "nav-active" in html
        # Specifically for Versions page
        assert 'aria-current="page"' in html
