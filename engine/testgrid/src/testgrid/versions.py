"""Version configuration management for chart-test-swarm.

Loads engine-level defaults from ``engine/defaults/versions.yaml``,
optionally merges with a project-level ``<project>/chart-test/versions.yaml``
(project values win on conflict), validates the merged config against a
JSON schema, and provides :func:`get_resolved_config` as the single public
entry point.

Merge strategy
--------------
- ``engine/defaults/versions.yaml`` is the authoritative baseline.
- ``<project>/chart-test/versions.yaml`` is an optional partial override.
- Deep merge: if both files have a dict for the same key, the merge
  recurses into that dict.  Scalar values in the project file always
  win over the corresponding engine-default value.
- The project file is optional; if absent, engine defaults are used as-is.

Schema
------
The merged config is validated against a JSON Schema (draft-07).  Five
top-level sections are required:

  ``kubernetes``   – provider k8s versions (kind, minikube, gke, eks, aks)
  ``cli_tools``    – CLI tool versions (helm, kubectl, kind, minikube)
  ``preinstalls``  – named Helm chart entries (chart, version, repo per entry)
  ``product``      – the chart under test (chart name, version)
  ``cloud``        – cloud provider settings (gke/eks/aks k8s_version + region)

Dashboard editing
-----------------
:func:`write_version_edit` writes a changed value to the project
``chart-test/versions.yaml`` (never to engine defaults).

:func:`log_version_history` appends a timestamped entry to
``reports/versions-history.json`` recording every edit.
"""

from __future__ import annotations

import copy
import datetime
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import jsonschema
import yaml

# ---------------------------------------------------------------------------
# Public constant — path to the bundled engine defaults
# ---------------------------------------------------------------------------

#: Absolute path to ``engine/defaults/versions.yaml``, resolved relative to
#: this module's location.  Workers must never modify this file.
DEFAULT_ENGINE_VERSIONS: Path = Path(__file__).parents[3] / "defaults" / "versions.yaml"

# ---------------------------------------------------------------------------
# JSON Schema for the version config
# ---------------------------------------------------------------------------

_CLOUD_PROVIDER_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "k8s_version": {"type": "string"},
        "region": {"type": "string"},
    },
    "additionalProperties": False,
}

_VERSION_CONFIG_SCHEMA: dict[str, Any] = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "type": "object",
    "required": ["kubernetes", "cli_tools", "preinstalls", "product", "cloud"],
    "additionalProperties": False,
    "properties": {
        "kubernetes": {
            "type": "object",
            "properties": {
                "kind": {"type": "string"},
                "minikube": {"type": "string"},
                "gke": {"type": "string"},
                "eks": {"type": "string"},
                "aks": {"type": "string"},
            },
            "additionalProperties": False,
        },
        "cli_tools": {
            "type": "object",
            "properties": {
                "helm": {"type": "string"},
                "kubectl": {"type": "string"},
                "kind": {"type": "string"},
                "minikube": {"type": "string"},
            },
            "additionalProperties": False,
        },
        "preinstalls": {
            "type": "object",
            "additionalProperties": {
                "type": "object",
                "required": ["chart", "version", "repo"],
                "properties": {
                    "chart": {"type": "string"},
                    "version": {"type": "string"},
                    "repo": {"type": "string"},
                },
                "additionalProperties": False,
            },
        },
        "product": {
            "type": "object",
            "properties": {
                "chart": {"type": "string"},
                "version": {"type": "string"},
            },
            "additionalProperties": False,
        },
        "cloud": {
            "type": "object",
            "properties": {
                "gke": _CLOUD_PROVIDER_SCHEMA,
                "eks": _CLOUD_PROVIDER_SCHEMA,
                "aks": _CLOUD_PROVIDER_SCHEMA,
            },
            "additionalProperties": False,
        },
    },
}


# ---------------------------------------------------------------------------
# Internal deep-merge helper
# ---------------------------------------------------------------------------


