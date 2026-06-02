"""Tests for F14.1 — ``chart-test-swarm new`` scaffolding command.

Validates the assertions VAL-KIT-001 through VAL-KIT-016 (selected ones):
  - VAL-KIT-001: new <integration> scaffolds fixture + scenario + smoke script
  - VAL-KIT-002: new capability/<name> scaffolds addon-less capability test
  - VAL-KIT-003: every generated scenario validates against schema
  - VAL-KIT-004: scenarios self-describe placement (category/tier/etc.)
  - VAL-KIT-005: taxonomy-incorrect category is rejected
  - VAL-KIT-008: no-primer integration is refused, available primers listed
  - VAL-KIT-013: no-clobber on existing ids without --force
  - VAL-KIT-014: --dry-run writes nothing, lists prospective paths
  - VAL-KIT-016: tier defaults per kind
"""

from __future__ import annotations

import stat
import subprocess
from pathlib import Path

import pytest
import yaml
from typer.testing import CliRunner

from chart_test_swarm.main import app

# ── Paths ──────────────────────────────────────────────────────────────────

REPO_ROOT = Path(__file__).resolve().parents[3]
SCHEMA_PATH = REPO_ROOT / "engine" / "templates" / "scenario.schema.json"
INTEGRATIONS_ROOT = (
    REPO_ROOT / "engine" / "skills" / "chart-test-swarm" / "references" / "integrations"
)

runner = CliRunner()


# ── Helpers ────────────────────────────────────────────────────────────────


def _validate_scenario(yaml_path: Path) -> tuple[bool, str]:
    """Validate a scenario YAML against the project schema via check-jsonschema."""
    result = subprocess.run(
        [
            "uv",
            "run",
            "--directory",
            str(REPO_ROOT / "engine" / "testgrid"),
            "check-jsonschema",
            "--schemafile",
            str(SCHEMA_PATH),
            str(yaml_path),
        ],
        capture_output=True,
        text=True,
        timeout=15,
    )
    return result.returncode == 0, result.stderr + result.stdout


def _taxonomy_categories() -> set[str]:
    """Derive the set of valid categories from the integrations tree."""
    return {
        d.name for d in INTEGRATIONS_ROOT.iterdir() if d.is_dir() and not d.name.startswith(".")
    }


def _primers_for_category(category: str) -> list[str]:
    """List primer stems for a given category."""
    cat_dir = INTEGRATIONS_ROOT / category
    if not cat_dir.is_dir():
        return []
    return sorted(f.stem for f in cat_dir.glob("*.md") if f.is_file())


# ── Integration mode (VAL-KIT-001) ─────────────────────────────────────────


class TestNewIntegration:
    """VAL-KIT-001: new <category>/<integration> scaffolds fixture + scenario + smoke script."""

    def test_scaffolds_three_files(self, tmp_path: Path) -> None:
        """Scaffolding an integration with an existing primer produces three files."""
        # Use certificates/cert-manager which has a primer
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        result = runner.invoke(
            app,
            [
                "new",
                "certificates/cert-manager",
                "--project-dir",
                str(tmp_path),
            ],
        )
        assert result.exit_code == 0, f"exit={result.exit_code}, out={result.output}"

        # Check three files exist
        fixture = chart_test / "fixtures" / "certificates" / "cert-manager-values.yaml"
        scenario = chart_test / "scenarios" / "certificates" / "certificates-cert-manager.yaml"
        smoke = chart_test / "assertions" / "cert-manager-smoke.sh"

        assert fixture.exists(), f"Fixture not found: {fixture}"
        assert scenario.exists(), f"Scenario not found: {scenario}"
        assert smoke.exists(), f"Smoke script not found: {smoke}"

    def test_chart_values_yaml_untouched(self, tmp_path: Path) -> None:
        """The chart's values.yaml must not be modified."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        # Create a chart/values.yaml
        chart_dir = tmp_path / "chart"
        chart_dir.mkdir()
        values_yaml = chart_dir / "values.yaml"
        original = "# my original values\nreplicaCount: 1\n"
        values_yaml.write_text(original)

        runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )

        assert values_yaml.read_text() == original, "chart values.yaml was modified!"

    def test_smoke_script_is_executable(self, tmp_path: Path) -> None:
        """The scaffolded smoke script must have the executable bit set."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )

        smoke = chart_test / "assertions" / "cert-manager-smoke.sh"
        assert smoke.exists()
        mode = smoke.stat().st_mode
        assert mode & stat.S_IXUSR, f"Smoke script not executable: {oct(mode)}"


