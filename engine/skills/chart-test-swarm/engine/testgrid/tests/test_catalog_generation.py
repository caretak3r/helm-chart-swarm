"""Tests for deterministic catalog generation (f12-4).

Covers VAL-CAT-005, VAL-CAT-006, VAL-CAT-007.

The catalog maps category → integration/capability → scenarios with each
entry referencing the scenario's canonical YAML path and an
applied-overrides locator.  Ordering is lexicographically stable and
regeneration yields byte-identical output (modulo a single timestamp line).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_scenario(
    scenarios_dir: Path,
    category: str,
    filename: str,
    *,
    scenario_id: str | None = None,
    integration: str | None = None,
    capability: str | None = None,
    tier: str | None = None,
    extra: dict[str, Any] | None = None,
) -> Path:
    """Write a minimal scenario YAML under *scenarios_dir/<category>/<filename>*.

    Returns the path to the written file.
    """
    cat_dir = scenarios_dir / category
    cat_dir.mkdir(parents=True, exist_ok=True)
    path = cat_dir / filename
    doc: dict[str, Any] = {
        "id": scenario_id or filename.replace(".yaml", ""),
        "cluster": {"provider": "kind", "k8s_version": "v1.30.0"},
        "product": {"chart": "./chart", "release": "sample", "namespace": "sample"},
        "asserts": [{"type": "pods-ready", "namespace": "sample"}],
    }
    if category:
        doc["category"] = category
    if integration:
        doc["integration"] = integration
    if capability:
        doc["capability"] = capability
    if tier:
        doc["tier"] = tier
    if extra:
        doc.update(extra)
    path.write_text(yaml.dump(doc, sort_keys=False, default_flow_style=False), encoding="utf-8")
    return path


def _write_run_artifacts(reports_dir: Path, run_id: str, scenario_id: str) -> Path:
    """Write a minimal run artifacts bundle so the catalog can resolve overrides."""
    agent_dir = reports_dir / run_id / f"scenario-{scenario_id}" / "artifacts"
    agent_dir.mkdir(parents=True, exist_ok=True)
    (agent_dir / "scenario.yaml").write_text(
        yaml.dump({"id": scenario_id}, sort_keys=False), encoding="utf-8"
    )
    (agent_dir / "applied-overrides.yaml").write_text(
        yaml.dump({"image": {"tag": "1.27"}}, sort_keys=False), encoding="utf-8"
    )
    return agent_dir


# ---------------------------------------------------------------------------
# VAL-CAT-005: catalog parses as category → integration/capability → scenarios,
#   every scenario on disk appears exactly once, total count equals file walk
# ---------------------------------------------------------------------------


class TestCatalogStructure:
    """VAL-CAT-005: catalog maps category → integration/capability → scenarios."""

    def test_catalog_parses_as_mapping(self, tmp_path: Path) -> None:
        """Generated catalog.yaml parses as a valid YAML mapping."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "certificates",
            "cert-manager-self-signed.yaml",
            scenario_id="cert-manager-self-signed",
            integration="cert-manager",
            tier="live",
        )
        catalog = generate_catalog(scenarios_dir)
        assert isinstance(catalog, dict)

    def test_catalog_top_keys_are_categories(self, tmp_path: Path) -> None:
        """Top-level keys in the catalog are scenario categories."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "networking",
            "traefik-basic.yaml",
            scenario_id="traefik-basic",
            integration="traefik",
            tier="live",
        )
        _write_scenario(
            scenarios_dir,
            "certificates",
            "cert-manager-self-signed.yaml",
            scenario_id="cert-manager-self-signed",
            integration="cert-manager",
            tier="live",
        )
        catalog = generate_catalog(scenarios_dir)
        assert set(catalog.keys()) == {"networking", "certificates"}

    def test_catalog_second_level_are_integrations_or_capabilities(self, tmp_path: Path) -> None:
        """Second-level keys are integration names or capability names."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "certificates",
            "cert-manager-self-signed.yaml",
            scenario_id="cert-manager-self-signed",
            integration="cert-manager",
            tier="live",
        )
        _write_scenario(
            scenarios_dir,
            "capability",
            "baseline-deploy.yaml",
            scenario_id="baseline-deploy",
            capability="baseline-deploy",
            tier="capability",
        )
        catalog = generate_catalog(scenarios_dir)
        # certificates category → cert-manager integration
        assert "cert-manager" in catalog["certificates"]
        # capability category → baseline-deploy capability
        assert "baseline-deploy" in catalog["capability"]

    def test_catalog_every_scenario_appears_exactly_once(self, tmp_path: Path) -> None:
        """Every scenario file on disk appears exactly once in the catalog."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        ids = []
        for cat, integ, sid, tier in [
            ("certificates", "cert-manager", "cert-manager-self-signed", "live"),
            ("certificates", "cert-manager", "cert-manager-wildcard", "live"),
            ("networking", "traefik", "traefik-basic", "live"),
            ("capability", "baseline-deploy", "baseline-deploy", "capability"),
        ]:
            _write_scenario(
                scenarios_dir,
                cat,
                f"{sid}.yaml",
                scenario_id=sid,
                integration=integ if cat != "capability" else None,
                capability=integ if cat == "capability" else None,
                tier=tier,
            )
            ids.append(sid)

        catalog = generate_catalog(scenarios_dir)

        # Flatten all scenario ids from the catalog
        found_ids: list[str] = []
        for _cat, integrations in catalog.items():
            for _integ, scenarios in integrations.items():
                for entry in scenarios:
                    found_ids.append(entry["id"])

        assert sorted(found_ids) == sorted(ids)

    def test_catalog_count_equals_file_walk(self, tmp_path: Path) -> None:
        """Total catalog scenario count equals the number of YAML files on disk."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        for i in range(5):
            _write_scenario(
                scenarios_dir,
                "networking",
                f"traefik-variant-{i}.yaml",
                scenario_id=f"traefik-variant-{i}",
                integration="traefik",
                tier="live",
            )

        catalog = generate_catalog(scenarios_dir)

        # Count files on disk
        file_count = sum(1 for _ in scenarios_dir.rglob("*.yaml") if _.is_file())

        # Count scenarios in catalog
        catalog_count = sum(
            len(scenarios)
            for integrations in catalog.values()
            for scenarios in integrations.values()
        )
        assert catalog_count == file_count

    def test_catalog_scenario_without_integration_goes_to_uncategorized(
        self, tmp_path: Path
    ) -> None:
        """Scenarios with a category but no integration/capability are placed
        under a special key (e.g. the category itself or '_uncategorized')."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "networking",
            "generic-test.yaml",
            scenario_id="generic-test",
            tier="live",
            # No integration or capability field
        )
        catalog = generate_catalog(scenarios_dir)
        # The scenario must appear somewhere under the "networking" category
        all_ids: list[str] = []
        for integ_scenarios in catalog.get("networking", {}).values():
            for entry in integ_scenarios:
                all_ids.append(entry["id"])
        assert "generic-test" in all_ids

    def test_catalog_scenario_without_category_infers_from_directory(self, tmp_path: Path) -> None:
        """A scenario that omits the category field has it inferred from its
        parent directory name."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        # Write a scenario without the `category` field, but in a directory
        # named "service-mesh"
        cat_dir = scenarios_dir / "service-mesh"
        cat_dir.mkdir(parents=True, exist_ok=True)
        path = cat_dir / "istio-basic.yaml"
        doc = {
            "id": "istio-basic",
            "cluster": {"provider": "kind", "k8s_version": "v1.30.0"},
            "product": {"chart": "./chart", "release": "sample", "namespace": "sample"},
            "asserts": [{"type": "pods-ready", "namespace": "sample"}],
            "integration": "istio",
            "tier": "live",
            # No `category` field — should be inferred from dir name
        }
        path.write_text(yaml.dump(doc, sort_keys=False), encoding="utf-8")

        catalog = generate_catalog(scenarios_dir)
        assert "service-mesh" in catalog


