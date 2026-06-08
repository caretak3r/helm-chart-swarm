"""Tests for versions.py — version config load, merge, and schema validation.

Covers:
  VAL-VER-001: engine/defaults/versions.yaml parses and validates against schema
  VAL-VER-002: project versions.yaml overrides engine defaults; defaults fill gaps

Test categories:
  - TestLoadEngineDefaults: parsing the engine defaults file
  - TestLoadProjectOverrides: loading optional project overrides
  - TestMergeConfigs: deep-merge semantics (project wins, defaults fill gaps)
  - TestValidateConfig: JSON schema validation
  - TestGetResolvedConfig: end-to-end merge + validate
"""

from __future__ import annotations

import copy
from pathlib import Path
from typing import Any

import pytest
import yaml

from testgrid.versions import (
    DEFAULT_ENGINE_VERSIONS,
    get_resolved_config,
    load_engine_defaults,
    load_project_overrides,
    merge_configs,
    validate_config,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_project_versions(tmp_path: Path, data: dict[str, Any]) -> Path:
    """Write *data* to tmp_path/chart-test/versions.yaml; return tmp_path."""
    chart_test_dir = tmp_path / "chart-test"
    chart_test_dir.mkdir(parents=True, exist_ok=True)
    (chart_test_dir / "versions.yaml").write_text(
        yaml.dump(data, default_flow_style=False), encoding="utf-8"
    )
    return tmp_path


# ---------------------------------------------------------------------------
# TestLoadEngineDefaults
# ---------------------------------------------------------------------------


class TestLoadEngineDefaults:
    """Tests for load_engine_defaults()."""

    def test_loads_without_error(self) -> None:
        """load_engine_defaults() loads the bundled defaults file without error."""
        config = load_engine_defaults()
        assert isinstance(config, dict)
        assert len(config) > 0

    def test_has_all_five_required_top_level_keys(self) -> None:
        """Engine defaults must have all five top-level keys (VAL-VER-001)."""
        config = load_engine_defaults()
        for key in ("kubernetes", "cli_tools", "preinstalls", "product", "cloud"):
            assert key in config, f"Missing required top-level key: '{key}'"

    def test_kubernetes_section_has_expected_providers(self) -> None:
        """kubernetes section must include kind and minikube version strings."""
        config = load_engine_defaults()
        k8s = config["kubernetes"]
        assert "kind" in k8s
        assert "minikube" in k8s
        assert isinstance(k8s["kind"], str), "kind version must be a string"
        assert isinstance(k8s["minikube"], str), "minikube version must be a string"

    def test_cli_tools_section_has_expected_tools(self) -> None:
        """cli_tools section must include helm, kubectl, kind, minikube."""
        config = load_engine_defaults()
        tools = config["cli_tools"]
        for tool in ("helm", "kubectl", "kind", "minikube"):
            assert tool in tools, f"cli_tools missing '{tool}'"
            assert isinstance(tools[tool], str), f"cli_tools.{tool} must be a string"

    def test_preinstalls_has_at_least_11_charts(self) -> None:
        """preinstalls section must contain 11 or more chart entries."""
        config = load_engine_defaults()
        preinstalls = config["preinstalls"]
        assert isinstance(preinstalls, dict)
        assert len(preinstalls) >= 11, (
            f"Expected at least 11 preinstalls, found {len(preinstalls)}: "
            f"{list(preinstalls.keys())}"
        )

    def test_each_preinstall_has_chart_version_repo(self) -> None:
        """Every preinstall entry must have 'chart', 'version', and 'repo' fields."""
        config = load_engine_defaults()
        for name, entry in config["preinstalls"].items():
            for field in ("chart", "version", "repo"):
                assert field in entry, f"preinstall '{name}' missing '{field}'"
                assert isinstance(entry[field], str), (
                    f"preinstall '{name}'.{field} must be a string"
                )

    def test_cloud_section_has_gke_eks_aks(self) -> None:
        """cloud section must have gke, eks, and aks provider entries."""
        config = load_engine_defaults()
        cloud = config["cloud"]
        for provider in ("gke", "eks", "aks"):
            assert provider in cloud, f"cloud missing '{provider}'"
            assert "k8s_version" in cloud[provider], f"cloud.{provider} missing 'k8s_version'"
            assert "region" in cloud[provider], f"cloud.{provider} missing 'region'"

    def test_product_section_has_chart_and_version(self) -> None:
        """product section must have 'chart' and 'version' fields."""
        config = load_engine_defaults()
        product = config["product"]
        assert "chart" in product
        assert "version" in product

    def test_explicit_path_parameter(self, tmp_path: Path) -> None:
        """load_engine_defaults() accepts an explicit Path argument."""
        data: dict[str, Any] = {
            "kubernetes": {"kind": "1.28", "minikube": "1.28"},
            "cli_tools": {"helm": "3.15", "kubectl": "1.28", "kind": "0.25", "minikube": "1.33"},
            "preinstalls": {},
            "product": {"chart": "test-chart", "version": "0.0.1"},
            "cloud": {},
        }
        custom_file = tmp_path / "custom-versions.yaml"
        custom_file.write_text(yaml.dump(data), encoding="utf-8")
        result = load_engine_defaults(custom_file)
        assert result["kubernetes"]["kind"] == "1.28"
        assert result["cli_tools"]["helm"] == "3.15"

    def test_default_path_constant_points_to_existing_file(self) -> None:
        """DEFAULT_ENGINE_VERSIONS must be a path to an existing file."""
        assert DEFAULT_ENGINE_VERSIONS.is_file(), (
            f"DEFAULT_ENGINE_VERSIONS does not exist: {DEFAULT_ENGINE_VERSIONS}"
        )


# ---------------------------------------------------------------------------
# TestLoadProjectOverrides
# ---------------------------------------------------------------------------


class TestLoadProjectOverrides:
    """Tests for load_project_overrides()."""

    def test_returns_none_when_no_chart_test_dir(self, tmp_path: Path) -> None:
        """Returns None when chart-test/ directory does not exist."""
        result = load_project_overrides(tmp_path)
        assert result is None

    def test_returns_none_when_no_versions_file(self, tmp_path: Path) -> None:
        """Returns None when chart-test/versions.yaml does not exist."""
        (tmp_path / "chart-test").mkdir()
        result = load_project_overrides(tmp_path)
        assert result is None

    def test_loads_project_versions_yaml(self, tmp_path: Path) -> None:
        """Loads chart-test/versions.yaml and returns its contents as dict."""
        project_dir = _write_project_versions(tmp_path, {"kubernetes": {"kind": "1.29"}})
        result = load_project_overrides(project_dir)
        assert result is not None
        assert result["kubernetes"]["kind"] == "1.29"

    def test_project_override_can_be_partial(self, tmp_path: Path) -> None:
        """Project override only needs a subset of sections."""
        project_dir = _write_project_versions(
            tmp_path, {"product": {"chart": "my-chart", "version": "1.0.0"}}
        )
        result = load_project_overrides(project_dir)
        assert result is not None
        assert "product" in result
        assert "kubernetes" not in result  # partial is OK


# ---------------------------------------------------------------------------
# TestMergeConfigs
# ---------------------------------------------------------------------------


class TestMergeConfigs:
    """Tests for merge_configs() — deep merge with project winning on conflict."""

    def test_no_overrides_returns_copy_of_defaults(self) -> None:
        """merge_configs(defaults, None) returns the engine defaults unchanged."""
        defaults: dict[str, Any] = {
            "kubernetes": {"kind": "1.31", "minikube": "1.31"},
            "cli_tools": {"helm": "3.17"},
        }
        result = merge_configs(defaults, None)
        assert result == defaults

    def test_project_value_wins_on_conflict(self) -> None:
        """When both have the same key, the project value takes precedence."""
        defaults: dict[str, Any] = {"kubernetes": {"kind": "1.31", "minikube": "1.31"}}
        project: dict[str, Any] = {"kubernetes": {"kind": "1.29"}}
        result = merge_configs(defaults, project)
        assert result["kubernetes"]["kind"] == "1.29", "project value should win"

    def test_engine_defaults_fill_missing_keys(self) -> None:
        """Keys present in defaults but absent from project are preserved."""
        defaults: dict[str, Any] = {"kubernetes": {"kind": "1.31", "minikube": "1.31"}}
        project: dict[str, Any] = {"kubernetes": {"kind": "1.29"}}
        result = merge_configs(defaults, project)
        assert result["kubernetes"]["minikube"] == "1.31", "default should fill gap"

    def test_engine_defaults_fill_missing_sections(self) -> None:
        """Entire sections missing from project are preserved from defaults."""
        defaults: dict[str, Any] = {
            "kubernetes": {"kind": "1.31"},
            "cli_tools": {"helm": "3.17"},
        }
        project: dict[str, Any] = {"kubernetes": {"kind": "1.29"}}
        result = merge_configs(defaults, project)
        assert "cli_tools" in result
        assert result["cli_tools"]["helm"] == "3.17"

    def test_deep_merge_of_preinstalls(self) -> None:
        """Deep merge: project overrides one preinstall, default keeps others."""
        defaults: dict[str, Any] = {
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
            }
        }
        project: dict[str, Any] = {
            "preinstalls": {
                "cert-manager": {
                    "chart": "cert-manager",
                    "version": "v1.14",
                    "repo": "https://charts.jetstack.io",
                },
            }
        }
        result = merge_configs(defaults, project)
        # project cert-manager version wins
        assert result["preinstalls"]["cert-manager"]["version"] == "v1.14"
        # default traefik is preserved
        assert result["preinstalls"]["traefik"]["version"] == "34.0.0"

    def test_does_not_mutate_defaults(self) -> None:
        """merge_configs must not mutate the engine defaults dict."""
        defaults: dict[str, Any] = {"kubernetes": {"kind": "1.31"}}
        project: dict[str, Any] = {"kubernetes": {"kind": "1.29"}}
        defaults_before = copy.deepcopy(defaults)
        merge_configs(defaults, project)
        assert defaults == defaults_before, "engine defaults must not be mutated"

    def test_does_not_mutate_project(self) -> None:
        """merge_configs must not mutate the project overrides dict."""
        defaults: dict[str, Any] = {"kubernetes": {"kind": "1.31"}}
        project: dict[str, Any] = {"kubernetes": {"kind": "1.29"}}
        project_before = copy.deepcopy(project)
        merge_configs(defaults, project)
        assert project == project_before, "project overrides must not be mutated"

    def test_project_adds_new_section_to_defaults(self) -> None:
        """Project can add a key not present in defaults at all."""
        defaults: dict[str, Any] = {"kubernetes": {"kind": "1.31"}}
        project: dict[str, Any] = {"extra_key": "custom-value"}
        result = merge_configs(defaults, project)
        assert result["extra_key"] == "custom-value"
        assert result["kubernetes"]["kind"] == "1.31"


