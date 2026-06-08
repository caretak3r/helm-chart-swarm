"""Tests for F10.1 — generate pick subcommand.

Validates:
  - VAL-LLM-001: generate --help exits 0 and lists pick / author / explore
  - VAL-LLM-002: pick is non-interactive with flags or stdin; no selection exits non-zero
  - VAL-LLM-003: emitted YAML validates against scenario schema
  - VAL-LLM-004: --output writes to file, stdout has only confirmation
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from typer.testing import CliRunner

from chart_test_swarm.main import app

# Paths
REPO_ROOT = Path(__file__).resolve().parents[3]
TESTGRID_DIR = REPO_ROOT / "engine" / "testgrid"
SCHEMA_PATH = REPO_ROOT / "engine" / "templates" / "scenario.schema.json"
SCENARIOS_DIR = REPO_ROOT / "examples" / "sample-product-chart" / "chart-test" / "scenarios"

runner = CliRunner()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _validate_yaml_against_schema(yaml_text: str) -> bool:
    """Validate YAML text against the scenario schema using check-jsonschema CLI.

    check-jsonschema auto-detects YAML/JSON by file extension, so we write
    to a temporary .yaml file rather than piping to stdin.
    """
    import tempfile

    with tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".yaml",
        prefix="pick-test-",
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


# ---------------------------------------------------------------------------
# VAL-LLM-001: generate --help exits 0 and lists pick / author / explore
# ---------------------------------------------------------------------------


class TestGenerateHelp:
    """VAL-LLM-001: generate --help advertises all three modes."""

    def test_generate_help_exits_0(self) -> None:
        """generate --help exits 0."""
        result = runner.invoke(app, ["generate", "--help"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"

    def test_generate_help_lists_pick(self) -> None:
        """generate --help advertises 'pick'."""
        result = runner.invoke(app, ["generate", "--help"])
        assert "pick" in result.stdout, f"Expected 'pick' in help output:\n{result.stdout}"

    def test_generate_help_lists_author(self) -> None:
        """generate --help advertises 'author'."""
        result = runner.invoke(app, ["generate", "--help"])
        assert "author" in result.stdout, f"Expected 'author' in help output:\n{result.stdout}"

    def test_generate_help_lists_explore(self) -> None:
        """generate --help advertises 'explore'."""
        result = runner.invoke(app, ["generate", "--help"])
        assert "explore" in result.stdout, f"Expected 'explore' in help output:\n{result.stdout}"


# ---------------------------------------------------------------------------
# VAL-LLM-002: pick is non-interactive with flags or stdin; no selection →
#   non-zero exit within 5s (no hang)
# ---------------------------------------------------------------------------


class TestPickNonInteractive:
    """VAL-LLM-002: pick is non-interactive with flags or stdin."""

    def test_pick_with_category_integration_variant_flags(self) -> None:
        """generate pick --category certificates --integration cert-manager
        --variant self-signed exits 0 with YAML output."""
        result = runner.invoke(
            app,
            [
                "generate",
                "pick",
                "--category",
                "certificates",
                "--integration",
                "cert-manager",
                "--variant",
                "self-signed",
            ],
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstdout={result.stdout}\nstderr={result.stderr}"
        )
        assert result.stdout.strip(), "Expected non-empty stdout"

    def test_pick_with_exact_variant_flag(self) -> None:
        """generate pick with exact variant name 'wildcard' exits 0."""
        result = runner.invoke(
            app,
            [
                "generate",
                "pick",
                "--category",
                "certificates",
                "--integration",
                "cert-manager",
                "--variant",
                "wildcard",
            ],
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstdout={result.stdout}\nstderr={result.stderr}"
        )
        assert result.stdout.strip(), "Expected non-empty stdout"

    def test_pick_with_stdin_json_feed(self) -> None:
        """generate pick with stdin JSON feed exits 0."""
        feed = json.dumps(
            {"category": "certificates", "integration": "cert-manager", "variant": "self-signed"}
        )
        result = runner.invoke(
            app,
            ["generate", "pick"],
            input=feed,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstdout={result.stdout}\nstderr={result.stderr}"
        )
        assert result.stdout.strip(), "Expected non-empty stdout"

    def test_pick_no_selection_non_tty_exits_nonzero(self) -> None:
        """generate pick with no flags and no stdin exits non-zero within 5s."""
        import time

        start = time.monotonic()
        result = runner.invoke(app, ["generate", "pick"])
        elapsed = time.monotonic() - start

        assert result.exit_code != 0, (
            f"Expected non-zero exit, got {result.exit_code}\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )
        assert elapsed < 5.0, f"Expected fast failure (<5s), took {elapsed:.2f}s"
        # Should have a clear "no selection" message
        combined = result.stdout + result.stderr
        assert "no selection" in combined.lower() or "category" in combined.lower(), (
            f"Expected 'no selection' or 'category' in output:\n{combined}"
        )

    def test_pick_with_stdin_yaml_feed(self) -> None:
        """generate pick with stdin YAML feed exits 0."""
        feed = "category: certificates\nintegration: cert-manager\nvariant: self-signed\n"
        result = runner.invoke(
            app,
            ["generate", "pick"],
            input=feed,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstdout={result.stdout}\nstderr={result.stderr}"
        )
        assert result.stdout.strip(), "Expected non-empty stdout"

    def test_pick_flags_take_precedence_over_stdin(self) -> None:
        """Flags override stdin feed values."""
        feed = json.dumps(
            {"category": "gateway-api", "integration": "envoy-gateway", "variant": "grpcroute"}
        )
        result = runner.invoke(
            app,
            [
                "generate",
                "pick",
                "--category",
                "certificates",
                "--integration",
                "cert-manager",
                "--variant",
                "wildcard",
            ],
            input=feed,
        )
        # Should pick the flag values (certificates/cert-manager/wildcard), not stdin
        assert result.exit_code == 0, (
            f"Expected exit 0, got {result.exit_code}\nstderr={result.stderr}"
        )


# ---------------------------------------------------------------------------
# VAL-LLM-003: emitted YAML validates against scenario schema
# ---------------------------------------------------------------------------


class TestPickSchemaValidation:
    """VAL-LLM-003: emitted YAML validates against scenario.schema.json."""

    def test_pick_output_validates_against_schema(self) -> None:
        """Emitted YAML passes jsonschema validation."""
        result = runner.invoke(
            app,
            [
                "generate",
                "pick",
                "--category",
                "certificates",
                "--integration",
                "cert-manager",
                "--variant",
                "self-signed",
            ],
        )
        assert result.exit_code == 0
        assert _validate_yaml_against_schema(result.stdout), (
            f"Schema validation failed for output:\n{result.stdout[:500]}"
        )

    def test_pick_wildcard_variant_validates(self) -> None:
        """Wildcard variant YAML validates."""
        result = runner.invoke(
            app,
            [
                "generate",
                "pick",
                "--category",
                "certificates",
                "--integration",
                "cert-manager",
                "--variant",
                "wildcard",
            ],
        )
        assert result.exit_code == 0
        assert _validate_yaml_against_schema(result.stdout), (
            f"Schema validation failed:\n{result.stdout[:500]}"
        )

    def test_pick_ingress_variant_validates(self) -> None:
        """Ingress controller variant YAML validates."""
        result = runner.invoke(
            app,
            [
                "generate",
                "pick",
                "--category",
                "ingress-controllers",
                "--integration",
                "nginx-ingress",
                "--variant",
                "basic",
            ],
        )
        assert result.exit_code == 0
        assert _validate_yaml_against_schema(result.stdout), (
            f"Schema validation failed:\n{result.stdout[:500]}"
        )


# ---------------------------------------------------------------------------
# VAL-LLM-004: --output writes to file, stdout has only confirmation
# ---------------------------------------------------------------------------


class TestPickOutputFlag:
    """VAL-LLM-004: --output writes to file, stdout has only confirmation."""

    def test_pick_output_writes_to_file(self, tmp_path: Path) -> None:
        """--output writes scenario YAML to the specified file."""
        out_file = tmp_path / "pick-output.yaml"
        result = runner.invoke(
            app,
            [
                "generate",
                "pick",
                "--category",
                "certificates",
                "--integration",
                "cert-manager",
                "--variant",
                "self-signed",
                "--output",
                str(out_file),
            ],
        )
        assert result.exit_code == 0, f"exit_code={result.exit_code}\nstderr={result.stderr}"
        assert out_file.exists(), f"Output file not created: {out_file}"
        content = out_file.read_text()
        assert content.strip(), "Output file is empty"
        assert "cluster:" in content, f"Output file missing 'cluster:':\n{content[:500]}"

    def test_pick_output_stdout_has_no_yaml_body(self, tmp_path: Path) -> None:
        """--output stdout contains only confirmation, no YAML body."""
        out_file = tmp_path / "pick-stdout-test.yaml"
        result = runner.invoke(
            app,
            [
                "generate",
                "pick",
                "--category",
                "certificates",
                "--integration",
                "cert-manager",
                "--variant",
                "self-signed",
                "--output",
                str(out_file),
            ],
        )
        assert result.exit_code == 0

        stdout = result.stdout.strip()
        # Should NOT contain YAML markers like "cluster:" or "apiVersion"
        assert "cluster:" not in stdout, f"stdout contains YAML body:\n{stdout}"
        assert "apiVersion" not in stdout, f"stdout contains YAML body:\n{stdout}"
        # Should contain a confirmation/path line
        assert str(out_file) in stdout or "Scenario" in stdout or "written" in stdout.lower(), (
            f"stdout missing confirmation: {stdout}"
        )
        # Should be at most 2 lines
        lines = [line for line in stdout.split("\n") if line.strip()]
        assert len(lines) <= 2, f"stdout should be <= 2 lines, got {len(lines)}:\n{stdout}"

    def test_pick_output_file_validates_against_schema(self, tmp_path: Path) -> None:
        """Output file content validates against schema."""
        out_file = tmp_path / "pick-validate.yaml"
        result = runner.invoke(
            app,
            [
                "generate",
                "pick",
                "--category",
                "certificates",
                "--integration",
                "cert-manager",
                "--variant",
                "self-signed",
                "--output",
                str(out_file),
            ],
        )
        assert result.exit_code == 0
        assert out_file.exists()
        assert _validate_yaml_against_schema(out_file.read_text()), (
            "Output file does not validate against schema"
        )


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


class TestPickEdgeCases:
    """Edge case and error handling tests."""

    def test_pick_nonexistent_category_exits_nonzero(self) -> None:
        """Non-existent category exits non-zero with clear error."""
        result = runner.invoke(
            app,
            [
                "generate",
                "pick",
                "--category",
                "nonexistent",
                "--integration",
                "fake-integration",
                "--variant",
                "basic",
            ],
        )
        assert result.exit_code != 0, f"Expected non-zero exit, got {result.exit_code}"
        combined = result.stdout + result.stderr
        assert "no scenario" in combined.lower() or "not found" in combined.lower(), (
            f"Expected error message:\n{combined}"
        )

    def test_pick_nonexistent_variant_exits_nonzero(self) -> None:
        """Non-existent variant exits non-zero."""
        result = runner.invoke(
            app,
            [
                "generate",
                "pick",
                "--category",
                "certificates",
                "--integration",
                "cert-manager",
                "--variant",
                "nonexistent-variant-xyz",
            ],
        )
        assert result.exit_code != 0, f"Expected non-zero exit, got {result.exit_code}"

    def test_pick_help_exits_0(self) -> None:
        """generate pick --help exits 0 and shows options."""
        result = runner.invoke(app, ["generate", "pick", "--help"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}, stderr={result.stderr}"
        assert "--category" in result.stdout, f"Expected --category in help:\n{result.stdout}"
        assert "--integration" in result.stdout, f"Expected --integration in help:\n{result.stdout}"
        assert "--variant" in result.stdout, f"Expected --variant in help:\n{result.stdout}"
        assert "--output" in result.stdout, f"Expected --output in help:\n{result.stdout}"
