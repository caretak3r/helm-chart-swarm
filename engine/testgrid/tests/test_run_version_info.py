"""Tests for run detail page version info section (f-fix-version-format-and-run-detail).

Covers:
  VAL-VER-003: cluster-up.sh uses kubernetes version from config
               (verified via versions.yaml format check)
  VAL-VER-011: Old runs preserve their original version info
               (run detail page shows versions from artifacts/versions.json)

Test categories:
  - TestVersionsYamlFormat: engine defaults use full patch version format
  - TestRunDetailVersionInfo: run.html.j2 shows version snapshot from artifacts
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
import yaml

from testgrid.collect import Run, Scenario
from testgrid.render import render_run
from testgrid.versions import DEFAULT_ENGINE_VERSIONS, load_engine_defaults

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_artifact_dir_with_versions(parent: Path, versions_data: dict[str, Any]) -> Path:
    """Create artifacts/ dir under *parent* with a versions.json file."""
    art = parent / "artifacts"
    art.mkdir(parents=True, exist_ok=True)
    (art / "versions.json").write_text(json.dumps(versions_data, indent=2), encoding="utf-8")
    return art


def _minimal_versions_json() -> dict[str, Any]:
    """Return a minimal versions.json structure (as produced by run-scenario.sh)."""
    return {
        "helm": "v3.17.0",
        "kubectl": "v1.31.0",
        "kind": "0.27.0",
        "minikube": "unknown",
        "k8s_server": "v1.31.0",
        "preinstalls": {
            "cert-manager": {
                "version": "v1.17",
                "source": "versions-config",
            }
        },
    }


# ---------------------------------------------------------------------------
# TestVersionsYamlFormat
# ---------------------------------------------------------------------------


class TestVersionsYamlFormat:
    """Tests that engine/defaults/versions.yaml uses full patch version format.

    Validates the format required for kind --image flag (VAL-VER-003).
    """

    def test_engine_defaults_kubernetes_kind_is_full_patch_format(self) -> None:
        """kubernetes.kind must be in full patch format (vMAJOR.MINOR.PATCH) for kind --image flag."""
        config = load_engine_defaults()
        kind_ver = config["kubernetes"]["kind"]
        # Must start with 'v' and have exactly three version components
        assert kind_ver.startswith("v"), (
            f"kubernetes.kind must start with 'v', got: '{kind_ver}'. "
            f"kind --image requires 'kindest/node:v<MAJOR>.<MINOR>.<PATCH>' format."
        )
        parts = kind_ver.lstrip("v").split(".")
        assert len(parts) == 3, (
            f"kubernetes.kind must be full semver (vMAJOR.MINOR.PATCH), got: '{kind_ver}'. "
            f"Format 'v1.31' is invalid for kind -- use 'v1.31.0'."
        )
        for part in parts:
            assert part.isdigit(), (
                f"kubernetes.kind version component '{part}' must be numeric, got: '{kind_ver}'"
            )

    def test_engine_defaults_kubernetes_minikube_is_full_patch_format(self) -> None:
        """kubernetes.minikube must be in full patch format (vMAJOR.MINOR.PATCH)."""
        config = load_engine_defaults()
        mk_ver = config["kubernetes"]["minikube"]
        assert mk_ver.startswith("v"), f"kubernetes.minikube must start with 'v', got: '{mk_ver}'."
        parts = mk_ver.lstrip("v").split(".")
        assert len(parts) == 3, (
            f"kubernetes.minikube must be full semver (vMAJOR.MINOR.PATCH), got: '{mk_ver}'."
        )


# ---------------------------------------------------------------------------
# TestRunDetailVersionInfo
# ---------------------------------------------------------------------------


class TestRunDetailVersionInfo:
    """Tests for version snapshot section in the run detail page (VAL-VER-011)."""

    def test_render_run_shows_version_info_section_when_versions_json_present(
        self, tmp_path: Path
    ) -> None:
        """Run detail page must render a version info section when versions.json is present."""
        art_dir = _make_artifact_dir_with_versions(
            tmp_path / "scenario-dir", _minimal_versions_json()
        )

        scenario = Scenario(
            id="test-scenario",
            status="PASS",
            artifact_dir=art_dir,
        )
        run = Run(
            run_id="run-test-ver-info",
            scenarios=[scenario],
        )

        out_dir = tmp_path / "out"
        render_run(run, out_dir)

        html = (out_dir / "run-test-ver-info" / "index.html").read_text(encoding="utf-8")
        # Must contain a version info / version snapshot section
        assert "version" in html.lower(), "Run page must contain version info section"

    def test_render_run_shows_k8s_server_version_from_versions_json(self, tmp_path: Path) -> None:
        """Run detail page must show the k8s server version from artifacts/versions.json (VAL-VER-011)."""
        versions_data = _minimal_versions_json()
        versions_data["k8s_server"] = "v1.31.0"
        art_dir = _make_artifact_dir_with_versions(tmp_path / "scenario-dir", versions_data)

        scenario = Scenario(
            id="test-scenario",
            status="PASS",
            artifact_dir=art_dir,
        )
        run = Run(run_id="run-test-k8s-ver", scenarios=[scenario])

        out_dir = tmp_path / "out"
        render_run(run, out_dir)

        html = (out_dir / "run-test-k8s-ver" / "index.html").read_text(encoding="utf-8")
        assert "v1.31.0" in html, (
            "Run detail page must show k8s server version from artifacts/versions.json"
        )

    def test_render_run_shows_preinstall_versions_with_sources(self, tmp_path: Path) -> None:
        """Run detail page must show preinstall chart versions with their sources (VAL-VER-011)."""
        versions_data: dict[str, Any] = {
            "helm": "v3.17.0",
            "kubectl": "v1.31.0",
            "kind": "0.27.0",
            "minikube": "unknown",
            "k8s_server": "v1.31.0",
            "preinstalls": {
                "cert-manager": {"version": "v1.17", "source": "versions-config"},
                "traefik": {"version": "34.0.0", "source": "scenario"},
            },
        }
        art_dir = _make_artifact_dir_with_versions(tmp_path / "scenario-dir", versions_data)

        scenario = Scenario(
            id="test-scenario",
            status="PASS",
            artifact_dir=art_dir,
        )
        run = Run(run_id="run-test-preinstalls", scenarios=[scenario])

        out_dir = tmp_path / "out"
        render_run(run, out_dir)

        html = (out_dir / "run-test-preinstalls" / "index.html").read_text(encoding="utf-8")
        # Must show both preinstall entries
        assert "cert-manager" in html, "Run page must show cert-manager preinstall"
        assert "v1.17" in html, "Run page must show cert-manager version"
        assert "versions-config" in html, "Run page must show versions-config source"
        assert "traefik" in html, "Run page must show traefik preinstall"
        assert "34.0.0" in html, "Run page must show traefik version"
        assert "scenario" in html, "Run page must show scenario source"

    def test_render_run_no_version_section_when_no_versions_json(self, tmp_path: Path) -> None:
        """Run detail page must not crash when no versions.json artifact is present."""
        scenario = Scenario(
            id="test-scenario",
            status="PASS",
            artifact_dir=None,
        )
        run = Run(run_id="run-test-no-versions", scenarios=[scenario])

        out_dir = tmp_path / "out"
        # Must not raise any exception
        render_run(run, out_dir)

        html = (out_dir / "run-test-no-versions" / "index.html").read_text(encoding="utf-8")
        assert "<html" in html, "Run page must render even without versions.json"

    def test_render_run_version_info_uses_artifact_from_oldest_not_current_config(
        self, tmp_path: Path
    ) -> None:
        """Run detail page must use artifact versions.json, not current config (VAL-VER-011).

        This ensures old runs preserve their original version info even after config changes.
        """
        # Simulate an old run with k8s v1.29.0 in its artifacts
        old_versions = {
            "helm": "v3.14.0",
            "kubectl": "v1.29.0",
            "kind": "0.22.0",
            "minikube": "unknown",
            "k8s_server": "v1.29.0",
            "preinstalls": {
                "cert-manager": {"version": "v1.14", "source": "versions-config"},
            },
        }
        art_dir = _make_artifact_dir_with_versions(tmp_path / "scenario-dir", old_versions)

        scenario = Scenario(
            id="test-scenario",
            status="PASS",
            artifact_dir=art_dir,
        )
        # Current config would have v1.31.0 but this old run used v1.29.0
        run = Run(
            run_id="run-test-old-ver",
            k8s_version="v1.29.0",
            scenarios=[scenario],
        )

        out_dir = tmp_path / "out"
        render_run(run, out_dir)

        html = (out_dir / "run-test-old-ver" / "index.html").read_text(encoding="utf-8")
        # Must show the OLD version from artifacts, not current config
        assert "v1.29.0" in html, (
            "Run page must show the version captured at run time (v1.29.0), not current config"
        )
        assert "v1.14" in html, (
            "Run page must show the old cert-manager version (v1.14) from run artifact"
        )

    def test_render_run_uses_first_scenario_with_versions_json(self, tmp_path: Path) -> None:
        """When multiple scenarios, render_run uses versions.json from the first available."""
        art_dir_1 = _make_artifact_dir_with_versions(
            tmp_path / "scenario-1",
            {**_minimal_versions_json(), "k8s_server": "v1.31.0"},
        )
        art_dir_2 = _make_artifact_dir_with_versions(
            tmp_path / "scenario-2",
            {**_minimal_versions_json(), "k8s_server": "v1.31.5"},  # different version
        )

        # Scenario IDs are sorted, so test-a comes before test-b
        scenarios = [
            Scenario(id="test-a", status="PASS", artifact_dir=art_dir_1),
            Scenario(id="test-b", status="PASS", artifact_dir=art_dir_2),
        ]
        run = Run(run_id="run-test-multi-scen", scenarios=scenarios)

        out_dir = tmp_path / "out"
        render_run(run, out_dir)

        html = (out_dir / "run-test-multi-scen" / "index.html").read_text(encoding="utf-8")
        # Should contain v1.31.0 from first sorted scenario (test-a)
        assert "v1.31.0" in html, "Run page must show versions from first scenario"

    def test_render_run_handles_malformed_versions_json_gracefully(self, tmp_path: Path) -> None:
        """render_run must not crash when versions.json is malformed."""
        art = tmp_path / "scenario-dir" / "artifacts"
        art.mkdir(parents=True, exist_ok=True)
        (art / "versions.json").write_text("INVALID JSON {{{", encoding="utf-8")

        scenario = Scenario(
            id="test-scenario",
            status="PASS",
            artifact_dir=art,
        )
        run = Run(run_id="run-test-bad-json", scenarios=[scenario])

        out_dir = tmp_path / "out"
        # Must not raise any exception
        render_run(run, out_dir)
        html = (out_dir / "run-test-bad-json" / "index.html").read_text(encoding="utf-8")
        assert "<html" in html
