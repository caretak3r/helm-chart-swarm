"""Tests for F9.2 — ``chart-test-swarm run`` subcommand.

Validates:
  - VAL-CLI-006: run --help exits 0, advertises --scenario, --integration, --backend, --parallelism
  - VAL-CLI-007: run --scenario <path> dispatches via dispatch-swarm.sh
  - VAL-CLI-008: run --integration <name> filters scenarios
  - VAL-CLI-009: run --backend minikube forwards backend; invalid backend rejected
  - VAL-CLI-010: run --parallelism N validation (reject 0, -1, foo)
  - VAL-CLI-014: Cluster name prefix enforcement pre-subprocess
  - VAL-CLI-018: run emits run id as last line of stdout
  - VAL-CLI-019: Missing scenario file produces clear error, no traceback
  - VAL-CLI-022: Flag->env mapping documented and verified
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from textwrap import dedent

import pytest
from typer.testing import CliRunner

from chart_test_swarm.main import app

runner = CliRunner()

REPO_ROOT = Path(__file__).resolve().parents[3]
MISSING_PATH = "/tmp/chart-test-swarm-does-not-exist-99999.yaml"


# ── Helpers ──────────────────────────────────────────────────────────────────


def _write_stub(tmp_path: Path, name: str, content: str) -> Path:
    """Write an executable stub script to *tmp_path* and return its path."""
    stub = tmp_path / name
    stub.write_text(content)
    stub.chmod(0o755)
    return stub


def _add_to_path(tmp_path: Path) -> dict[str, str]:
    """Return an env dict with *tmp_path* prepended to PATH."""
    env = os.environ.copy()
    env["PATH"] = f"{tmp_path}{os.pathsep}{env.get('PATH', '')}"
    return env


def _scenario_yaml(tmp_path: Path, name: str, tags: str | None = None) -> Path:
    """Write a minimal scenario YAML to *tmp_path*."""
    f = tmp_path / name
    tags_line = f"tags: [{tags}]" if tags else "tags: []"
    f.write_text(
        f"---\n"
        f"id: {name.replace('.yaml', '')}\n"
        f"cluster:\n  provider: kind\n"
        f"product:\n  chart: ./chart\n  release: test\n  namespace: default\n"
        f"asserts: []\n"
        f"{tags_line}\n"
    )
    return f


# ═══════════════════════════════════════════════════════════════════════════
# VAL-CLI-006: run --help
# ═══════════════════════════════════════════════════════════════════════════


class TestRunHelp:
    """VAL-CLI-006: run --help exits 0 and advertises required flags."""

    def test_help_exits_0(self) -> None:
        """run --help exits with code 0."""
        result = runner.invoke(app, ["run", "--help"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"

    def test_help_advertises_scenario(self) -> None:
        """--help mentions --scenario."""
        result = runner.invoke(app, ["run", "--help"])
        assert "--scenario" in result.stdout

    def test_help_advertises_integration(self) -> None:
        """--help mentions --integration."""
        result = runner.invoke(app, ["run", "--help"])
        assert "--integration" in result.stdout

    def test_help_advertises_backend(self) -> None:
        """--help mentions --backend."""
        result = runner.invoke(app, ["run", "--help"])
        assert "--backend" in result.stdout

    def test_help_advertises_parallelism(self) -> None:
        """--help mentions --parallelism."""
        result = runner.invoke(app, ["run", "--help"])
        assert "--parallelism" in result.stdout

    def test_help_contains_usage(self) -> None:
        """--help output contains Usage."""
        result = runner.invoke(app, ["run", "--help"])
        assert "Usage" in result.stdout


# ═══════════════════════════════════════════════════════════════════════════
# VAL-CLI-007: --scenario dispatches via dispatch-swarm.sh
# ═══════════════════════════════════════════════════════════════════════════


class TestScenarioDispatch:
    """VAL-CLI-007: run --scenario dispatches via dispatch-swarm.sh."""

    def test_stub_invoked_with_scenario(self, tmp_path: Path) -> None:
        """The PATH stub is invoked and receives the scenario path via env var."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "RUN_ID=run-stub"
                echo "CTS_SCENARIOS=$CTS_SCENARIOS"
                exit 0
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")

        env = _add_to_path(tmp_path)
        # Also set CTS_ENGINE_SCRIPTS_DIR to force resolution through PATH
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["run", "--scenario", str(scn), "--project-dir", str(tmp_path)],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "RUN_ID=run-stub" in result.stdout, f"stdout: {result.stdout}"
        assert str(scn) in result.stdout, (
            f"Expected scenario path in CTS_SCENARIOS env, got stdout: {result.stdout}"
        )

    def test_stub_exits_nonzero_propagates(self, tmp_path: Path) -> None:
        """When the stub exits non-zero, the CLI propagates the exit code."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "FAILING" >&2
                exit 3
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")
        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["run", "--scenario", str(scn), "--project-dir", str(tmp_path)],
            env=env,
        )
        assert result.exit_code == 3, f"Expected exit 3, got {result.exit_code}"
        assert "FAILING" in result.stderr


# ═══════════════════════════════════════════════════════════════════════════
# VAL-CLI-008: --integration filtering
# ═══════════════════════════════════════════════════════════════════════════


class TestIntegrationFiltering:
    """VAL-CLI-008: run --integration <name> filters scenarios."""

    def test_matching_scenarios_passed_to_stub(self, tmp_path: Path) -> None:
        """Matched scenarios appear in CTS_SCENARIOS env var."""
        # Create a project-like structure
        proj = tmp_path / "project"
        scn_dir = proj / "chart-test" / "scenarios"
        scn_dir.mkdir(parents=True)

        # chart-test-swarm.yaml
        (proj / "chart-test-swarm.yaml").write_text(
            "project:\n  name: test\nscenarios_dir: chart-test/scenarios\n"
        )

        # Create scenarios with cert-manager and nginx
        _scenario_yaml(scn_dir, "certificates-cert-manager-basic.yaml")
        _scenario_yaml(scn_dir, "certificates-cert-manager-wildcard.yaml")
        _scenario_yaml(scn_dir, "ingress-controllers-nginx-basic.yaml")

        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "CTS_SCENARIOS=$CTS_SCENARIOS"
                echo "RUN_ID=run-stub"
                exit 0
            """),
        )

        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["run", "--integration", "cert-manager", "--project-dir", str(proj)],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"

        # Both cert-manager scenarios should be in the list
        assert "cert-manager-basic" in result.stdout
        assert "cert-manager-wildcard" in result.stdout
        # The nginx scenario should NOT be in the list
        assert "nginx-basic" not in result.stdout

    def test_no_match_exits_nonzero_with_message(self, tmp_path: Path) -> None:
        """Non-matching integration exits non-zero with 'no scenarios matched'."""
        proj = tmp_path / "project"
        scn_dir = proj / "chart-test" / "scenarios"
        scn_dir.mkdir(parents=True)

        (proj / "chart-test-swarm.yaml").write_text(
            "project:\n  name: test\nscenarios_dir: chart-test/scenarios\n"
        )

        result = runner.invoke(
            app,
            ["run", "--integration", "nonexistent", "--project-dir", str(proj)],
        )
        assert result.exit_code != 0
        assert "no scenarios matched" in result.stderr.lower()