# ── Capability mode (VAL-KIT-002) ──────────────────────────────────────────


class TestNewCapability:
    """VAL-KIT-002: new capability/<name> scaffolds addon-less capability test."""

    def test_scaffolds_fixture_and_scenario(self, tmp_path: Path) -> None:
        """Scaffolding a capability produces fixture + scenario (no smoke script needed)."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        result = runner.invoke(
            app,
            ["new", "capability/my-custom-check", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code == 0, f"exit={result.exit_code}, out={result.output}"

        fixture = chart_test / "fixtures" / "capability" / "my-custom-check-values.yaml"
        scenario = chart_test / "scenarios" / "capability" / "capability-my-custom-check.yaml"

        assert fixture.exists(), f"Fixture not found: {fixture}"
        assert scenario.exists(), f"Scenario not found: {scenario}"

    def test_scenario_has_capability_assert(self, tmp_path: Path) -> None:
        """Capability scenario references a §10.4 capability assert type."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        runner.invoke(
            app,
            ["new", "capability/my-custom-check", "--project-dir", str(tmp_path)],
        )

        scenario = chart_test / "scenarios" / "capability" / "capability-my-custom-check.yaml"
        doc = yaml.safe_load(scenario.read_text())

        # Asserts must include at least one capability-assert type
        capability_types = {
            "labels-present",
            "annotations-present",
            "scheme-enforced",
            "rbac-objects",
            "security-context",
            "network-policy",
            "resources-present",
            "imagepullsecrets-present",
            "serviceaccount-annotations",
            "scheduling-present",
            "priority-class-present",
        }
        assert_types = {a["type"] for a in doc.get("asserts", [])}
        assert assert_types & capability_types, (
            f"No capability assert type found in: {assert_types}"
        )

    def test_no_preinstall_addon_block(self, tmp_path: Path) -> None:
        """Capability scenario must not have a cluster.preinstall addon stanza."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        runner.invoke(
            app,
            ["new", "capability/my-custom-check", "--project-dir", str(tmp_path)],
        )

        scenario = chart_test / "scenarios" / "capability" / "capability-my-custom-check.yaml"
        doc = yaml.safe_load(scenario.read_text())

        preinstall = doc.get("cluster", {}).get("preinstall", [])
        assert preinstall == [], f"Capability scenario should have no preinstall, got: {preinstall}"


# ── Schema validation (VAL-KIT-003) ────────────────────────────────────────


class TestSchemaValidation:
    """VAL-KIT-003: every generated scenario validates against the schema."""

    def test_integration_scenario_validates(self, tmp_path: Path) -> None:
        """Integration scenario passes check-jsonschema."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )

        scenario = chart_test / "scenarios" / "certificates" / "certificates-cert-manager.yaml"
        ok, err = _validate_scenario(scenario)
        assert ok, f"Schema validation failed: {err}"

    def test_capability_scenario_validates(self, tmp_path: Path) -> None:
        """Capability scenario passes check-jsonschema."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        runner.invoke(
            app,
            ["new", "capability/my-custom-check", "--project-dir", str(tmp_path)],
        )

        scenario = chart_test / "scenarios" / "capability" / "capability-my-custom-check.yaml"
        ok, err = _validate_scenario(scenario)
        assert ok, f"Schema validation failed: {err}"


# ── Self-describing placement (VAL-KIT-004) ───────────────────────────────


class TestSelfDescribingPlacement:
    """VAL-KIT-004: scenarios self-describe placement fields."""

    def test_integration_scenario_has_category_and_integration(self, tmp_path: Path) -> None:
        """Integration scenario carries category + integration + tier."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )

        scenario = chart_test / "scenarios" / "certificates" / "certificates-cert-manager.yaml"
        doc = yaml.safe_load(scenario.read_text())

        cat = doc.get("category")
        integ = doc.get("integration")
        assert cat == "certificates", f"Wrong category: {cat}"
        assert integ == "cert-manager", f"Wrong integration: {integ}"
        assert "tier" in doc, "Missing tier field"
        assert "capability" not in doc, "Integration scenario must NOT have 'capability' field"

    def test_capability_scenario_has_category_and_capability(self, tmp_path: Path) -> None:
        """Capability scenario carries category + capability + tier."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        runner.invoke(
            app,
            ["new", "capability/my-custom-check", "--project-dir", str(tmp_path)],
        )

        scenario = chart_test / "scenarios" / "capability" / "capability-my-custom-check.yaml"
        doc = yaml.safe_load(scenario.read_text())

        cat = doc.get("category")
        cap = doc.get("capability")
        assert cat == "capability", f"Wrong category: {cat}"
        assert cap == "my-custom-check", f"Wrong capability: {cap}"
        assert "tier" in doc, "Missing tier field"
        assert "integration" not in doc, "Capability scenario must NOT have 'integration' field"


# ── Taxonomy category enforcement (VAL-KIT-005) ────────────────────────────


class TestTaxonomyCategoryEnforcement:
    """VAL-KIT-005: category outside the taxonomy is rejected before any file is written."""

    def test_invalid_category_rejected(self, tmp_path: Path) -> None:
        """An unknown category is rejected before any scaffolding."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        result = runner.invoke(
            app,
            ["new", "nonexistent-category/some-integration", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code != 0, f"Expected non-zero exit, got {result.exit_code}"
        # No files should be written
        scenario_files = list((chart_test / "scenarios").rglob("*.yaml"))
        assert scenario_files == [], (
            f"Files were written despite invalid category: {scenario_files}"
        )

    def test_error_mentions_invalid_category(self, tmp_path: Path) -> None:
        """Error message references the invalid category."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        result = runner.invoke(
            app,
            ["new", "nonexistent-category/some-integration", "--project-dir", str(tmp_path)],
        )
        combined = result.output + (result.stderr or "")
        assert "nonexistent-category" in combined.lower(), (
            f"Error should name the invalid category, got: {combined}"
        )


# ── No-primer refusal (VAL-KIT-008) ────────────────────────────────────────


class TestNoPrimerRefusal:
    """VAL-KIT-008: no-primer target scaffolds nothing, lists available primers."""

    def test_no_primer_exits_nonzero(self, tmp_path: Path) -> None:
        """A valid category but missing primer is refused."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        # certificates is valid, but "nonexistent-primer" has no primer .md
        result = runner.invoke(
            app,
            ["new", "certificates/nonexistent-primer", "--project-dir", str(tmp_path)],
        )
        assert result.exit_code != 0, f"Expected non-zero exit, got {result.exit_code}"

    def test_no_primer_lists_available(self, tmp_path: Path) -> None:
        """The error message lists available primers for the category."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        result = runner.invoke(
            app,
            ["new", "certificates/nonexistent-primer", "--project-dir", str(tmp_path)],
        )
        combined = result.output + (result.stderr or "")
        # cert-manager, manual-tls-secret, mounted-tls-certs are the certificates primers
        assert "cert-manager" in combined, (
            f"Should list available primer cert-manager, got: {combined}"
        )

    def test_no_primer_writes_nothing(self, tmp_path: Path) -> None:
        """No files are written when there is no primer."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        runner.invoke(
            app,
            ["new", "certificates/nonexistent-primer", "--project-dir", str(tmp_path)],
        )

        all_files = list(chart_test.rglob("*"))
        real_files = [f for f in all_files if f.is_file()]
        assert real_files == [], f"Files written despite no primer: {real_files}"


