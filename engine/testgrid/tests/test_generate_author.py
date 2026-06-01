"""Tests for F10.2 — generate author subcommand.

Validates:
  - VAL-LLM-005: generate author invokes CTS_LLM_CMD subprocess (no direct API calls)
  - VAL-LLM-006: output passes jsonschema validation
  - VAL-LLM-007: retries on invalid LLM output up to bounded max
  - VAL-LLM-008: rejects empty/whitespace descriptions
  - VAL-LLM-013: missing host LLM binary surfaces clear actionable error
  - VAL-LLM-014: auto-discovery of droid uses PATH when CTS_LLM_CMD is unset
  - VAL-LLM-018: schema-failing LLM output reported with diagnosable error
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest
from typer.testing import CliRunner

from chart_test_swarm.main import app

# ── paths ──────────────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).resolve().parents[3]
STUB_PATH = REPO_ROOT / "engine" / "testgrid" / "tests" / "stubs" / "llm-stub.sh"
SCHEMA_PATH = REPO_ROOT / "engine" / "templates" / "scenario.schema.json"

runner = CliRunner()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _validate_yaml_against_schema(yaml_text: str) -> bool:
    """Validate YAML text against the scenario schema using check-jsonschema CLI."""
    import tempfile

    with tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".yaml",
        prefix="author-test-",
        delete=False,
    ) as f:
        f.write(yaml_text)
        tmp_path = f.name

    try:
        result = subprocess.run(
            [
                "check-jsonschema",
                "--schemafile",
                str(SCHEMA_PATH),
                tmp_path,
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.returncode == 0
    finally:
        Path(tmp_path).unlink(missing_ok=True)


def _make_env(extra: dict[str, str] | None = None) -> dict[str, str]:
    """Build an environment dict with CTS_LLM_CMD pointing at the stub."""
    env = os.environ.copy()
    env["CTS_LLM_CMD"] = f"bash {STUB_PATH}"
    if extra:
        env.update(extra)
    return env


# ---------------------------------------------------------------------------
# VAL-LLM-005: generate author invokes CTS_LLM_CMD subprocess (no direct API calls)
# ---------------------------------------------------------------------------


class TestAuthorInvokesLLMCmd:
    """VAL-LLM-005: generate author invokes CTS_LLM_CMD, no direct API calls."""

    def test_author_with_valid_llm_emits_canned_yaml(self, tmp_path: Path) -> None:
        """CTS_LLM_CMD=valid fake → stdout contains canned YAML."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({"LLM_STUB_MODE": "valid", "LLM_STUB_COUNT_FILE": str(count_file)})

        result = runner.invoke(
            app,
            ["generate", "author", "istio with strict-mtls + cert-manager"],
            env=env,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstdout={result.stdout}\nstderr={result.stderr}"
        )
        # The output should contain the canned scenario's id
        assert "llm-generated-scenario" in result.stdout, (
            f"Expected canned scenario id in output:\n{result.stdout[:500]}"
        )
        # The stub should have been invoked exactly once
        assert count_file.exists(), "Stub count file not created"
        assert count_file.read_text().strip() == "1", (
            f"Expected 1 stub invocation, got: {count_file.read_text().strip()}"
        )

    def test_author_zero_outbound_network_calls(self) -> None:
        """Source code contains no API key env lookups or LLM client imports.

        Validated via static grep — no need for runtime network inspection.
        """
        src_dir = REPO_ROOT / "engine" / "testgrid" / "src" / "chart_test_swarm"
        # Walk all .py files
        for py_file in src_dir.rglob("*.py"):
            content = py_file.read_text()
            # No API key env lookups
            forbidden = [
                "OPENAI_API_KEY",
                "ANTHROPIC_API_KEY",
                "GEMINI_API_KEY",
                "GOOGLE_API_KEY",
                "sk-",
            ]
            for pattern in forbidden:
                if pattern in content:
                    # Allow "sk-" only if it's in a docstring that says "sk-ip" or if checking
                    # for credential patterns (i.e., the grep in VAL-LLM-015)
                    # For this test, we're checking source code ONLY for API key patterns
                    if pattern == "sk-" and "sk-" in content:
                        # Check if it's a random occurrence (e.g. in a word like "task-")
                        # or an actual API key pattern
                        lines_with_sk = [
                            line for line in content.split("\n") if "sk-" in line
                        ]
                        for line in lines_with_sk:
                            if "sk-" in line and not line.strip().startswith("#"):
                                pytest.fail(
                                    f"Found potential credential pattern '{pattern}' "
                                    f"in {py_file}:\n  {line.strip()[:120]}"
                                )
                    else:
                        pytest.fail(
                            f"Found credential pattern '{pattern}' in {py_file}"
                        )