# ═══════════════════════════════════════════════════════════════════════════
# VAL-CLI-009: --backend validation
# ═══════════════════════════════════════════════════════════════════════════


class TestBackendValidation:
    """VAL-CLI-009: --backend forwarding and validation."""

    def test_backend_minikube_propagated(self, tmp_path: Path) -> None:
        """--backend minikube sets PROVIDER=minikube in env."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "PROVIDER=$PROVIDER"
                echo "RUN_ID=run-stub"
                exit 0
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")
        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            [
                "run",
                "--scenario",
                str(scn),
                "--backend",
                "minikube",
                "--project-dir",
                str(tmp_path),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "PROVIDER=minikube" in result.stdout

    def test_invalid_backend_rejected(self) -> None:
        """Invalid backend exits non-zero with enum hint."""
        result = runner.invoke(
            app,
            ["run", "--backend", "invalid-backend"],
        )
        assert result.exit_code != 0
        assert "invalid-backend" in result.stderr
        # Should mention supported backends
        assert any(b in result.stderr for b in ["kind", "minikube", "k3d"]), (
            f"Expected backend hint in stderr: {result.stderr}"
        )


# ═══════════════════════════════════════════════════════════════════════════
# VAL-CLI-010: --parallelism validation
# ═══════════════════════════════════════════════════════════════════════════


class TestParallelismValidation:
    """VAL-CLI-010: --parallelism N validation."""

    @pytest.mark.parametrize(
        "bad_value,expected_msg",
        [
            ("0", ">= 1"),
            ("-1", ">= 1"),
            ("-5", ">= 1"),
            ("foo", "positive integer"),
            ("1.5", "positive integer"),
            ("", "positive integer"),
        ],
    )
    def test_bad_parallelism_rejected(self, bad_value: str, expected_msg: str) -> None:
        """Invalid parallelism values are rejected non-zero."""
        result = runner.invoke(app, ["run", "--parallelism", bad_value])
        assert result.exit_code != 0, (
            f"Expected non-zero exit for --parallelism {bad_value}, got {result.exit_code}"
        )
        assert expected_msg in result.stderr.lower(), (
            f"Expected '{expected_msg}' for --parallelism {bad_value}, stderr: {result.stderr}"
        )

    def test_valid_parallelism_accepted(self, tmp_path: Path) -> None:
        """Valid --parallelism 2 is forwarded."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "NUM_AGENTS=$NUM_AGENTS"
                echo "RUN_ID=run-stub"
                exit 0
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")
        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            [
                "run",
                "--scenario",
                str(scn),
                "--parallelism",
                "3",
                "--project-dir",
                str(tmp_path),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "NUM_AGENTS=3" in result.stdout


# ═══════════════════════════════════════════════════════════════════════════
# VAL-CLI-014: Cluster name prefix enforcement
# ═══════════════════════════════════════════════════════════════════════════


class TestClusterNamePrefix:
    """VAL-CLI-014: cluster name prefix enforced before subprocess dispatch."""

    def test_unprefixed_name_rejected(self) -> None:
        """CLUSTER_NAME without prefix is rejected before any dispatch."""
        result = runner.invoke(
            app,
            ["run", "--cluster-name", "not-prefixed-cluster"],
        )
        assert result.exit_code != 0
        assert "not-prefixed-cluster" in result.stderr
        assert "chart-test-swarm-" in result.stderr, (
            f"Expected prefix requirement in stderr: {result.stderr}"
        )

    def test_bare_prefix_rejected(self, tmp_path: Path) -> None:
        """CLUSTER_NAME=chart-test-swarm (no suffix) is rejected."""
        result = runner.invoke(
            app,
            ["run", "--cluster-name", "chart-test-swarm"],
        )
        assert result.exit_code != 0
        assert "chart-test-swarm" in result.stderr

    def test_valid_prefix_accepted(self, tmp_path: Path) -> None:
        """CLUSTER_NAME with valid prefix is forwarded."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "CLUSTER_NAME=$CLUSTER_NAME"
                echo "RUN_ID=run-stub"
                exit 0
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")
        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            [
                "run",
                "--scenario",
                str(scn),
                "--cluster-name",
                "chart-test-swarm-test1",
                "--project-dir",
                str(tmp_path),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "CLUSTER_NAME=chart-test-swarm-test1" in result.stdout


# ═══════════════════════════════════════════════════════════════════════════
# VAL-CLI-018: RUN_ID emitted as last line
# ═══════════════════════════════════════════════════════════════════════════


class TestRunIdEmission:
    """VAL-CLI-018: run emits RUN_ID as last line of stdout."""

    def test_run_id_matches_pattern(self, tmp_path: Path) -> None:
        """Last stdout line matches ^run-[0-9]{8}-[0-9]{6}(-[0-9]+)?$."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "RUN_ID=$RUN_ID"
                exit 0
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")
        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            ["run", "--scenario", str(scn), "--project-dir", str(tmp_path)],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"

        last_line = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
        match = re.match(r"^run-\d{8}-\d{6}(-\d+)?$", last_line)
        assert match, f"Last line '{last_line}' does not match expected RUN_ID pattern"

    def test_explicit_run_id_respected(self, tmp_path: Path) -> None:
        """--run-id value is forwarded."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "RUN_ID=$RUN_ID"
                exit 0
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")
        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            [
                "run",
                "--scenario",
                str(scn),
                "--run-id",
                "run-20250101-120000-custom",
                "--project-dir",
                str(tmp_path),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        # The last line should be the explicit run id
        last_line = result.stdout.strip().splitlines()[-1]
        assert last_line == "run-20250101-120000-custom", (
            f"Expected explicit run id, got: {last_line}"
        )


# ═══════════════════════════════════════════════════════════════════════════
# VAL-CLI-019: Missing scenario — clear error, no traceback
# ═══════════════════════════════════════════════════════════════════════════


class TestMissingScenario:
    """VAL-CLI-019: missing scenario file → clear error, no Python traceback."""

    def test_missing_file_exits_nonzero(self) -> None:
        """Non-existent scenario exits non-zero quickly."""
        import time

        start = time.monotonic()
        result = runner.invoke(app, ["run", "--scenario", MISSING_PATH])
        elapsed = time.monotonic() - start

        assert result.exit_code != 0
        assert elapsed < 5.0, f"Took {elapsed:.1f}s, expected <5s"

    def test_error_names_path(self) -> None:
        """Stderr contains the literal path."""
        result = runner.invoke(app, ["run", "--scenario", MISSING_PATH])
        assert MISSING_PATH in result.stderr

    def test_error_is_actionable(self) -> None:
        """Stderr contains actionable phrasing ('not found' / 'no such file')."""
        result = runner.invoke(app, ["run", "--scenario", MISSING_PATH])
        stderr_lower = result.stderr.lower()
        assert any(
            phrase in stderr_lower for phrase in ["not found", "no such file", "does not exist"]
        ), f"Expected actionable error in stderr: {result.stderr}"

    def test_no_traceback(self) -> None:
        """No Python traceback in stderr."""
        result = runner.invoke(app, ["run", "--scenario", MISSING_PATH])
        assert "Traceback (most recent call last)" not in result.stderr
        assert "FileNotFoundError" not in result.stderr


# ═══════════════════════════════════════════════════════════════════════════
# VAL-CLI-022: Flag → env-var mapping
# ═══════════════════════════════════════════════════════════════════════════


class TestFlagToEnvMapping:
    """VAL-CLI-022: every CLI flag has a documented engine-script env-var mapping."""

    def test_flag_to_env_dict_exists(self) -> None:
        """FLAG_TO_ENV dict is importable."""
        from chart_test_swarm.flags import FLAG_TO_ENV

        assert isinstance(FLAG_TO_ENV, dict)
        assert len(FLAG_TO_ENV) > 0

    def test_each_flag_has_env_var(self) -> None:
        """Every expected flag has a mapping."""
        from chart_test_swarm.flags import FLAG_TO_ENV

        required = {
            "backend",
            "parallelism",
            "cluster_name",
            "run_id",
            "reports_dir",
            "project_dir",
            "suite",
        }
        for flag in required:
            assert flag in FLAG_TO_ENV, f"Missing FLAG_TO_ENV entry for '{flag}'"
            assert FLAG_TO_ENV[flag], f"Empty FLAG_TO_ENV value for '{flag}'"

    def test_debug_trace_shows_env_vars(self, tmp_path: Path) -> None:
        """CTS_DEBUG=1 produces trace showing env vars set from CLI flags."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "RUN_ID=$RUN_ID"
                echo "PROVIDER=$PROVIDER"
                echo "NUM_AGENTS=$NUM_AGENTS"
                echo "CLUSTER_NAME=$CLUSTER_NAME"
                exit 0
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")
        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)
        env["CTS_DEBUG"] = "1"

        result = runner.invoke(
            app,
            [
                "run",
                "--scenario",
                str(scn),
                "--backend",
                "minikube",
                "--parallelism",
                "2",
                "--cluster-name",
                "chart-test-swarm-test1",
                "--run-id",
                "run-debug",
                "--project-dir",
                str(tmp_path),
            ],
            env=env,
        )
        # Debug traces go to stderr
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "PROVIDER=minikube" in result.stderr
        assert "NUM_AGENTS=2" in result.stderr
        assert "CLUSTER_NAME=chart-test-swarm-test1" in result.stderr
        assert "RUN_ID=run-debug" in result.stderr