# ── No-clobber (VAL-KIT-013) ──────────────────────────────────────────────


class TestNoClobber:
    """VAL-KIT-013: re-running for an existing id does not clobber without --force."""

    def test_no_clobber_exits_nonzero(self, tmp_path: Path) -> None:
        """Re-running the same id without --force exits non-zero."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        # First run: should succeed
        result1 = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )
        assert result1.exit_code == 0, f"First run failed: {result1.output}"

        # Read the original scenario content
        scenario = chart_test / "scenarios" / "certificates" / "certificates-cert-manager.yaml"
        original_bytes = scenario.read_bytes()

        # Second run: should refuse
        result2 = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )
        assert result2.exit_code != 0, f"Second run should exit non-zero: {result2.output}"

        # File should be byte-unchanged
        assert scenario.read_bytes() == original_bytes, "Scenario was clobbered!"

    def test_force_overwrites(self, tmp_path: Path) -> None:
        """With --force, the existing files are overwritten."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        # First run
        runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )

        scenario = chart_test / "scenarios" / "certificates" / "certificates-cert-manager.yaml"
        original = scenario.read_text()

        # Modify the file to prove overwrite
        scenario.write_text(original.replace("cert-manager", "MODIFIED"))

        # Second run with --force
        result = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path), "--force"],
        )
        assert result.exit_code == 0, f"--force run failed: {result.output}"

        # File should be overwritten back to the template output
        new_content = scenario.read_text()
        assert "MODIFIED" not in new_content, "File was not overwritten with --force"