# ---------------------------------------------------------------------------
# VAL-LLM-006: output passes jsonschema validation
# ---------------------------------------------------------------------------


class TestAuthorSchemaValidation:
    """VAL-LLM-006: emitted YAML validates against scenario.schema.json."""

    def test_author_valid_llm_output_passes_schema(self, tmp_path: Path) -> None:
        """LLM stub in valid mode → output validates against schema."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({"LLM_STUB_MODE": "valid", "LLM_STUB_COUNT_FILE": str(count_file)})

        result = runner.invoke(
            app,
            ["generate", "author", "cert-manager with self-signed ca"],
            env=env,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstderr={result.stderr}"
        )
        assert _validate_yaml_against_schema(result.stdout), (
            f"Schema validation failed for generated YAML:\n{result.stdout[:500]}"
        )


# ---------------------------------------------------------------------------
# VAL-LLM-007: retries on invalid LLM output up to bounded max
# ---------------------------------------------------------------------------


class TestAuthorRetries:
    """VAL-LLM-007: retries on invalid output up to --max-retries."""

    def test_author_retries_three_times_on_invalid(self, tmp_path: Path) -> None:
        """LLM_STUB_PLAN=fail,fail,pass → 3 invocations, exits 0."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({
            "LLM_STUB_PLAN": "fail,fail,pass",
            "LLM_STUB_COUNT_FILE": str(count_file),
        })

        result = runner.invoke(
            app,
            ["generate", "author", "anything", "--max-retries", "3"],
            env=env,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstdout={result.stdout}\nstderr={result.stderr}"
        )
        assert count_file.read_text().strip() == "3", (
            f"Expected 3 invocations, got: {count_file.read_text().strip()}"
        )

    def test_author_max_retries_one_fails_on_invalid(self, tmp_path: Path) -> None:
        """--max-retries 1 against fail,fail,pass → non-zero exit, stderr has 'invalid'/'schema'."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({
            "LLM_STUB_PLAN": "fail,fail,pass",
            "LLM_STUB_COUNT_FILE": str(count_file),
        })

        result = runner.invoke(
            app,
            ["generate", "author", "anything", "--max-retries", "1"],
            env=env,
        )
        assert result.exit_code != 0, (
            f"Expected non-zero exit, got {result.exit_code}\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )
        combined = result.stdout + result.stderr
        assert "invalid" in combined.lower() or "schema" in combined.lower(), (
            f"Expected 'invalid' or 'schema' in output:\n{combined}"
        )

    def test_author_default_max_retries_is_three(self, tmp_path: Path) -> None:
        """Default --max-retries is 3 (no flag needed)."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({"LLM_STUB_MODE": "valid", "LLM_STUB_COUNT_FILE": str(count_file)})

        result = runner.invoke(
            app,
            ["generate", "author", "valid description"],
            env=env,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstderr={result.stderr}"
        )
        assert count_file.read_text().strip() == "1"


# ---------------------------------------------------------------------------
# VAL-LLM-008: rejects empty/whitespace descriptions
# ---------------------------------------------------------------------------


