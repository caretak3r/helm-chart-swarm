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
"""

from __future__ import annotations

import copy
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