# ── Dry-run (VAL-KIT-014) ─────────────────────────────────────────────────


class TestDryRun:
    """VAL-KIT-014: --dry-run writes nothing and lists prospective paths."""

    def test_dry_run_writes_nothing(self, tmp_path: Path) -> None:
        """--dry-run produces no files on disk."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        result = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path), "--dry-run"],
        )
        assert result.exit_code == 0, f"--dry-run failed: {result.output}"

        # No files should be created under chart-test/ (only the dirs we made)
        all_files = [f for f in chart_test.rglob("*") if f.is_file()]
        assert all_files == [], f"--dry-run created files: {all_files}"

    def test_dry_run_lists_paths(self, tmp_path: Path) -> None:
        """--dry-run stdout lists the prospective file paths."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        result = runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path), "--dry-run"],
        )

        output = result.output
        # Should mention at least fixture, scenario, and smoke script paths
        assert "cert-manager-values.yaml" in output, (
            f"Missing fixture path in dry-run output: {output}"
        )
        assert "certificates-cert-manager.yaml" in output, (
            f"Missing scenario path in dry-run output: {output}"
        )
        assert "cert-manager-smoke.sh" in output, (
            f"Missing smoke script path in dry-run output: {output}"
        )


# ── Tier defaults (VAL-KIT-016) ────────────────────────────────────────────


