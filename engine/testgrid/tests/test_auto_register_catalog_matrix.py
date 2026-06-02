"""Tests for auto-registration of newly authored tests in catalog & matrix (f14-3).

Covers VAL-KIT-006, VAL-KIT-007, VAL-KIT-015.

These tests prove that a freshly authored test auto-registers with no
manual edit: after ``new`` scaffolds a scenario and the catalog is
regenerated, the catalog contains the entry mapping the new scenario;
after rebuilding the dashboard, the support matrix contains its cell.
The catalog is a pure function of scenarios (regeneration is
deterministic; adding one scenario is the only delta).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml
from typer.testing import CliRunner

from chart_test_swarm.main import app
from testgrid.catalog import catalog_to_yaml, generate_catalog

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

runner = CliRunner()

REPO_ROOT = Path(__file__).resolve().parents[3]
INTEGRATIONS_ROOT = (
    REPO_ROOT / "engine" / "skills" / "chart-test-swarm" / "references" / "integrations"
)
SCHEMA_PATH = REPO_ROOT / "engine" / "templates" / "scenario.schema.json"


def _setup_chart_test_dir(tmp_path: Path) -> Path:
    """Create a minimal chart-test/ tree under tmp_path for scaffolding."""
    chart_test = tmp_path / "chart-test"
    (chart_test / "scenarios").mkdir(parents=True, exist_ok=True)
    (chart_test / "fixtures").mkdir(parents=True, exist_ok=True)
    (chart_test / "assertions").mkdir(parents=True, exist_ok=True)
    return chart_test


def _write_scenario(
    scenarios_dir: Path,
    category: str,
    filename: str,
    *,
    scenario_id: str | None = None,
    integration: str | None = None,
    capability: str | None = None,
    tier: str | None = None,
    cluster_provider: str = "kind",
    extra: dict[str, Any] | None = None,
) -> Path:
    """Write a minimal scenario YAML under *scenarios_dir/<category>/<filename>*."""
    cat_dir = scenarios_dir / category
    cat_dir.mkdir(parents=True, exist_ok=True)
    path = cat_dir / filename
    doc: dict[str, Any] = {
        "id": scenario_id or filename.replace(".yaml", ""),
        "cluster": {"provider": cluster_provider, "k8s_version": "v1.30.0"},
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


def _write_run_result(
    reports_dir: Path,
    run_id: str,
    scenario_id: str,
    status: str = "PASS",
    cluster_provider: str = "kind",
) -> Path:
    """Write a minimal run result so collect can find scenario status."""
    agent_dir = reports_dir / run_id / "agent-1" / "artifacts"
    agent_dir.mkdir(parents=True, exist_ok=True)
    (agent_dir / "scenario.yaml").write_text(
        yaml.dump({"id": scenario_id}, sort_keys=False), encoding="utf-8"
    )
    (agent_dir / "applied-overrides.yaml").write_text(
        yaml.dump({"image": {"tag": "1.27"}}, sort_keys=False), encoding="utf-8"
    )
    # result.yaml
    result_path = reports_dir / run_id / "agent-1" / "result.yaml"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(
        yaml.dump(
            {
                "agent": 1,
                "results": [
                    {
                        "scenario_id": scenario_id,
                        "status": status,
                        "asserts": [{"type": "pods-ready", "status": status}],
                    }
                ],
            },
            sort_keys=False,
        ),
        encoding="utf-8",
    )
    # scenarios-snapshot.yaml
    snap_path = reports_dir / run_id / "scenarios-snapshot.yaml"
    snap_path.write_text(
        yaml.dump(
            {
                "scenarios": [
                    {
                        "id": scenario_id,
                        "cluster": {"provider": cluster_provider},
                        "product": {
                            "chart": "./chart",
                            "release": "sample",
                            "namespace": "sample",
                        },
                        "asserts": [{"type": "pods-ready", "namespace": "sample"}],
                    }
                ]
            },
            sort_keys=False,
        ),
        encoding="utf-8",
    )
    # run-meta.yaml
    meta_path = reports_dir / run_id / "run-meta.yaml"
    meta_path.write_text(
        yaml.dump(
            {
                "run_id": run_id,
                "project": {"name": "test"},
                "chart": {"name": "sample", "version": "0.1.0"},
                "cluster_provider": cluster_provider,
            },
            sort_keys=False,
        ),
        encoding="utf-8",
    )
    return result_path


def _build_dashboard(reports_dir: Path, scenarios_dir: Path, out_dir: Path) -> int:
    """Run the testgrid build command and return exit code."""
    from testgrid.cli import main

    return main(
        [
            "build",
            "--reports",
            str(reports_dir),
            "--out",
            str(out_dir),
            "--scenarios",
            str(scenarios_dir),
        ]
    )


def _scaffold_integration(
    tmp_path: Path,
    target: str,
    *,
    project_dir: str | None = None,
    force: bool = False,
    tier: str | None = None,
) -> object:
    """Run the ``new`` command via CliRunner and return the result."""
    args = ["new", target]
    if project_dir:
        args.extend(["--project-dir", project_dir])
    if force:
        args.append("--force")
    if tier:
        args.extend(["--tier", tier])
    return runner.invoke(app, args)


# ---------------------------------------------------------------------------
# VAL-KIT-006: freshly authored test auto-registers in catalog with
#   no manual edit
# ---------------------------------------------------------------------------


class TestAutoRegisterInCatalog:
    """VAL-KIT-006: After ``new`` scaffolds a scenario and the catalog is
    regenerated, the catalog contains the new scenario entry under the
    correct category/integration|capability node with no hand-edited
    registry file in the path."""

    def test_new_integration_scenario_appears_in_catalog(self, tmp_path: Path) -> None:
        """Scaffolding an integration scenario then regenerating the catalog
        produces a catalog entry for the new scenario under the correct
        category/integration node."""
        # Setup chart-test dir
        _setup_chart_test_dir(tmp_path)
        scenarios_dir = tmp_path / "chart-test" / "scenarios"

        # Pre-populate with an existing scenario
        _write_scenario(
            scenarios_dir,
            "certificates",
            "cert-manager-existing.yaml",
            scenario_id="cert-manager-existing",
            integration="cert-manager",
            tier="live",
        )

        # Generate catalog BEFORE new — should have only the existing scenario
        catalog_before = generate_catalog(scenarios_dir)
        cert_before = catalog_before.get("certificates", {}).get("cert-manager", [])
        before_ids = {e["id"] for e in cert_before}
        assert "cert-manager-existing" in before_ids
        assert "certificates-cert-manager" not in before_ids

        # Scaffold a new integration scenario
        result = _scaffold_integration(
            tmp_path,
            "certificates/cert-manager",
            project_dir=str(tmp_path),
        )
        assert result.exit_code == 0, f"new command failed: {result.stderr}"

        # Verify the scaffolded scenario file exists on disk
        scaffolded = scenarios_dir / "certificates" / "certificates-cert-manager.yaml"
        assert scaffolded.is_file(), f"scaffolded scenario not found at {scaffolded}"

        # Regenerate catalog AFTER new — should contain the new scenario
        catalog_after = generate_catalog(scenarios_dir)
        cert_after = catalog_after.get("certificates", {}).get("cert-manager", [])
        after_ids = {e["id"] for e in cert_after}
        assert "certificates-cert-manager" in after_ids, (
            "newly scaffolded scenario must appear in catalog under "
            "certificates/cert-manager after regeneration"
        )

        # The existing scenario is still there
        assert "cert-manager-existing" in after_ids

    def test_new_capability_scenario_appears_in_catalog(self, tmp_path: Path) -> None:
        """Scaffolding a capability scenario then regenerating the catalog
        produces a catalog entry under the correct capability node."""
        _setup_chart_test_dir(tmp_path)
        scenarios_dir = tmp_path / "chart-test" / "scenarios"

        # Scaffold a capability scenario
        result = _scaffold_integration(
            tmp_path,
            "capability/my-custom-check",
            project_dir=str(tmp_path),
        )
        assert result.exit_code == 0, f"new command failed: {result.stderr}"

        # Verify the scaffolded scenario file exists on disk
        scaffolded = scenarios_dir / "capability" / "capability-my-custom-check.yaml"
        assert scaffolded.is_file(), f"scaffolded scenario not found at {scaffolded}"

        # Regenerate catalog — should contain the new scenario
        catalog = generate_catalog(scenarios_dir)
        cap_entries = catalog.get("capability", {}).get("my-custom-check", [])
        cap_ids = {e["id"] for e in cap_entries}
        assert "capability-my-custom-check" in cap_ids, (
            "newly scaffolded capability must appear in catalog under capability/my-custom-check"
        )

    def test_no_hand_edited_registry_required(self, tmp_path: Path) -> None:
        """The catalog is generated purely from the scenarios tree — no
        manual edit to any registry/catalog file is needed between
        scaffolding and catalog regeneration."""
        _setup_chart_test_dir(tmp_path)
        scenarios_dir = tmp_path / "chart-test" / "scenarios"

        # Scaffold
        result = _scaffold_integration(
            tmp_path,
            "certificates/cert-manager",
            project_dir=str(tmp_path),
        )
        assert result.exit_code == 0

        # Generate catalog directly from scenarios — no intermediate
        # registry file should be required
        catalog = generate_catalog(scenarios_dir)

        # Verify the new scenario is in the catalog
        cert_entries = catalog.get("certificates", {}).get("cert-manager", [])
        cert_ids = {e["id"] for e in cert_entries}
        assert "certificates-cert-manager" in cert_ids

        # There must be no hand-edited catalog file on disk that we read
        # from — the catalog is derived purely from the scenario YAMLs
        catalog_file = tmp_path / "chart-test" / "catalog.yaml"
        assert not catalog_file.exists(), (
            "no hand-edited catalog.yaml should be required; catalog is derived from scenario YAMLs"
        )

    def test_catalog_entry_maps_scenario_to_correct_paths(self, tmp_path: Path) -> None:
        """The catalog entry for the new scenario maps its id to the correct
        category/integration node with correct path references."""
        _setup_chart_test_dir(tmp_path)
        scenarios_dir = tmp_path / "chart-test" / "scenarios"

        # Scaffold
        result = _scaffold_integration(
            tmp_path,
            "certificates/cert-manager",
            project_dir=str(tmp_path),
        )
        assert result.exit_code == 0

        catalog = generate_catalog(scenarios_dir)
        cert_entries = catalog.get("certificates", {}).get("cert-manager", [])
        new_entry = None
        for e in cert_entries:
            if e["id"] == "certificates-cert-manager":
                new_entry = e
                break

        assert new_entry is not None, "entry for new scenario must exist in catalog"
        # The path field must point at the scenario YAML
        assert new_entry["path"].endswith(".yaml")
        # The path must resolve on disk
        resolved = scenarios_dir / new_entry["path"]
        assert resolved.is_file(), f"catalog path {resolved} must resolve on disk"


# ---------------------------------------------------------------------------
# VAL-KIT-007: new test appears on dashboard support matrix with
#   no manual edit
# ---------------------------------------------------------------------------


class TestAutoRegisterInMatrix:
    """VAL-KIT-007: After regenerating the dashboard against a reports/
    including the new scenario, the support matrix contains a cell/row
    for the new test keyed by category/capability."""

    def test_new_integration_scenario_appears_in_support_matrix(self, tmp_path: Path) -> None:
        """After scaffolding a new integration scenario and rebuilding the
        dashboard, the support matrix contains a cell/row for it."""
        _setup_chart_test_dir(tmp_path)
        scenarios_dir = tmp_path / "chart-test" / "scenarios"
        reports_dir = tmp_path / "reports"
        out_dir = tmp_path / "dist"

        # Pre-existing scenario with a run result
        _write_scenario(
            scenarios_dir,
            "networking",
            "traefik-basic.yaml",
            scenario_id="traefik-basic",
            integration="traefik",
            tier="live",
        )
        _write_run_result(reports_dir, "run-001", "traefik-basic", status="PASS")

        # Scaffold a new integration scenario
        result = _scaffold_integration(
            tmp_path,
            "certificates/cert-manager",
            project_dir=str(tmp_path),
        )
        assert result.exit_code == 0, f"new command failed: {result.stderr}"

        # Write a run result for the new scenario too
        _write_run_result(reports_dir, "run-001", "certificates-cert-manager", status="PASS")

        # Build dashboard — should include the new scenario in the support matrix
        exit_code = _build_dashboard(reports_dir, scenarios_dir, out_dir)
        assert exit_code == 0

        sm_path = out_dir / "support-matrix.html"
        assert sm_path.is_file(), "support-matrix.html must exist after build"
        sm_html = sm_path.read_text(encoding="utf-8")

        # The new scenario id must appear in the support matrix
        assert "certificates-cert-manager" in sm_html, (
            "newly scaffolded integration scenario must appear in support matrix "
            "after a single rebuild"
        )

    def test_new_capability_scenario_appears_in_support_matrix(self, tmp_path: Path) -> None:
        """After scaffolding a new capability scenario and rebuilding the
        dashboard, the support matrix contains a cell/row for it."""
        _setup_chart_test_dir(tmp_path)
        scenarios_dir = tmp_path / "chart-test" / "scenarios"
        reports_dir = tmp_path / "reports"
        out_dir = tmp_path / "dist"

        # Scaffold a new capability scenario
        result = _scaffold_integration(
            tmp_path,
            "capability/my-compliance-check",
            project_dir=str(tmp_path),
        )
        assert result.exit_code == 0

        # Write a run result for the capability scenario
        _write_run_result(reports_dir, "run-001", "capability-my-compliance-check", status="PASS")

        # Build dashboard
        exit_code = _build_dashboard(reports_dir, scenarios_dir, out_dir)
        assert exit_code == 0

        sm_html = (out_dir / "support-matrix.html").read_text(encoding="utf-8")
        assert "capability-my-compliance-check" in sm_html, (
            "newly scaffolded capability scenario must appear in support matrix"
        )

    def test_new_scenario_appears_with_no_manual_dashboard_edit(self, tmp_path: Path) -> None:
        """The new scenario appears in the support matrix after a single
        rebuild with no manual edit to any dashboard/matrix config."""
        _setup_chart_test_dir(tmp_path)
        scenarios_dir = tmp_path / "chart-test" / "scenarios"
        reports_dir = tmp_path / "reports"
        out_dir = tmp_path / "dist"

        # Scaffold
        result = _scaffold_integration(
            tmp_path,
            "certificates/cert-manager",
            project_dir=str(tmp_path),
        )
        assert result.exit_code == 0

        # No reports — the scenario will show as UNTESTED in the matrix
        # but it must still appear as a row/cell.
        exit_code = _build_dashboard(reports_dir, scenarios_dir, out_dir)
        assert exit_code == 0

        sm_html = (out_dir / "support-matrix.html").read_text(encoding="utf-8")
        assert "certificates-cert-manager" in sm_html, (
            "new scenario must appear in support matrix even without run results"
        )

    def test_support_matrix_shows_new_scenario_in_correct_category(self, tmp_path: Path) -> None:
        """The support matrix places the new scenario under the correct
        category/capability grouping."""
        _setup_chart_test_dir(tmp_path)
        scenarios_dir = tmp_path / "chart-test" / "scenarios"
        reports_dir = tmp_path / "reports"
        out_dir = tmp_path / "dist"

        # Scaffold integration
        result = _scaffold_integration(
            tmp_path,
            "certificates/cert-manager",
            project_dir=str(tmp_path),
        )
        assert result.exit_code == 0

        # Build dashboard
        exit_code = _build_dashboard(reports_dir, scenarios_dir, out_dir)
        assert exit_code == 0

        sm_html = (out_dir / "support-matrix.html").read_text(encoding="utf-8")

        # The support matrix must reference "certificates" as the category
        # and "cert-manager" as the integration
        assert "certificates" in sm_html
        assert "cert-manager" in sm_html


# ---------------------------------------------------------------------------
# VAL-KIT-015: catalog is derived from scenarios, not hand-maintained
# ---------------------------------------------------------------------------


class TestCatalogPureFunction:
    """VAL-KIT-015: Deleting/regenerating the catalog from the scenarios
    tree reproduces the same catalog content (modulo timestamps), proving
    the catalog is a pure function of scenarios + primers.  Adding a
    scenario and rebuilding changes the catalog deterministically; no
    other input is required."""

    def test_regenerating_twice_yields_byte_identical_output(self, tmp_path: Path) -> None:
        """Regenerating the catalog twice yields byte-identical output
        (minus the timestamp line)."""
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
            "networking",
            "traefik-basic.yaml",
            scenario_id="traefik-basic",
            integration="traefik",
            tier="live",
        )

        catalog_a = generate_catalog(scenarios_dir)
        catalog_b = generate_catalog(scenarios_dir)
        yaml_a = catalog_to_yaml(catalog_a)
        yaml_b = catalog_to_yaml(catalog_b)

        # Strip timestamp lines
        body_a = "\n".join(
            line for line in yaml_a.splitlines() if not line.startswith("# Generated at")
        )
        body_b = "\n".join(
            line for line in yaml_b.splitlines() if not line.startswith("# Generated at")
        )
        assert body_a == body_b, "double regeneration must yield byte-identical output"

    def test_adding_one_scenario_is_only_delta(self, tmp_path: Path) -> None:
        """Adding a single scenario and regenerating the catalog changes
        the catalog deterministically — the new entry is the only delta."""
        scenarios_dir = tmp_path / "scenarios"

        # Baseline: two scenarios
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

        catalog_before = generate_catalog(scenarios_dir)

        # Add one new scenario
        _write_scenario(
            scenarios_dir,
            "networking",
            "traefik-advanced.yaml",
            scenario_id="traefik-advanced",
            integration="traefik",
            tier="live",
        )

        catalog_after = generate_catalog(scenarios_dir)

        # Flatten scenario IDs before and after
        def _flatten_ids(catalog: dict) -> set[str]:
            ids: set[str] = set()
            for integrations in catalog.values():
                for entries in integrations.values():
                    for entry in entries:
                        ids.add(entry["id"])
            return ids

        ids_before = _flatten_ids(catalog_before)
        ids_after = _flatten_ids(catalog_after)

        # The only new id is "traefik-advanced"
        diff = ids_after - ids_before
        assert diff == {"traefik-advanced"}, (
            f"only the added scenario should be new in the catalog, got: {diff}"
        )

        # No existing ids should have been removed
        assert ids_before.issubset(ids_after)

    def test_catalog_deletion_and_regeneration_reproduces_same(self, tmp_path: Path) -> None:
        """Deleting a catalog file and regenerating reproduces the same
        content (modulo timestamps)."""
        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "networking",
            "traefik-basic.yaml",
            scenario_id="traefik-basic",
            integration="traefik",
            tier="live",
        )

        # Generate and write catalog
        catalog_1 = generate_catalog(scenarios_dir)
        yaml_1 = catalog_to_yaml(catalog_1)
        catalog_file = tmp_path / "catalog.yaml"
        catalog_file.write_text(yaml_1, encoding="utf-8")

        # Delete the catalog file
        catalog_file.unlink()
        assert not catalog_file.exists()

        # Regenerate from scratch
        catalog_2 = generate_catalog(scenarios_dir)
        yaml_2 = catalog_to_yaml(catalog_2)

        # Bodies must be identical (minus timestamp)
        body_1 = "\n".join(
            line for line in yaml_1.splitlines() if not line.startswith("# Generated at")
        )
        body_2 = "\n".join(
            line for line in yaml_2.splitlines() if not line.startswith("# Generated at")
        )
        assert body_1 == body_2, (
            "regenerating after deletion must reproduce the same catalog content"
        )

    def test_catalog_is_pure_function_no_external_inputs(self, tmp_path: Path) -> None:
        """The catalog generation takes only the scenarios_dir (and optionally
        reports_dir) as inputs — no external state, no hand-maintained list."""
        scenarios_dir = tmp_path / "scenarios"
        _write_scenario(
            scenarios_dir,
            "capability",
            "baseline-deploy.yaml",
            scenario_id="baseline-deploy",
            capability="baseline-deploy",
            tier="capability",
        )

        # Generate the catalog twice with the same inputs
        cat1 = generate_catalog(scenarios_dir)
        cat2 = generate_catalog(scenarios_dir)

        # Must be identical (catalog is a pure function)
        assert cat1 == cat2, "catalog generation must be a pure function of its inputs"

    def test_new_scenario_catalog_determinism_after_scaffold(self, tmp_path: Path) -> None:
        """After scaffolding a new scenario via the ``new`` command, the
        catalog is deterministic — regenerating twice yields byte-identical
        output."""
        _setup_chart_test_dir(tmp_path)
        scenarios_dir = tmp_path / "chart-test" / "scenarios"

        # Scaffold
        result = _scaffold_integration(
            tmp_path,
            "certificates/cert-manager",
            project_dir=str(tmp_path),
        )
        assert result.exit_code == 0

        # Generate twice
        catalog_a = generate_catalog(scenarios_dir)
        catalog_b = generate_catalog(scenarios_dir)
        yaml_a = catalog_to_yaml(catalog_a)
        yaml_b = catalog_to_yaml(catalog_b)

        body_a = "\n".join(
            line for line in yaml_a.splitlines() if not line.startswith("# Generated at")
        )
        body_b = "\n".join(
            line for line in yaml_b.splitlines() if not line.startswith("# Generated at")
        )
        assert body_a == body_b, (
            "catalog must be deterministic even after scaffolding a new scenario"
        )


# ---------------------------------------------------------------------------
# End-to-end integration: new → catalog → support matrix in one flow
# ---------------------------------------------------------------------------


class TestEndToEndAutoRegistration:
    """End-to-end: scaffold with ``new``, regenerate catalog, rebuild
    dashboard — the new test auto-registers in both catalog and
    support matrix with zero manual edits."""

    def test_new_to_catalog_to_matrix_integration_flow(self, tmp_path: Path) -> None:
        """Full flow: scaffold → catalog contains entry → matrix has cell."""
        _setup_chart_test_dir(tmp_path)
        scenarios_dir = tmp_path / "chart-test" / "scenarios"
        reports_dir = tmp_path / "reports"
        out_dir = tmp_path / "dist"

        # Pre-existing scenario
        _write_scenario(
            scenarios_dir,
            "networking",
            "traefik-basic.yaml",
            scenario_id="traefik-basic",
            integration="traefik",
            tier="live",
        )
        _write_run_result(reports_dir, "run-001", "traefik-basic", status="PASS")

        # Step 1: Scaffold a new integration scenario
        result = _scaffold_integration(
            tmp_path,
            "certificates/cert-manager",
            project_dir=str(tmp_path),
        )
        assert result.exit_code == 0, f"Step 1 (new) failed: {result.stderr}"

        # Step 2: Regenerate catalog — verify new scenario is present
        catalog = generate_catalog(scenarios_dir)
        cert_entries = catalog.get("certificates", {}).get("cert-manager", [])
        cert_ids = {e["id"] for e in cert_entries}
        assert "certificates-cert-manager" in cert_ids, (
            "Step 2 (catalog): new scenario must appear in catalog"
        )

        # Step 3: Write a run result for the new scenario
        _write_run_result(reports_dir, "run-001", "certificates-cert-manager", status="PASS")

        # Step 4: Build dashboard — verify new scenario in support matrix
        exit_code = _build_dashboard(reports_dir, scenarios_dir, out_dir)
        assert exit_code == 0, "Step 4 (dashboard build) failed"

        sm_html = (out_dir / "support-matrix.html").read_text(encoding="utf-8")
        assert "certificates-cert-manager" in sm_html, (
            "Step 4 (matrix): new scenario must appear in support matrix"
        )

        # Step 5: Verify determinism — regenerate catalog twice
        yaml_a = catalog_to_yaml(generate_catalog(scenarios_dir))
        yaml_b = catalog_to_yaml(generate_catalog(scenarios_dir))
        body_a = "\n".join(
            line for line in yaml_a.splitlines() if not line.startswith("# Generated at")
        )
        body_b = "\n".join(
            line for line in yaml_b.splitlines() if not line.startswith("# Generated at")
        )
        assert body_a == body_b, "Step 5 (determinism): catalog must be deterministic"

    def test_new_capability_to_catalog_to_matrix_flow(self, tmp_path: Path) -> None:
        """Full flow for capability: scaffold → catalog → matrix."""
        _setup_chart_test_dir(tmp_path)
        scenarios_dir = tmp_path / "chart-test" / "scenarios"
        reports_dir = tmp_path / "reports"
        out_dir = tmp_path / "dist"

        # Scaffold a capability scenario
        result = _scaffold_integration(
            tmp_path,
            "capability/extra-labels",
            project_dir=str(tmp_path),
        )
        assert result.exit_code == 0, f"Scaffold failed: {result.stderr}"

        # Catalog contains the capability entry
        catalog = generate_catalog(scenarios_dir)
        cap_entries = catalog.get("capability", {}).get("extra-labels", [])
        cap_ids = {e["id"] for e in cap_entries}
        assert "capability-extra-labels" in cap_ids, "catalog must contain the capability entry"

        # Build dashboard with a run result
        _write_run_result(reports_dir, "run-001", "capability-extra-labels", status="PASS")
        exit_code = _build_dashboard(reports_dir, scenarios_dir, out_dir)
        assert exit_code == 0

        sm_html = (out_dir / "support-matrix.html").read_text(encoding="utf-8")
        assert "capability-extra-labels" in sm_html, (
            "capability scenario must appear in support matrix"
        )

    def test_three_way_consistency_after_new(self, tmp_path: Path) -> None:
        """After scaffolding via ``new``, on-disk scenarios ≡ catalog
        scenarios ≡ support-matrix scenarios (three-way consistency)."""
        _setup_chart_test_dir(tmp_path)
        scenarios_dir = tmp_path / "chart-test" / "scenarios"
        reports_dir = tmp_path / "reports"
        out_dir = tmp_path / "dist"

        # Pre-existing + new
        _write_scenario(
            scenarios_dir,
            "networking",
            "traefik-basic.yaml",
            scenario_id="traefik-basic",
            integration="traefik",
            tier="live",
        )
        _write_run_result(reports_dir, "run-001", "traefik-basic", status="PASS")

        result = _scaffold_integration(
            tmp_path,
            "certificates/cert-manager",
            project_dir=str(tmp_path),
        )
        assert result.exit_code == 0

        _write_run_result(reports_dir, "run-001", "certificates-cert-manager", status="PASS")

        # On-disk ids
        on_disk_ids: set[str] = set()
        for p in scenarios_dir.rglob("*.yaml"):
            if p.is_file() and p.parent != scenarios_dir:
                doc = yaml.safe_load(p.read_text(encoding="utf-8"))
                if isinstance(doc, dict) and "id" in doc:
                    on_disk_ids.add(doc["id"])

        # Catalog ids
        catalog = generate_catalog(scenarios_dir)
        catalog_ids: set[str] = set()
        for integrations in catalog.values():
            for entries in integrations.values():
                for entry in entries:
                    catalog_ids.add(entry["id"])

        # Support matrix ids (from HTML)
        exit_code = _build_dashboard(reports_dir, scenarios_dir, out_dir)
        assert exit_code == 0
        sm_html = (out_dir / "support-matrix.html").read_text(encoding="utf-8")

        # Every catalog id must be in the support matrix HTML
        for sid in catalog_ids:
            assert sid in sm_html, f"catalog scenario '{sid}' missing from support matrix"

        # On-disk ≡ catalog (every scenario file produces a catalog entry)
        assert on_disk_ids == catalog_ids, f"on-disk ({on_disk_ids}) ≠ catalog ({catalog_ids})"