# ---------------------------------------------------------------------------
# TestValidateConfig
# ---------------------------------------------------------------------------


class TestValidateConfig:
    """Tests for validate_config() — JSON schema validation."""

    def test_valid_engine_defaults_pass(self) -> None:
        """The bundled engine defaults file passes schema validation."""
        config = load_engine_defaults()
        validate_config(config)  # must not raise

    def test_missing_kubernetes_section_fails(self) -> None:
        """Config without 'kubernetes' section fails schema validation."""
        import jsonschema

        config = load_engine_defaults()
        del config["kubernetes"]
        with pytest.raises(jsonschema.ValidationError):
            validate_config(config)

    def test_missing_preinstalls_section_fails(self) -> None:
        """Config without 'preinstalls' section fails schema validation."""
        import jsonschema

        config = load_engine_defaults()
        del config["preinstalls"]
        with pytest.raises(jsonschema.ValidationError):
            validate_config(config)

    def test_preinstall_missing_repo_field_fails(self) -> None:
        """A preinstall entry missing the 'repo' field fails validation."""
        import jsonschema

        config = load_engine_defaults()
        config["preinstalls"]["no-repo-chart"] = {"chart": "no-repo", "version": "1.0"}
        with pytest.raises(jsonschema.ValidationError):
            validate_config(config)

    def test_non_string_version_fails(self) -> None:
        """A version value that is not a string fails validation."""
        import jsonschema

        config = load_engine_defaults()
        config["kubernetes"]["kind"] = 131  # integer, not string
        with pytest.raises(jsonschema.ValidationError):
            validate_config(config)