class TestTierDefaults:
    """VAL-KIT-016: tier defaults correct per kind."""

    def test_integration_defaults_to_live(self, tmp_path: Path) -> None:
        """Integration mode defaults tier to 'live'."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        runner.invoke(
            app,
            ["new", "certificates/cert-manager", "--project-dir", str(tmp_path)],
        )

        scenario = chart_test / "scenarios" / "certificates" / "certificates-cert-manager.yaml"
        doc = yaml.safe_load(scenario.read_text())
        assert doc.get("tier") == "live", f"Expected tier=live, got {doc.get('tier')}"

    def test_capability_defaults_to_capability(self, tmp_path: Path) -> None:
        """Capability mode defaults tier to 'capability'."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        runner.invoke(
            app,
            ["new", "capability/my-custom-check", "--project-dir", str(tmp_path)],
        )

        scenario = chart_test / "scenarios" / "capability" / "capability-my-custom-check.yaml"
        doc = yaml.safe_load(scenario.read_text())
        assert doc.get("tier") == "capability", f"Expected tier=capability, got {doc.get('tier')}"

    def test_cloud_native_defaults_to_authored_only(self, tmp_path: Path) -> None:
        """Cloud-native integration defaults tier to 'authored-only'."""
        chart_test = tmp_path / "chart-test"
        chart_test.mkdir()
        (chart_test / "scenarios").mkdir()
        (chart_test / "fixtures").mkdir()
        (chart_test / "assertions").mkdir()

        # cloud-native/aws-load-balancer-controller has a primer
        result = runner.invoke(
            app,
            ["new", "cloud-native/aws-load-balancer-controller", "--project-dir", str(tmp_path)],
        )
        if result.exit_code != 0:
            # If there's no primer for this, the command should refuse;
            # but if there IS a primer, check the tier
            primers = _primers_for_category("cloud-native")
            if "aws-load-balancer-controller" not in primers:
                pytest.skip("aws-load-balancer-controller primer not yet authored")
            raise AssertionError(f"Command failed unexpectedly: {result.output}")

        # Find the scenario
        scenario_files = list((chart_test / "scenarios" / "cloud-native").glob("*.yaml"))
        assert scenario_files, "No scenario files found for cloud-native"
        doc = yaml.safe_load(scenario_files[0].read_text())
        assert doc.get("tier") == "authored-only", (
            f"Expected tier=authored-only, got {doc.get('tier')}"
        )


# ── Help and basic UX ───────────────────────────────────────────────────────


class TestNewHelpAndUX:
    """Verify `new` subcommand help and basic UX."""

    def test_new_help_exits_0(self) -> None:
        """new --help exits 0."""
        result = runner.invoke(app, ["new", "--help"])
        assert result.exit_code == 0, f"exit={result.exit_code}: {result.output}"

    def test_new_help_mentions_target(self) -> None:
        """new --help mentions the <target> argument."""
        result = runner.invoke(app, ["new", "--help"])
        assert "TARGET" in result.output or "target" in result.output.lower(), (
            f"Expected TARGET in help, got:\n{result.output}"
        )

    def test_new_no_target_exits_nonzero(self) -> None:
        """new without a target argument exits non-zero."""
        result = runner.invoke(app, ["new"])
        assert result.exit_code != 0

    def test_new_force_flag_accepted(self, tmp_path: Path) -> None:
        """new --force is an accepted flag."""
        result = runner.invoke(app, ["new", "--help"])
        assert "--force" in result.output, f"Missing --force in help: {result.output}"

    def test_new_dry_run_flag_accepted(self) -> None:
        """new --dry-run is an accepted flag."""
        result = runner.invoke(app, ["new", "--help"])
        assert "--dry-run" in result.output, f"Missing --dry-run in help: {result.output}"


# ── Integration with existing list command ──────────────────────────────────


class TestNewIntegrationDiscovery:
    """Integration of `new` command with the existing primer/integration discovery."""

    def test_new_uses_same_taxonomy_as_list(self) -> None:
        """The categories used by `new` match the categories discovered by `list integrations`."""
        categories = _taxonomy_categories()
        # These are the expected categories per architecture §10.3
        expected = {
            "certificates",
            "cloud-native",
            "gateway-api",
            "ingress-controllers",
            "policy",
            "service-mesh",
        }
        # At minimum, these should be present
        assert expected.issubset(categories), f"Missing categories: {expected - categories}"

    def test_capability_is_valid_category_even_without_primer_dir(self) -> None:
        """The 'capability' category is accepted by `new` even though it has no primer dir."""
        # capability/ is a special pseudo-category; it should be valid even if
        # references/integrations/capability/ does not exist
        pass  # This is validated in TestNewCapability above