# ═══════════════════════════════════════════════════════════════════════════
# Additional: Edge cases
# ═══════════════════════════════════════════════════════════════════════════


class TestEdgeCases:
    """Additional edge-case tests for the run command."""

    def test_scenario_path_not_a_file(self, tmp_path: Path) -> None:
        """A directory passed as --scenario gives clear error."""
        d = tmp_path / "not-a-file"
        d.mkdir()

        result = runner.invoke(app, ["run", "--scenario", str(d)])
        assert result.exit_code != 0
        assert "not a file" in result.stderr.lower()

    def test_all_flags_accepted(self, tmp_path: Path) -> None:
        """All documented flags can be passed together without arg-parsing error."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "RUN_ID=run-stub"
                exit 0
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")
        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            [
                "run",
                "--scenario",
                str(scn),
                "--backend",
                "kind",
                "--parallelism",
                "1",
                "--cluster-name",
                "chart-test-swarm-test2",
                "--run-id",
                "run-all-flags",
                "--reports-dir",
                "/tmp/reports",
                "--project-dir",
                str(tmp_path),
                "--suite",
                "all",
            ],
            env=env,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstdout={result.stdout}\nstderr={result.stderr}"
        )


# ═══════════════════════════════════════════════════════════════════════════
# VAL-CLOUD-015: --include-cloud-native flag
# ═══════════════════════════════════════════════════════════════════════════


class TestIncludeCloudNative:
    """VAL-CLOUD-015: --include-cloud-native flag maps to CTS_INCLUDE_CLOUD_NATIVE=1."""

    def test_help_shows_include_cloud_native(self) -> None:
        """run --help shows --include-cloud-native flag."""
        result = runner.invoke(app, ["run", "--help"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"
        assert "--include-cloud-native" in result.stdout, (
            f"Expected '--include-cloud-native' in help output:\n{result.stdout}"
        )

    def test_flag_sets_env_var(self, tmp_path: Path) -> None:
        """--include-cloud-native sets CTS_INCLUDE_CLOUD_NATIVE=1 in subprocess env."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "CTS_INCLUDE_CLOUD_NATIVE=${CTS_INCLUDE_CLOUD_NATIVE:-unset}"
                echo "RUN_ID=run-stub"
                exit 0
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")
        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            [
                "run",
                "--scenario",
                str(scn),
                "--include-cloud-native",
                "--project-dir",
                str(tmp_path),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "CTS_INCLUDE_CLOUD_NATIVE=1" in result.stdout, (
            f"Expected CTS_INCLUDE_CLOUD_NATIVE=1 in output:\n{result.stdout}"
        )

    def test_flag_default_is_zero(self, tmp_path: Path) -> None:
        """Default (flag not set) → CTS_INCLUDE_CLOUD_NATIVE=0."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "CTS_INCLUDE_CLOUD_NATIVE=${CTS_INCLUDE_CLOUD_NATIVE:-unset}"
                echo "RUN_ID=run-stub"
                exit 0
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")
        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            [
                "run",
                "--scenario",
                str(scn),
                "--project-dir",
                str(tmp_path),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "CTS_INCLUDE_CLOUD_NATIVE=0" in result.stdout, (
            f"Expected CTS_INCLUDE_CLOUD_NATIVE=0 in output:\n{result.stdout}"
        )

    def test_debug_trace_shows_include_cloud_native(self, tmp_path: Path) -> None:
        """CTS_DEBUG=1 trace shows CTS_INCLUDE_CLOUD_NATIVE=1 when flag is set."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "RUN_ID=run-stub"
                exit 0
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")
        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)
        env["CTS_DEBUG"] = "1"

        result = runner.invoke(
            app,
            [
                "run",
                "--scenario",
                str(scn),
                "--include-cloud-native",
                "--project-dir",
                str(tmp_path),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        assert "CTS_INCLUDE_CLOUD_NATIVE=1" in result.stderr, (
            f"Expected CTS_INCLUDE_CLOUD_NATIVE=1 in debug trace (stderr):\n{result.stderr}"
        )

    def test_flag_to_env_includes_include_cloud_native(self) -> None:
        """FLAG_TO_ENV mapping includes --include-cloud-native → CTS_INCLUDE_CLOUD_NATIVE."""
        from chart_test_swarm.flags import FLAG_TO_ENV

        assert "include_cloud_native" in FLAG_TO_ENV, (
            "Missing 'include_cloud_native' key in FLAG_TO_ENV"
        )
        assert FLAG_TO_ENV["include_cloud_native"] == "CTS_INCLUDE_CLOUD_NATIVE", (
            f"Expected 'CTS_INCLUDE_CLOUD_NATIVE', got '{FLAG_TO_ENV['include_cloud_native']}'"
        )

    def test_all_flags_including_cloud_native(self, tmp_path: Path) -> None:
        """--include-cloud-native can be combined with other flags."""
        _write_stub(
            tmp_path,
            "dispatch-swarm.sh",
            dedent("""\
                #!/usr/bin/env bash
                echo "CTS_INCLUDE_CLOUD_NATIVE=${CTS_INCLUDE_CLOUD_NATIVE:-unset}"
                echo "RUN_ID=run-stub"
                exit 0
            """),
        )

        scn = _scenario_yaml(tmp_path, "test-scenario.yaml")
        env = _add_to_path(tmp_path)
        env["CTS_ENGINE_SCRIPTS_DIR"] = str(tmp_path)

        result = runner.invoke(
            app,
            [
                "run",
                "--scenario",
                str(scn),
                "--backend",
                "kind",
                "--parallelism",
                "2",
                "--cluster-name",
                "chart-test-swarm-cloud1",
                "--run-id",
                "run-cloud-test",
                "--suite",
                "all",
                "--include-cloud-native",
                "--project-dir",
                str(tmp_path),
            ],
            env=env,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstdout={result.stdout}\nstderr={result.stderr}"
        )
        assert "CTS_INCLUDE_CLOUD_NATIVE=1" in result.stdout