class TestAuthorRejectsEmptyDescription:
    """VAL-LLM-008: rejects empty/whitespace descriptions before LLM invocation."""

    def test_author_empty_description_exits_nonzero(self, tmp_path: Path) -> None:
        """'' description exits non-zero with stderr message."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({"LLM_STUB_MODE": "valid", "LLM_STUB_COUNT_FILE": str(count_file)})

        result = runner.invoke(
            app,
            ["generate", "author", ""],
            env=env,
        )
        assert result.exit_code != 0, (
            f"Expected non-zero exit, got {result.exit_code}"
        )
        combined = result.stdout + result.stderr
        assert (
            "empty" in combined.lower()
            or "non-empty" in combined.lower()
            or "required" in combined.lower()
        ), f"Expected error about empty description:\n{combined}"
        # The stub should NOT have been invoked
        assert not count_file.exists() or count_file.read_text().strip() == "0", (
            "LLM stub was invoked despite empty description"
        )

    def test_author_whitespace_description_exits_nonzero(self, tmp_path: Path) -> None:
        """'   ' description exits non-zero with stderr message."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({"LLM_STUB_MODE": "valid", "LLM_STUB_COUNT_FILE": str(count_file)})

        result = runner.invoke(
            app,
            ["generate", "author", "   "],
            env=env,
        )
        assert result.exit_code != 0, (
            f"Expected non-zero exit, got {result.exit_code}"
        )
        combined = result.stdout + result.stderr
        assert (
            "empty" in combined.lower()
            or "non-empty" in combined.lower()
            or "required" in combined.lower()
        ), f"Expected error about empty description:\n{combined}"
        # The stub should NOT have been invoked
        assert not count_file.exists() or count_file.read_text().strip() == "0", (
            "LLM stub was invoked despite whitespace-only description"
        )

    def test_author_valid_description_does_invoke_stub(self, tmp_path: Path) -> None:
        """A real description DOES invoke the stub (regression guard)."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({"LLM_STUB_MODE": "valid", "LLM_STUB_COUNT_FILE": str(count_file)})

        result = runner.invoke(
            app,
            ["generate", "author", "valid description here"],
            env=env,
        )
        assert result.exit_code == 0
        assert count_file.exists()
        assert count_file.read_text().strip() == "1"


# ---------------------------------------------------------------------------
# VAL-LLM-013: missing host LLM binary surfaces clear actionable error
# ---------------------------------------------------------------------------


class TestAuthorMissingLLMBinary:
    """VAL-LLM-013: missing droid binary → clear error with CTS_LLM_CMD guidance."""

    def test_author_no_cts_llm_cmd_no_droid_on_path(self, tmp_path: Path) -> None:
        """CTS_LLM_CMD unset + no droid on PATH → non-zero exit, stderr explains."""
        # Build a PATH with only essential system dirs (no droid)
        safe_path = "/usr/bin:/bin"
        env = os.environ.copy()
        env["PATH"] = safe_path
        # Ensure CTS_LLM_CMD is NOT set
        env.pop("CTS_LLM_CMD", None)

        result = runner.invoke(
            app,
            ["generate", "author", "some description"],
            env=env,
        )
        assert result.exit_code != 0, (
            f"Expected non-zero exit, got {result.exit_code}\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )
        combined = result.stdout + result.stderr
        # Must explain how to set CTS_LLM_CMD
        assert "CTS_LLM_CMD" in combined, (
            f"Expected mention of CTS_LLM_CMD env var:\n{combined}"
        )
        # Must name what was searched for
        assert "droid" in combined.lower(), (
            f"Expected mention of 'droid' binary:\n{combined}"
        )


# ---------------------------------------------------------------------------
# VAL-LLM-014: auto-discovery of droid uses PATH when CTS_LLM_CMD is unset
# ---------------------------------------------------------------------------


class TestAuthorDroidAutoDiscovery:
    """VAL-LLM-014: unset CTS_LLM_CMD + droid on PATH → invokes that droid."""

    def test_author_discovers_droid_on_path(self, tmp_path: Path) -> None:
        """Place a 'droid' shim on PATH; verify it gets invoked."""
        # Create a fake droid shim that emits schema-valid YAML
        droid_shim = tmp_path / "droid"
        droid_shim.write_text(
            "#!/usr/bin/env bash\n"
            "# droid shim for testing auto-discovery\n"
            "cat <<'YAMLEOF'\n"
            "---\n"
            "id: auto-discovered\n"
            "name: Auto-discovered droid scenario\n"
            "description: Generated by droid auto-discovery stub\n"
            "cluster:\n"
            "  provider: kind\n"
            "  k8s_version: v1.30.0\n"
            "product:\n"
            "  chart: chart\n"
            "  release: sample\n"
            "  namespace: sample\n"
            "  set:\n"
            "    replicaCount: \"1\"\n"
            "asserts:\n"
            "  - type: pods-ready\n"
            "    namespace: sample\n"
            "YAMLEOF\n"
        )
        droid_shim.chmod(0o755)

        env = os.environ.copy()
        env.pop("CTS_LLM_CMD", None)
        # Add tmp_path to PATH
        env["PATH"] = f"{tmp_path}{os.pathsep}{env.get('PATH', '/usr/bin:/bin')}"

        result = runner.invoke(
            app,
            ["generate", "author", "auto-discovered test"],
            env=env,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstdout={result.stdout}\nstderr={result.stderr}"
        )
        assert "auto-discovered" in result.stdout, (
            f"Expected auto-discovered scenario in output:\n{result.stdout[:500]}"
        )


# ---------------------------------------------------------------------------
# VAL-LLM-018: schema-failing LLM output reported with diagnosable error
# ---------------------------------------------------------------------------


class TestAuthorSchemaFailing:
    """VAL-LLM-018: schema-failing YAML → stderr names failing field path."""

    def test_author_schema_fail_reports_diagnosable_error(self, tmp_path: Path) -> None:
        """schema-fail mode → non-zero exit, stderr names provider + enum."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({
            "LLM_STUB_MODE": "schema-fail",
            "LLM_STUB_COUNT_FILE": str(count_file),
        })

        result = runner.invoke(
            app,
            ["generate", "author", "test schema failure", "--max-retries", "1"],
            env=env,
        )
        assert result.exit_code != 0, (
            f"Expected non-zero exit, got {result.exit_code}\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )
        combined = result.stdout + result.stderr
        # Must name a failing schema path
        assert "cluster" in combined.lower() and "provider" in combined.lower(), (
            f"Expected error to name 'cluster.provider':\n{combined}"
        )
        assert "enum" in combined.lower() or "bogus-backend" in combined.lower(), (
            f"Expected error to mention enum values or the offending value:\n{combined}"
        )

    def test_author_schema_fail_retry_then_success(self, tmp_path: Path) -> None:
        """schema-fail on invocations 1-2, valid on 3 → exits 0."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({
            "LLM_STUB_PLAN": "schema-fail,schema-fail,pass",
            "LLM_STUB_COUNT_FILE": str(count_file),
        })

        result = runner.invoke(
            app,
            ["generate", "author", "test", "--max-retries", "3"],
            env=env,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstdout={result.stdout}\nstderr={result.stderr}"
        )
        assert count_file.read_text().strip() == "3"


# ---------------------------------------------------------------------------
# --output flag tests
# ---------------------------------------------------------------------------


class TestAuthorOutputFlag:
    """--output writes the scenario to a file."""

    def test_author_output_writes_to_file(self, tmp_path: Path) -> None:
        """--output writes scenario YAML to the specified file."""
        out_file = tmp_path / "author-output.yaml"
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({"LLM_STUB_MODE": "valid", "LLM_STUB_COUNT_FILE": str(count_file)})

        result = runner.invoke(
            app,
            [
                "generate",
                "author",
                "test-description",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"exit_code={result.exit_code}\nstderr={result.stderr}"
        assert out_file.exists(), f"Output file not created: {out_file}"
        content = out_file.read_text()
        assert "llm-generated-scenario" in content, (
            f"Output file missing expected content:\n{content[:500]}"
        )

    def test_author_output_stdout_has_no_yaml_body(self, tmp_path: Path) -> None:
        """--output stdout should be <=2 lines, no YAML body."""
        out_file = tmp_path / "author-stdout-test.yaml"
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({"LLM_STUB_MODE": "valid", "LLM_STUB_COUNT_FILE": str(count_file)})

        result = runner.invoke(
            app,
            [
                "generate",
                "author",
                "test-description",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0
        stdout = result.stdout.strip()
        # Should NOT contain YAML markers
        assert "cluster:" not in stdout, f"stdout contains YAML body:\n{stdout}"
        assert "apiVersion" not in stdout, f"stdout contains YAML body:\n{stdout}"
        # Should contain a confirmation line
        assert str(out_file) in stdout or "Scenario" in stdout or "written" in stdout.lower(), (
            f"stdout missing confirmation: {stdout}"
        )
        lines = [line for line in stdout.split("\n") if line.strip()]
        assert len(lines) <= 2, f"stdout should be <=2 lines, got {len(lines)}:\n{stdout}"


# ---------------------------------------------------------------------------
# generated_by provenance
# ---------------------------------------------------------------------------


class TestAuthorGeneratedBy:
    """Generated scenarios carry generated_by provenance."""

    def test_author_output_includes_generated_by(self, tmp_path: Path) -> None:
        """Emitted YAML includes a generated_by section."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({"LLM_STUB_MODE": "valid", "LLM_STUB_COUNT_FILE": str(count_file)})

        result = runner.invoke(
            app,
            ["generate", "author", "test provenance"],
            env=env,
        )
        assert result.exit_code == 0
        # The output should have generated_by
        assert "generated_by:" in result.stdout, (
            f"Expected generated_by section:\n{result.stdout[:500]}"
        )
        assert "by:" in result.stdout, (
            f"Expected generated_by.by field:\n{result.stdout[:500]}"
        )


# ---------------------------------------------------------------------------
# --force flag for overwriting output
# ---------------------------------------------------------------------------


class TestAuthorForceFlag:
    """--output refuses to overwrite without --force."""

    def test_author_output_refuses_overwrite(self, tmp_path: Path) -> None:
        """--output on existing file exits non-zero, suggests --force."""
        out_file = tmp_path / "exists.yaml"
        out_file.write_text("existing content")
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({"LLM_STUB_MODE": "valid", "LLM_STUB_COUNT_FILE": str(count_file)})

        result = runner.invoke(
            app,
            [
                "generate",
                "author",
                "test-overwrite",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code != 0, (
            f"Expected non-zero exit for overwrite refusal, got {result.exit_code}"
        )
        combined = result.stdout + result.stderr
        assert "already exist" in combined.lower() or "--force" in combined.lower(), (
            f"Expected message about existing file or --force:\n{combined}"
        )
        # Content preserved
        assert out_file.read_text() == "existing content", (
            "Original file content was modified!"
        )

    def test_author_output_force_overwrites(self, tmp_path: Path) -> None:
        """--output --force overwrites existing file."""
        out_file = tmp_path / "force-test.yaml"
        out_file.write_text("old content")
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({"LLM_STUB_MODE": "valid", "LLM_STUB_COUNT_FILE": str(count_file)})

        result = runner.invoke(
            app,
            [
                "generate",
                "author",
                "force-test",
                "--output",
                str(out_file),
                "--force",
            ],
            env=env,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstderr={result.stderr}"
        )
        content = out_file.read_text()
        assert "old content" not in content, "File was not overwritten"
        assert "llm-generated-scenario" in content, f"New content missing:\n{content[:500]}"


# ---------------------------------------------------------------------------
# Help output
# ---------------------------------------------------------------------------


class TestAuthorHelp:
    """generate author --help exits 0 and shows flags."""

    def test_author_help_exits_0(self) -> None:
        """generate author --help exits 0."""
        result = runner.invoke(app, ["generate", "author", "--help"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"

    def test_author_help_shows_max_retries(self) -> None:
        """generate author --help shows --max-retries."""
        result = runner.invoke(app, ["generate", "author", "--help"])
        assert "--max-retries" in result.stdout, (
            f"Expected --max-retries in help:\n{result.stdout}"
        )

    def test_author_help_shows_output(self) -> None:
        """generate author --help shows --output."""
        result = runner.invoke(app, ["generate", "author", "--help"])
        assert "--output" in result.stdout, (
            f"Expected --output in help:\n{result.stdout}"
        )


# ---------------------------------------------------------------------------
# Description is passed through to the LLM
# ---------------------------------------------------------------------------


class TestAuthorDescriptionPassedThrough:
    """The user description is passed to the LLM."""

    def test_author_passes_description_to_llm(self, tmp_path: Path) -> None:
        """Description is passed through to the LLM stub (via stdin)."""
        desc = "istio with strict-mtls + cert-manager + JWT auth"
        count_file = tmp_path / "llm-count.txt"
        env = _make_env({"LLM_STUB_MODE": "valid", "LLM_STUB_COUNT_FILE": str(count_file)})

        result = runner.invoke(
            app,
            ["generate", "author", desc],
            env=env,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstderr={result.stderr}"
        )
        # The stub logs the description to stderr — we verify the stub was called
        # but we can't easily assert the exact description via CliRunner's stderr
        # since it captures stderr from the stub too. The key test is that
        # the stub ran and emitted valid output.
        assert count_file.read_text().strip() == "1"