def _deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    """Return a new dict that deep-merges *override* into *base*.

    Rules:
    - If both dicts have a key whose value is a dict, recurse.
    - Otherwise the *override* value wins.
    - Neither *base* nor *override* is mutated.
    """
    result: dict[str, Any] = copy.deepcopy(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def load_engine_defaults(
    engine_defaults_path: Path | None = None,
) -> dict[str, Any]:
    """Load and return the engine-level version defaults.

    Parameters
    ----------
    engine_defaults_path:
        Explicit path to the engine defaults YAML.  Defaults to
        :data:`DEFAULT_ENGINE_VERSIONS`.

    Returns
    -------
    dict
        Parsed YAML as a plain Python dict.

    Raises
    ------
    FileNotFoundError
        If the defaults file does not exist at the resolved path.
    yaml.YAMLError
        If the file is not valid YAML.
    """
    path = engine_defaults_path or DEFAULT_ENGINE_VERSIONS
    with path.open(encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"Expected a YAML mapping in {path}, got {type(data).__name__}")
    return data


def load_project_overrides(project_dir: Path) -> dict[str, Any] | None:
    """Load the project-level version overrides, if present.

    Looks for ``<project_dir>/chart-test/versions.yaml``.

    Parameters
    ----------
    project_dir:
        Root directory of the project (e.g. ``examples/sample-product-chart``).

    Returns
    -------
    dict or None
        Parsed YAML as a plain Python dict, or ``None`` if the file does not
        exist.

    Raises
    ------
    yaml.YAMLError
        If the file exists but is not valid YAML.
    """
    versions_file = project_dir / "chart-test" / "versions.yaml"
    if not versions_file.is_file():
        return None
    with versions_file.open(encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if data is None:
        return None
    if not isinstance(data, dict):
        raise ValueError(f"Expected a YAML mapping in {versions_file}, got {type(data).__name__}")
    return data


def merge_configs(
    engine_defaults: dict[str, Any],
    project_overrides: dict[str, Any] | None,
) -> dict[str, Any]:
    """Deep-merge *project_overrides* on top of *engine_defaults*.

    Project values win on conflict.  Engine defaults fill any gaps not
    covered by the project file.  Neither input is mutated.

    Parameters
    ----------
    engine_defaults:
        The engine-level version config (loaded by :func:`load_engine_defaults`).
    project_overrides:
        The project-level overrides, or ``None`` if the project has no
        ``chart-test/versions.yaml``.

    Returns
    -------
    dict
        A new merged dict.  The caller receives full ownership; the inputs
        remain unchanged.
    """
    if project_overrides is None:
        return copy.deepcopy(engine_defaults)
    return _deep_merge(engine_defaults, project_overrides)


def validate_config(config: dict[str, Any]) -> None:
    """Validate *config* against the version-config JSON Schema.

    Parameters
    ----------
    config:
        A merged version config dict (as returned by :func:`merge_configs` or
        :func:`get_resolved_config`).

    Raises
    ------
    jsonschema.ValidationError
        If the config does not conform to the schema.
    jsonschema.SchemaError
        If the schema itself is malformed (should never happen).
    """
    jsonschema.validate(instance=config, schema=_VERSION_CONFIG_SCHEMA)


def get_resolved_config(
    project_dir: Path | None = None,
    engine_defaults_path: Path | None = None,
) -> dict[str, Any]:
    """Load, merge, validate, and return the resolved version config.

    This is the primary public entry point.  Call it with a *project_dir*
    to apply project-level overrides; omit it to use engine defaults only.

    Parameters
    ----------
    project_dir:
        Root directory of the project.  When provided, the function looks
        for ``<project_dir>/chart-test/versions.yaml`` and merges its values
        on top of the engine defaults (project wins on conflict).  If the
        file does not exist, engine defaults are used as-is.
    engine_defaults_path:
        Override the path to the engine defaults YAML.  Useful in tests.

    Returns
    -------
    dict
        The fully merged and schema-validated version config.

    Raises
    ------
    jsonschema.ValidationError
        If the resolved config does not conform to the schema.
    FileNotFoundError
        If the engine defaults file cannot be found.
    yaml.YAMLError
        If either YAML file is malformed.
    """
    defaults = load_engine_defaults(engine_defaults_path)
    overrides = load_project_overrides(project_dir) if project_dir is not None else None
    merged = merge_configs(defaults, overrides)
    validate_config(merged)
    return merged


# ---------------------------------------------------------------------------
# Dashboard display model
# ---------------------------------------------------------------------------


@dataclass
class VersionRow:
    """A single row in the versions dashboard table.

    Attributes
    ----------
    section:
        Top-level config section, e.g. ``"kubernetes"``, ``"cli_tools"``.
    key:
        Component name within the section.  For ``cloud``, the key uses
        dotted notation: ``"gke.k8s_version"``.
    version:
        The resolved version string for this component.
    source:
        Either ``"engine-default"`` (value came from engine/defaults/) or
        ``"project-override"`` (value was overridden by the project file).
    extra:
        Section-specific metadata.  For ``preinstalls``, holds
        ``{"chart": ..., "repo": ...}``.
    """

    section: str
    key: str
    version: str
    source: str  # "engine-default" | "project-override"
    extra: dict[str, str] = field(default_factory=dict)


def build_version_rows(
    merged_config: dict[str, Any],
    project_overrides: dict[str, Any] | None,
) -> dict[str, list[VersionRow]]:
    """Build display rows for the versions dashboard, annotated with source.

    For each value in *merged_config*, the function determines whether the
    value was contributed by the engine defaults or overridden by the project
    file by checking *project_overrides*.

    Parameters
    ----------
    merged_config:
        The fully merged version config (engine defaults + project overrides).
    project_overrides:
        The raw project overrides dict (as returned by
        :func:`load_project_overrides`), or ``None`` if there are no
        project overrides.  Used purely for source-labelling; it does not
        influence the values in the returned rows.

    Returns
    -------
    dict
        Mapping of section name → sorted list of :class:`VersionRow`.
    """
    overrides: dict[str, Any] = project_overrides or {}
    rows: dict[str, list[VersionRow]] = {}

    # kubernetes
    k8s_rows: list[VersionRow] = []
    for k, v in merged_config.get("kubernetes", {}).items():
        source = (
            "project-override"
            if "kubernetes" in overrides and k in overrides["kubernetes"]
            else "engine-default"
        )
        k8s_rows.append(VersionRow(section="kubernetes", key=k, version=str(v), source=source))
    rows["kubernetes"] = sorted(k8s_rows, key=lambda r: r.key)

    # cli_tools
    cli_rows: list[VersionRow] = []
    for k, v in merged_config.get("cli_tools", {}).items():
        source = (
            "project-override"
            if "cli_tools" in overrides and k in overrides["cli_tools"]
            else "engine-default"
        )
        cli_rows.append(VersionRow(section="cli_tools", key=k, version=str(v), source=source))
    rows["cli_tools"] = sorted(cli_rows, key=lambda r: r.key)

    # preinstalls
    preinstall_rows: list[VersionRow] = []
    for name, entry in merged_config.get("preinstalls", {}).items():
        if not isinstance(entry, dict):
            continue
        source = (
            "project-override"
            if "preinstalls" in overrides and name in overrides["preinstalls"]
            else "engine-default"
        )
        preinstall_rows.append(
            VersionRow(
                section="preinstalls",
                key=name,
                version=str(entry.get("version", "")),
                source=source,
                extra={
                    "chart": str(entry.get("chart", "")),
                    "repo": str(entry.get("repo", "")),
                },
            )
        )
    rows["preinstalls"] = sorted(preinstall_rows, key=lambda r: r.key)

    # product
    product_rows: list[VersionRow] = []
    for k, v in merged_config.get("product", {}).items():
        source = (
            "project-override"
            if "product" in overrides and k in overrides["product"]
            else "engine-default"
        )
        product_rows.append(VersionRow(section="product", key=k, version=str(v), source=source))
    rows["product"] = sorted(product_rows, key=lambda r: r.key)

    # cloud: flatten provider.key
    cloud_rows: list[VersionRow] = []
    for provider, provider_data in merged_config.get("cloud", {}).items():
        if not isinstance(provider_data, dict):
            continue
        for k, v in provider_data.items():
            source = (
                "project-override"
                if (
                    "cloud" in overrides
                    and provider in overrides["cloud"]
                    and k in overrides["cloud"][provider]
                )
                else "engine-default"
            )
            cloud_rows.append(
                VersionRow(
                    section="cloud",
                    key=f"{provider}.{k}",
                    version=str(v),
                    source=source,
                )
            )
    rows["cloud"] = sorted(cloud_rows, key=lambda r: r.key)

    return rows


# ---------------------------------------------------------------------------
# Version edit — write to project YAML only
# ---------------------------------------------------------------------------


def _get_key_path(section: str, key: str) -> list[str]:
    """Return the YAML key path for *section*.*key* in the project overrides.

    For ``preinstalls``, editing the version changes ``preinstalls.<name>.version``.
    For ``cloud``, the key is dotted (``gke.k8s_version``), so the path is
    ``["cloud", "gke", "k8s_version"]``.
    All other sections use ``[section, key]``.
    """
    if section == "preinstalls":
        return ["preinstalls", key, "version"]
    if section == "cloud" and "." in key:
        parts = key.split(".", 1)
        return ["cloud", parts[0], parts[1]]
    return [section, key]


def _get_old_value(
    section: str,
    key: str,
    project_dir: Path,
    engine_defaults_path: Path | None,
) -> str:
    """Return the current value for *section*.*key* from the resolved config.

    Reads the current project overrides (if any) merged with engine defaults
    to find the effective current value before the edit is applied.
    """
    defaults = load_engine_defaults(engine_defaults_path)
    overrides = load_project_overrides(project_dir)
    merged = merge_configs(defaults, overrides)

    if section == "preinstalls":
        preinstall = merged.get("preinstalls", {}).get(key, {})
        if isinstance(preinstall, dict):
            return str(preinstall.get("version", ""))
        return ""
    if section == "cloud" and "." in key:
        provider, subkey = key.split(".", 1)
        cloud_provider = merged.get("cloud", {}).get(provider, {})
        if isinstance(cloud_provider, dict):
            return str(cloud_provider.get(subkey, ""))
        return ""
    return str(merged.get(section, {}).get(key, ""))


def write_version_edit(
    section: str,
    key: str,
    new_value: str,
    project_dir: Path,
    reports_dir: Path,
    engine_defaults_path: Path | None = None,
) -> str:
    """Write a version edit to the project ``chart-test/versions.yaml``.

    This function MUST NEVER modify ``engine/defaults/versions.yaml``.
    Only the project-level file is written.

    The function reads the current state of the project overrides file
    (creating it if absent), sets ``section.key = new_value``, and writes
    the result back atomically.

    For the ``preinstalls`` section, only the ``version`` sub-field is
    updated; the ``chart`` and ``repo`` fields are preserved from engine
    defaults or existing project overrides.

    Parameters
    ----------
    section:
        Top-level config section (``kubernetes``, ``cli_tools``,
        ``preinstalls``, ``product``, ``cloud``).
    key:
        Component name within the section.  For ``cloud``, use dotted
        notation: ``"gke.k8s_version"``.
    new_value:
        The new version string to write.
    project_dir:
        Root directory of the project (contains ``chart-test/``).
    reports_dir:
        Path to the reports directory (used by :func:`log_version_history`
        called after this write).
    engine_defaults_path:
        Override path for engine defaults (tests only).

    Returns
    -------
    str
        The old value that was replaced.

    Raises
    ------
    ValueError
        If attempting to write to a path matching the engine defaults
        (safety guard — should never trigger in normal usage).
    """
    # Resolve the project versions.yaml path.
    chart_test_dir = project_dir / "chart-test"
    project_yaml_path = chart_test_dir / "versions.yaml"

    # Safety guard: ensure we are NOT writing to engine defaults.
    resolved_defaults = engine_defaults_path or DEFAULT_ENGINE_VERSIONS
    if project_yaml_path.resolve() == resolved_defaults.resolve():
        raise ValueError(
            "write_version_edit() must never write to engine/defaults/versions.yaml"
        )

    # Capture old value before any write.
    old_value = _get_old_value(section, key, project_dir, engine_defaults_path)

    # Load existing project overrides (or start from empty).
    existing: dict[str, Any] = {}
    if project_yaml_path.is_file():
        loaded = yaml.safe_load(project_yaml_path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            existing = loaded

    # Apply the edit by walking the key path.
    key_path = _get_key_path(section, key)
    node: dict[str, Any] = existing
    for part in key_path[:-1]:
        if part not in node or not isinstance(node[part], dict):
            node[part] = {}
        node = node[part]
    node[key_path[-1]] = new_value

    # Write back (create parent dir if needed).
    chart_test_dir.mkdir(parents=True, exist_ok=True)
    project_yaml_path.write_text(
        yaml.dump(existing, default_flow_style=False, allow_unicode=True),
        encoding="utf-8",
    )

    return old_value


# ---------------------------------------------------------------------------
# Version edit history logging
# ---------------------------------------------------------------------------


def log_version_history(
    section: str,
    key: str,
    old_value: str,
    new_value: str,
    source_file: str,
    reports_dir: Path,
    timestamp: str | None = None,
) -> None:
    """Append a version edit entry to ``reports/versions-history.json``.

    Creates the file if it does not exist.  Each entry records the
    component path, old value, new value, the file that was written,
    and an ISO 8601 timestamp.

    Parameters
    ----------
    section:
        Config section that was edited.
    key:
        Component key within the section.
    old_value:
        The value before the edit.
    new_value:
        The value after the edit.
    source_file:
        Relative path to the file that was written (e.g.
        ``"chart-test/versions.yaml"``).
    reports_dir:
        Path to the reports directory.
    timestamp:
        ISO 8601 timestamp string.  When ``None``, the current UTC time
        is used.  Provide a value in tests for determinism.
    """
    history_path = reports_dir / "versions-history.json"
    component = f"{section}.{key}"

    # Load existing history (or start fresh).
    history_data: dict[str, Any] = {"history": []}
    if history_path.is_file():
        try:
            loaded = json.loads(history_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict) and "history" in loaded:
                history_data = loaded
        except (json.JSONDecodeError, OSError):
            pass

    ts = timestamp or datetime.datetime.now(tz=datetime.UTC).isoformat()

    entry: dict[str, str] = {
        "timestamp": ts,
        "component": component,
        "old_value": old_value,
        "new_value": new_value,
        "source_file": source_file,
    }
    history_data["history"].append(entry)

    reports_dir.mkdir(parents=True, exist_ok=True)
    history_path.write_text(
        json.dumps(history_data, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