# ---------------------------------------------------------------------------
# VAL-CAT-006: each catalog entry references its canonical YAML and
#   overrides; canonical path resolves; overrides resolves or is marked
# ---------------------------------------------------------------------------


class TestCatalogReferences:
    """VAL-CAT-006: canonical path and overrides reference per entry."""

    def test_entry_has_canonical_path(self, tmp_path: Path) -> None:
        """Each catalog entry carries a 'path' field referencing the scenario YAML."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "certificates",
            "cert-manager-self-signed.yaml",
            scenario_id="cert-manager-self-signed",
            integration="cert-manager",
            tier="live",
        )
        catalog = generate_catalog(scenarios_dir)
        entry = catalog["certificates"]["cert-manager"][0]
        assert "path" in entry
        # The path should be a relative path within the scenarios tree
        assert entry["path"].endswith(".yaml")

    def test_canonical_path_resolves_on_disk(self, tmp_path: Path) -> None:
        """Each entry's canonical scenario YAML path resolves to an existing file."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "certificates",
            "cert-manager-self-signed.yaml",
            scenario_id="cert-manager-self-signed",
            integration="cert-manager",
            tier="live",
        )
        catalog = generate_catalog(scenarios_dir)
        entry = catalog["certificates"]["cert-manager"][0]
        resolved = scenarios_dir / entry["path"]
        assert resolved.is_file(), f"canonical path {resolved} does not resolve"

    def test_entry_has_overrides_reference(self, tmp_path: Path) -> None:
        """Each entry carries an 'overrides' reference."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "certificates",
            "cert-manager-self-signed.yaml",
            scenario_id="cert-manager-self-signed",
            integration="cert-manager",
            tier="live",
        )
        catalog = generate_catalog(scenarios_dir)
        entry = catalog["certificates"]["cert-manager"][0]
        assert "overrides" in entry

    def test_overrides_for_unrun_scenario_is_not_yet_run(self, tmp_path: Path) -> None:
        """For a not-yet-run scenario, the overrides reference is explicitly
        marked as not-yet-run (never a dangling path)."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "certificates",
            "cert-manager-self-signed.yaml",
            scenario_id="cert-manager-self-signed",
            integration="cert-manager",
            tier="live",
        )
        # No reports dir — scenario has never been run
        catalog = generate_catalog(scenarios_dir)
        entry = catalog["certificates"]["cert-manager"][0]
        overrides = entry["overrides"]
        # Must not be a dangling path — should be a marker string
        assert (
            overrides is None
            or (isinstance(overrides, str) and not overrides.endswith(".yaml"))
            or overrides == "not-yet-run"
        )

    def test_overrides_for_run_scenario_resolves(self, tmp_path: Path) -> None:
        """For a run scenario with reports, the overrides reference resolves."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "certificates",
            "cert-manager-self-signed.yaml",
            scenario_id="cert-manager-self-signed",
            integration="cert-manager",
            tier="live",
        )
        reports_dir = tmp_path / "reports"
        _write_run_artifacts(reports_dir, "run-20260601", "cert-manager-self-signed")
        catalog = generate_catalog(scenarios_dir, reports_dir=reports_dir)
        entry = catalog["certificates"]["cert-manager"][0]
        overrides_ref = entry["overrides"]
        # When there is a matching run, the overrides reference should
        # either be a resolvable path or a structured locator
        assert overrides_ref is not None
        # If it's a path, it must resolve relative to reports_dir
        if isinstance(overrides_ref, str) and overrides_ref.endswith(".yaml"):
            resolved = reports_dir / overrides_ref
            assert resolved.is_file(), f"overrides path {resolved} does not resolve"


# ---------------------------------------------------------------------------
# VAL-CAT-007: catalog generation is deterministic
# ---------------------------------------------------------------------------


class TestCatalogDeterminism:
    """VAL-CAT-007: byte-identical regeneration."""

    def test_regenerating_twice_yields_byte_identical_catalog(self, tmp_path: Path) -> None:
        """Generating the catalog twice produces byte-identical output
        (modulo the timestamp line)."""
        from testgrid.catalog import catalog_to_yaml, generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        for cat, integ, sid, tier in [
            ("networking", "traefik", "traefik-basic", "live"),
            ("certificates", "cert-manager", "cert-manager-self-signed", "live"),
            ("service-mesh", "istio", "istio-sidecar", "live"),
            ("capability", "baseline-deploy", "baseline-deploy", "capability"),
        ]:
            _write_scenario(
                scenarios_dir,
                cat,
                f"{sid}.yaml",
                scenario_id=sid,
                integration=integ if cat != "capability" else None,
                capability=integ if cat == "capability" else None,
                tier=tier,
            )

        catalog_a = generate_catalog(scenarios_dir)
        catalog_b = generate_catalog(scenarios_dir)
        yaml_a = catalog_to_yaml(catalog_a)
        yaml_b = catalog_to_yaml(catalog_b)

        # Strip the timestamp line (first line) for comparison
        lines_a = yaml_a.splitlines(keepends=True)
        lines_b = yaml_b.splitlines(keepends=True)
        # The timestamp line starts with "# Generated at"
        body_a = "".join(line for line in lines_a if not line.startswith("# Generated at"))
        body_b = "".join(line for line in lines_b if not line.startswith("# Generated at"))
        assert body_a == body_b

    def test_categories_are_lexicographically_sorted(self, tmp_path: Path) -> None:
        """Categories in the catalog appear in lexicographic order."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        for cat in ["service-mesh", "certificates", "networking", "capability"]:
            _write_scenario(
                scenarios_dir,
                cat,
                f"{cat}-test.yaml",
                scenario_id=f"{cat}-test",
                integration="test-integration",
                tier="live",
            )

        catalog = generate_catalog(scenarios_dir)
        keys = list(catalog.keys())
        assert keys == sorted(keys)

    def test_integrations_within_category_are_sorted(self, tmp_path: Path) -> None:
        """Integrations/capabilities within a category appear sorted."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        for integ in ["traefik", "nginx-ingress", "contour"]:
            _write_scenario(
                scenarios_dir,
                "networking",
                f"{integ}-basic.yaml",
                scenario_id=f"{integ}-basic",
                integration=integ,
                tier="live",
            )

        catalog = generate_catalog(scenarios_dir)
        integ_keys = list(catalog["networking"].keys())
        assert integ_keys == sorted(integ_keys)

    def test_scenarios_within_integration_are_sorted_by_id(self, tmp_path: Path) -> None:
        """Scenarios within an integration/capability appear sorted by id."""
        from testgrid.catalog import generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        for variant in ["wildcard", "self-signed", "lets-encrypt-staging"]:
            _write_scenario(
                scenarios_dir,
                "certificates",
                f"cert-manager-{variant}.yaml",
                scenario_id=f"cert-manager-{variant}",
                integration="cert-manager",
                tier="live",
            )

        catalog = generate_catalog(scenarios_dir)
        entries = catalog["certificates"]["cert-manager"]
        ids = [e["id"] for e in entries]
        assert ids == sorted(ids)

    def test_catalog_to_yaml_deterministic_with_same_input(self, tmp_path: Path) -> None:
        """catalog_to_yaml produces deterministic YAML text for the same
        catalog dict (the timestamp line is excluded from comparison)."""
        from testgrid.catalog import catalog_to_yaml, generate_catalog

        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "networking",
            "traefik-basic.yaml",
            scenario_id="traefik-basic",
            integration="traefik",
            tier="live",
        )
        catalog = generate_catalog(scenarios_dir)
        text_a = catalog_to_yaml(catalog)
        text_b = catalog_to_yaml(catalog)
        lines_a = text_a.splitlines(keepends=True)
        lines_b = text_b.splitlines(keepends=True)
        body_a = "".join(line for line in lines_a if not line.startswith("# Generated at"))
        body_b = "".join(line for line in lines_b if not line.startswith("# Generated at"))
        assert body_a == body_b


# ---------------------------------------------------------------------------
# CLI integration
# ---------------------------------------------------------------------------


class TestCatalogCLI:
    """Verify the ``testgrid catalog`` subcommand."""

    def test_catalog_subcommand_produces_yaml(self, tmp_path: Path) -> None:
        """``testgrid catalog --scenarios <dir> --out <file>`` writes a
        valid catalog.yaml."""
        from testgrid.cli import main

        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "networking",
            "traefik-basic.yaml",
            scenario_id="traefik-basic",
            integration="traefik",
            tier="live",
        )
        out_file = tmp_path / "catalog.yaml"
        exit_code = main(
            [
                "catalog",
                "--scenarios",
                str(scenarios_dir),
                "--out",
                str(out_file),
            ]
        )
        assert exit_code == 0
        assert out_file.is_file()
        doc = yaml.safe_load(out_file.read_text(encoding="utf-8"))
        assert "networking" in doc

    def test_catalog_subcommand_stdout(self, tmp_path: Path) -> None:
        """``testgrid catalog --scenarios <dir>`` (no --out) writes to stdout."""
        from io import StringIO

        from testgrid.cli import main

        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "certificates",
            "cert-manager-basic.yaml",
            scenario_id="cert-manager-basic",
            integration="cert-manager",
            tier="live",
        )

        # Capture stdout
        import contextlib

        buf = StringIO()
        with contextlib.redirect_stdout(buf):
            exit_code = main(["catalog", "--scenarios", str(scenarios_dir)])
        assert exit_code == 0
        output = buf.getvalue()
        assert "certificates" in output

    def test_catalog_subcommand_nonexistent_dir(self, tmp_path: Path) -> None:
        """``testgrid catalog --scenarios <nonexistent>`` exits non-zero."""
        from testgrid.cli import main

        exit_code = main(
            [
                "catalog",
                "--scenarios",
                str(tmp_path / "no-such-dir"),
            ]
        )
        assert exit_code != 0