# ---------------------------------------------------------------------------
# TestGetResolvedConfig
# ---------------------------------------------------------------------------


class TestGetResolvedConfig:
    """Tests for get_resolved_config() — full load + merge + validate pipeline."""

    def test_no_project_dir_returns_engine_defaults(self) -> None:
        """get_resolved_config() with no project_dir returns engine defaults."""
        config = get_resolved_config()
        assert isinstance(config, dict)
        for key in ("kubernetes", "cli_tools", "preinstalls", "product", "cloud"):
            assert key in config

    def test_missing_project_file_uses_defaults_only(self, tmp_path: Path) -> None:
        """When project dir has no chart-test/versions.yaml, returns engine defaults."""
        config = get_resolved_config(project_dir=tmp_path)
        defaults = load_engine_defaults()
        assert config == defaults

    def test_project_override_wins_on_conflict(self, tmp_path: Path) -> None:
        """Project-level kubernetes.kind overrides the engine default (VAL-VER-002)."""
        project_dir = _write_project_versions(tmp_path, {"kubernetes": {"kind": "1.27"}})
        config = get_resolved_config(project_dir=project_dir)
        assert config["kubernetes"]["kind"] == "1.27", "project value must win over engine default"

    def test_engine_defaults_fill_missing_project_keys(self, tmp_path: Path) -> None:
        """Engine defaults provide all keys not in the project override."""
        project_dir = _write_project_versions(tmp_path, {"kubernetes": {"kind": "1.27"}})
        config = get_resolved_config(project_dir=project_dir)
        defaults = load_engine_defaults()
        # cli_tools not in project override — must come from engine defaults
        assert config["cli_tools"] == defaults["cli_tools"]
        # preinstalls not in project override — must come from engine defaults
        assert config["preinstalls"] == defaults["preinstalls"]

    def test_all_version_categories_present_with_project_dir(self, tmp_path: Path) -> None:
        """Resolved config always contains all five version categories."""
        config = get_resolved_config(project_dir=tmp_path)
        for key in ("kubernetes", "cli_tools", "preinstalls", "product", "cloud"):
            assert key in config, f"Category '{key}' missing from resolved config"

    def test_custom_engine_defaults_path(self, tmp_path: Path) -> None:
        """get_resolved_config() honours an explicit engine_defaults_path."""
        custom_defaults: dict[str, Any] = {
            "kubernetes": {
                "kind": "1.28",
                "minikube": "1.28",
                "gke": "1.27",
                "eks": "1.27",
                "aks": "1.27",
            },
            "cli_tools": {"helm": "3.15", "kubectl": "1.28", "kind": "0.25", "minikube": "1.33"},
            "preinstalls": {},
            "product": {"chart": "custom", "version": "0.0.1"},
            "cloud": {},
        }
        custom_file = tmp_path / "custom-defaults.yaml"
        custom_file.write_text(yaml.dump(custom_defaults), encoding="utf-8")
        config = get_resolved_config(engine_defaults_path=custom_file)
        assert config["kubernetes"]["kind"] == "1.28"
        assert config["product"]["chart"] == "custom"
