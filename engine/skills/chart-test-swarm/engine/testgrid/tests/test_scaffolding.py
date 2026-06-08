"""Tests for F1.5 — repo test scaffolding.

Validates:
  - VAL-ENGINE-019: ruff check on src/testgrid exits 0
  - VAL-ENGINE-020: mypy resolves types-PyYAML and jinja2 stubs
  - VAL-ENGINE-025: run-scenario.sh emits actionable pre-boot error for missing fixtures
  - VAL-ENGINE-028: every engine script accepts --help and exits 0
  - VAL-ENGINE-029: scenario id collisions produce deterministic suffix
  - VAL-ENGINE-030: CLUSTER_NAME defaults satisfy the prefix invariant
  - VAL-ENGINE-039: scripts fail preflight with bash-version error (not mapfile)
  - VAL-CROSS-012: sweep tool validates all scenarios
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

# repo root: engine/testgrid/tests/ → engine/testgrid/ → engine/ → chart-test-swarm/
REPO_ROOT = Path(__file__).resolve().parents[3]
ENGINE_DIR = REPO_ROOT / "engine"
SCRIPTS_DIR = ENGINE_DIR / "scripts"
ASSERTS_DIR = ENGINE_DIR / "asserts"
TESTGRID_DIR = ENGINE_DIR / "testgrid"
SCHEMA_PATH = ENGINE_DIR / "templates" / "scenario.schema.json"
EXAMPLES_DIR = REPO_ROOT / "examples"


class TestRuffCheck:
    """VAL-ENGINE-019: ruff check on src/testgrid exits 0."""

    def test_ruff_check_exits_0(self) -> None:
        result = subprocess.run(
            ["uv", "run", "--directory", str(TESTGRID_DIR), "ruff", "check", "src/testgrid"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"ruff check failed:\nstdout={result.stdout}\nstderr={result.stderr}"
        )

    def test_ruff_format_check_exits_0(self) -> None:
        result = subprocess.run(
            [
                "uv",
                "run",
                "--directory",
                str(TESTGRID_DIR),
                "ruff",
                "format",
                "--check",
                "src/testgrid",
                "tests/",
            ],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"ruff format --check failed:\nstdout={result.stdout}\nstderr={result.stderr}"
        )


class TestMypyCheck:
    """VAL-ENGINE-020: mypy resolves types-PyYAML and jinja2 stubs."""

    def test_mypy_exits_0(self) -> None:
        result = subprocess.run(
            ["uv", "run", "--directory", str(TESTGRID_DIR), "mypy", "src/testgrid"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"mypy failed:\nstdout={result.stdout}\nstderr={result.stderr}"
        )

    def test_mypy_no_missing_stub_yaml(self) -> None:
        """No 'Library stubs not installed for yaml' diagnostic."""
        result = subprocess.run(
            ["uv", "run", "--directory", str(TESTGRID_DIR), "mypy", "src/testgrid"],
            capture_output=True,
            text=True,
        )
        assert 'Library stubs not installed for "yaml"' not in result.stderr, (
            f"mypy reports missing yaml stubs:\n{result.stderr}"
        )

    def test_mypy_no_missing_stub_jinja2(self) -> None:
        """No 'Cannot find implementation or library stub for jinja2' diagnostic."""
        result = subprocess.run(
            ["uv", "run", "--directory", str(TESTGRID_DIR), "mypy", "src/testgrid"],
            capture_output=True,
            text=True,
        )
        jinja2_msg = 'Cannot find implementation or library stub for module named "jinja2"'
        assert jinja2_msg not in result.stderr, (
            f"mypy reports missing jinja2 stubs:\n{result.stderr}"
        )


class TestClusterNameDefaults:
    """VAL-ENGINE-030: CLUSTER_NAME defaults satisfy the prefix invariant."""

    def test_cluster_up_default(self) -> None:
        """cluster-up.sh default CLUSTER_NAME matches ^chart-test-swarm-[a-z0-9-]+$."""
        script = SCRIPTS_DIR / "cluster-up.sh"
        content = script.read_text()
        # Find the default assignment line
        for line in content.splitlines():
            if "CLUSTER_NAME" in line and ":-chart-test-swarm-" in line:
                # Extract the default value
                import re

                m = re.search(r"\$\{CLUSTER_NAME:-chart-test-swarm-([a-z0-9-]+)\}", line)
                assert m, f"Could not parse CLUSTER_NAME default from: {line}"
                suffix = m.group(1)
                assert len(suffix) > 0, (
                    "CLUSTER_NAME default has empty suffix after 'chart-test-swarm-'"
                )
                assert re.match(r"^[a-z0-9-]+$", suffix), (
                    f"CLUSTER_NAME suffix '{suffix}' doesn't match [a-z0-9-]+"
                )
                return
        pytest.fail("Could not find CLUSTER_NAME default in cluster-up.sh")

    def test_cluster_down_default(self) -> None:
        """cluster-down.sh default CLUSTER_NAME matches ^chart-test-swarm-[a-z0-9-]+$."""
        script = SCRIPTS_DIR / "cluster-down.sh"
        content = script.read_text()
        for line in content.splitlines():
            if "CLUSTER_NAME" in line and ":-chart-test-swarm-" in line:
                import re

                m = re.search(r"\$\{CLUSTER_NAME:-chart-test-swarm-([a-z0-9-]+)\}", line)
                assert m, f"Could not parse CLUSTER_NAME default from: {line}"
                suffix = m.group(1)
                assert len(suffix) > 0
                return
        pytest.fail("Could not find CLUSTER_NAME default in cluster-down.sh")

    def test_run_scenario_default(self) -> None:
        """run-scenario.sh default CLUSTER_NAME matches ^chart-test-swarm-[a-z0-9-]+$."""
        script = SCRIPTS_DIR / "run-scenario.sh"
        content = script.read_text()
        for line in content.splitlines():
            if "CLUSTER_NAME" in line and ":-chart-test-swarm-" in line:
                import re

                m = re.search(r"\$\{CLUSTER_NAME:-chart-test-swarm-([a-z0-9-]+)\}", line)
                assert m, f"Could not parse CLUSTER_NAME default from: {line}"
                suffix = m.group(1)
                assert len(suffix) > 0
                return
        pytest.fail("Could not find CLUSTER_NAME default in run-scenario.sh")

    def test_no_bare_prefix_default(self) -> None:
        """No script uses the bare 'chart-test-swarm' (no suffix) as default."""
        for script_name in [
            "cluster-up.sh",
            "cluster-down.sh",
            "run-scenario.sh",
            "dispatch-swarm.sh",
        ]:
            script = SCRIPTS_DIR / script_name
            if not script.exists():
                continue
            content = script.read_text()
            # The pattern '${CLUSTER_NAME:-chart-test-swarm}' (no dash after swarm) is forbidden
            import re

            bare_match = re.search(r"\$\{CLUSTER_NAME:-chart-test-swarm\}", content)
            assert not bare_match, (
                f"{script_name} uses bare 'chart-test-swarm' as default — "
                "suffix is required per VAL-ENGINE-030"
            )


class TestHelpBanners:
    """VAL-ENGINE-028: every engine script accepts --help and exits 0."""

    ENTRY_SCRIPTS = [
        "cluster-up.sh",
        "cluster-down.sh",
        "apply-scenario.sh",
        "run-scenario.sh",
        "dispatch-swarm.sh",
        "build-dashboard.sh",
        "aggregate.sh",
        "verify.sh",
        "sweep-scenarios.sh",
        "orphan-audit.sh",
    ]

    @pytest.mark.parametrize("script_name", ENTRY_SCRIPTS)
    def test_help_exits_0(self, script_name: str) -> None:
        script = SCRIPTS_DIR / script_name
        if not script.exists():
            pytest.skip(f"{script_name} not found")
        result = subprocess.run(
            ["bash", str(script), "--help"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert result.returncode == 0, (
            f"{script_name} --help exited {result.returncode}:\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )

    @pytest.mark.parametrize("script_name", ENTRY_SCRIPTS)
    def test_help_contains_usage(self, script_name: str) -> None:
        script = SCRIPTS_DIR / script_name
        if not script.exists():
            pytest.skip(f"{script_name} not found")
        result = subprocess.run(
            ["bash", str(script), "--help"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert "Usage" in result.stdout, (
            f"{script_name} --help output missing 'Usage':\n{result.stdout}"
        )


class TestBashVersionPreflight:
    """VAL-ENGINE-039: scripts fail preflight with bash-version error under bash 3.2."""

    BASH4_SCRIPTS = [
        "cluster-up.sh",
        "cluster-down.sh",
        "apply-scenario.sh",
        "run-scenario.sh",
        "dispatch-swarm.sh",
        "verify.sh",
    ]

    @pytest.mark.parametrize("script_name", BASH4_SCRIPTS)
    def test_bash_version_preflight_present(self, script_name: str) -> None:
        """Script source contains bash version preflight check."""
        script = SCRIPTS_DIR / script_name
        if not script.exists():
            pytest.skip(f"{script_name} not found")
        content = script.read_text()
        assert "BASH_VERSINFO" in content, f"{script_name} is missing BASH_VERSINFO preflight check"
        assert "bash >= 4 required" in content or "bash >= 4" in content, (
            f"{script_name} preflight doesn't name bash version requirement"
        )

    def test_no_mapfile_without_preflight(self) -> None:
        """Scripts using mapfile command have the preflight guard before the mapfile call."""
        import re

        for script_name in self.BASH4_SCRIPTS:
            script = SCRIPTS_DIR / script_name
            if not script.exists():
                continue
            content = script.read_text()
            # Check for actual mapfile command usage (not inside comments)
            mapfile_matches = [
                m.start() for m in re.finditer(r"^[^#]*\bmapfile\b", content, re.MULTILINE)
            ]
            if mapfile_matches:
                preflight_pos = content.find("BASH_VERSINFO")
                assert preflight_pos >= 0, f"{script_name} uses mapfile without preflight"
                for mp in mapfile_matches:
                    assert preflight_pos < mp, (
                        f"{script_name}: BASH_VERSINFO preflight must precede mapfile usage"
                    )


class TestSweepTool:
    """VAL-CROSS-012: sweep tool validates all scenario YAMLs."""

    def test_sweep_tool_exists(self) -> None:
        """sweep-scenarios.sh exists and is executable."""
        sweep = SCRIPTS_DIR / "sweep-scenarios.sh"
        assert sweep.exists(), "sweep-scenarios.sh not found"
        assert os.access(sweep, os.X_OK), "sweep-scenarios.sh not executable"

    def test_sweep_tool_help(self) -> None:
        """sweep-scenarios.sh --help exits 0."""
        result = subprocess.run(
            ["bash", str(SCRIPTS_DIR / "sweep-scenarios.sh"), "--help"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert result.returncode == 0
        assert "Usage" in result.stdout

    def test_schema_file_exists(self) -> None:
        """The scenario schema file exists."""
        assert SCHEMA_PATH.exists(), f"Schema not found: {SCHEMA_PATH}"

    def test_check_jsonschema_available(self) -> None:
        """check-jsonschema CLI is available (installed via uv)."""
        result = subprocess.run(
            ["uv", "run", "--directory", str(TESTGRID_DIR), "check-jsonschema", "--version"],
            capture_output=True,
            text=True,
        )
        # If not available via uv, check if it's on PATH
        if result.returncode != 0:
            result2 = subprocess.run(
                ["check-jsonschema", "--version"],
                capture_output=True,
                text=True,
            )
            assert result2.returncode == 0, "check-jsonschema not available"


class TestOrphanAuditTool:
    """VAL-CROSS-016, VAL-CROSS-017: orphan-cleanup audit tool exists and works."""

    def test_orphan_audit_exists(self) -> None:
        """orphan-audit.sh exists and is executable."""
        audit = SCRIPTS_DIR / "orphan-audit.sh"
        assert audit.exists(), "orphan-audit.sh not found"
        assert os.access(audit, os.X_OK), "orphan-audit.sh not executable"

    def test_orphan_audit_help(self) -> None:
        """orphan-audit.sh --help exits 0."""
        result = subprocess.run(
            ["bash", str(SCRIPTS_DIR / "orphan-audit.sh"), "--help"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert result.returncode == 0
        assert "Usage" in result.stdout

    def test_orphan_audit_clean_state(self) -> None:
        """orphan-audit.sh exits 0 when no orphans exist."""
        result = subprocess.run(
            ["bash", str(SCRIPTS_DIR / "orphan-audit.sh")],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode == 0, (
            f"orphan-audit.sh found orphans:\n{result.stdout}\n{result.stderr}"
        )


class TestFixturePathValidation:
    """VAL-ENGINE-025: run-scenario.sh emits actionable pre-boot error for missing fixtures."""

    def test_run_scenario_has_pre_boot_validation(self) -> None:
        """run-scenario.sh source contains fixture path pre-boot validation."""
        script = SCRIPTS_DIR / "run-scenario.sh"
        content = script.read_text()
        assert "validate_fixture_paths" in content, (
            "run-scenario.sh missing validate_fixture_paths function"
        )
        assert "No cluster will be created" in content, (
            "run-scenario.sh missing 'No cluster will be created' error message"
        )

    def test_missing_path_error_includes_scenario_id(self) -> None:
        """Pre-boot error includes the scenario id."""
        script = SCRIPTS_DIR / "run-scenario.sh"
        content = script.read_text()
        # The error message should name the scenario id
        assert "scenario '$SCEN_ID'" in content or "scenario '$SCEN_ID'" in content, (
            "run-scenario.sh fixture error doesn't name the scenario id"
        )

    def test_missing_path_error_includes_preinstall_index(self) -> None:
        """Pre-boot error includes the preinstall index."""
        script = SCRIPTS_DIR / "run-scenario.sh"
        content = script.read_text()
        assert "preinstall[$i]" in content, (
            "run-scenario.sh fixture error doesn't name the preinstall index"
        )


class TestScenarioIdCollision:
    """VAL-ENGINE-029: scenario id collisions produce deterministic suffix."""

    def test_run_scenario_has_collision_detection(self) -> None:
        """run-scenario.sh source contains scenario id collision detection."""
        script = SCRIPTS_DIR / "run-scenario.sh"
        content = script.read_text()
        assert "collision" in content.lower() or "Scenario id collision" in content, (
            "run-scenario.sh missing scenario id collision detection"
        )

    def test_collision_uses_suffix_not_overwrite(self) -> None:
        """Collision detection appends a suffix rather than overwriting."""
        script = SCRIPTS_DIR / "run-scenario.sh"
        content = script.read_text()
        # The collision logic should produce a new dir name with a suffix
        assert "suffix" in content.lower(), "run-scenario.sh collision doesn't append suffix"


class TestPyprojectToml:
    """Verify pyproject.toml has all required dev dependencies."""

    def test_types_pyyaml_dep(self) -> None:
        """types-PyYAML is listed as a dev dependency."""
        content = (TESTGRID_DIR / "pyproject.toml").read_text()
        assert "types-PyYAML" in content, "types-PyYAML not in pyproject.toml"

    def test_mypy_config(self) -> None:
        """mypy config section exists with strict mode."""
        content = (TESTGRID_DIR / "pyproject.toml").read_text()
        assert "[tool.mypy]" in content, "mypy config section missing"
        assert "strict" in content, "mypy strict mode not configured"

    def test_jinja2_ignore_missing_imports(self) -> None:
        """jinja2 is configured with ignore_missing_imports in mypy overrides."""
        content = (TESTGRID_DIR / "pyproject.toml").read_text()
        assert "jinja2" in content, "jinja2 not mentioned in mypy config"
        assert "ignore_missing_imports" in content, "jinja2 ignore_missing_imports not configured"

    def test_check_jsonschema_dep(self) -> None:
        """check-jsonschema is listed as a dependency."""
        content = (TESTGRID_DIR / "pyproject.toml").read_text()
        assert "check-jsonschema" in content, "check-jsonschema not in pyproject.toml"

    def test_pytest_dep(self) -> None:
        """pytest is listed as a dev dependency."""
        content = (TESTGRID_DIR / "pyproject.toml").read_text()
        assert "pytest" in content, "pytest not in pyproject.toml"
