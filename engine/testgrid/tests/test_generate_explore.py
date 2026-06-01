"""Tests for F10.3 — generate explore subcommand.

Validates:
  - VAL-LLM-009: generate explore --max-iterations N is upper-bounded by N
  - VAL-LLM-010: generate explore --budget halts when budget exhausted
  - VAL-LLM-011: generate explore writes a summary report listing combos and outcomes
  - VAL-LLM-016: generate explore feeds prior result back into next LLM prompt
  - VAL-LLM-017: All generate modes accept --output for file-based capture
  - VAL-LLM-019: Generated scenarios refuse to overwrite without --force
  - VAL-LLM-020: generate explore writes summary incrementally (crash-safe)
  - VAL-LLM-021: Generated scenarios carry generated_by provenance
  - VAL-LLM-022: generate explore rejects prefix-violation before cluster spin-up
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

from typer.testing import CliRunner

from chart_test_swarm.main import app

# ── paths ──────────────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).resolve().parents[3]
STUB_PATH = REPO_ROOT / "engine" / "testgrid" / "tests" / "stubs" / "llm-stub.sh"
RUN_STUB_PATH = REPO_ROOT / "engine" / "testgrid" / "tests" / "stubs" / "run-stub.sh"
SCHEMA_PATH = REPO_ROOT / "engine" / "templates" / "scenario.schema.json"
CHART_PATH = REPO_ROOT / "examples" / "sample-product-chart" / "chart"

runner = CliRunner()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_env(extra: dict[str, str] | None = None) -> dict[str, str]:
    """Build an environment dict with CTS_LLM_CMD + CTS_RUN_CMD pointing at stubs."""
    env = os.environ.copy()
    env["CTS_LLM_CMD"] = f"bash {STUB_PATH}"
    env["CTS_RUN_CMD"] = f"bash {RUN_STUB_PATH}"
    if extra:
        env.update(extra)
    return env


def _validate_yaml_against_schema(yaml_text: str) -> bool:
    """Validate YAML text against the scenario schema using check-jsonschema CLI."""
    import tempfile

    with tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".yaml",
        prefix="explore-test-",
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
# VAL-LLM-009: generate explore --max-iterations N is upper-bounded by N
# ---------------------------------------------------------------------------


class TestExploreMaxIterations:
    """VAL-LLM-009: max-iterations bounds the exploration loop."""

    def test_explore_max_iterations_1_performs_exactly_1_iteration(self, tmp_path: Path) -> None:
        """With --max-iterations 1 and a valid LLM stub, performs exactly 1 iteration."""
        count_file = tmp_path / "llm-count.txt"
        out_file = tmp_path / "explore-out.json"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "1",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstdout={result.stdout}\nstderr={result.stderr}"
        )
        # LLM should have been invoked exactly once
        assert count_file.read_text().strip() == "1", (
            f"Expected 1 LLM invocation, got: {count_file.read_text().strip()}"
        )
        # Summary should have 1 record
        assert out_file.exists()
        records = json.loads(out_file.read_text())
        assert len(records) == 1, f"Expected 1 record, got {len(records)}"

    def test_explore_max_iterations_3_performs_exactly_3_iterations(self, tmp_path: Path) -> None:
        """With --max-iterations 3, performs exactly 3 iterations."""
        count_file = tmp_path / "llm-count.txt"
        out_file = tmp_path / "explore-out.json"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager,nginx-ingress",
                "--max-iterations",
                "3",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0, (
            f"exit_code={result.exit_code}\nstdout={result.stdout}\nstderr={result.stderr}"
        )
        assert count_file.read_text().strip() == "3", (
            f"Expected 3 LLM invocations, got: {count_file.read_text().strip()}"
        )
        records = json.loads(out_file.read_text())
        assert len(records) == 3, f"Expected 3 records, got {len(records)}"


# ---------------------------------------------------------------------------
# VAL-LLM-010: generate explore --budget halts when budget exhausted
# ---------------------------------------------------------------------------


class TestExploreBudget:
    """VAL-LLM-010: --budget halts exploration when exhausted."""

    def test_explore_budget_exhausted_halts_early(self, tmp_path: Path) -> None:
        """With --budget 2 and $1.50 cost per iteration, halts after 1 iter."""
        count_file = tmp_path / "llm-count.txt"
        out_file = tmp_path / "explore-out.json"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
                "LLM_STUB_COST": "1.50",
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "5",
                "--budget",
                "2.00",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"exit_code={result.exit_code}\nstderr={result.stderr}"
        # Should stop after 1 iteration ($1.50) since next would exceed $2.00
        invocations = int(count_file.read_text().strip())
        assert invocations <= 2, (
            f"Expected at most 2 invocations before budget exhausted, got {invocations}"
        )
        # Stderr should mention budget exhausted
        combined = result.stdout + result.stderr
        assert "budget" in combined.lower() or "exhausted" in combined.lower(), (
            f"Expected 'budget exhausted' in output:\n{combined}"
        )

    def test_explore_budget_high_enough_completes_all_iterations(self, tmp_path: Path) -> None:
        """With --budget 100 and $0.50 cost, all iterations complete."""
        count_file = tmp_path / "llm-count.txt"
        out_file = tmp_path / "explore-out.json"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
                "LLM_STUB_COST": "0.50",
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "2",
                "--budget",
                "100.00",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0
        assert count_file.read_text().strip() == "2"


# ---------------------------------------------------------------------------
# VAL-LLM-011: generate explore writes a summary report
# ---------------------------------------------------------------------------


class TestExploreSummaryReport:
    """VAL-LLM-011: summary report has correct shape."""

    def test_explore_summary_has_correct_keys(self, tmp_path: Path) -> None:
        """Each record has iteration, scenario_yaml, run_id, status, integrations."""
        count_file = tmp_path / "llm-count.txt"
        out_file = tmp_path / "explore-out.json"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager,nginx-ingress",
                "--max-iterations",
                "1",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0
        records = json.loads(out_file.read_text())
        assert len(records) == 1
        record = records[0]
        assert "iteration" in record, f"Missing 'iteration' key: {record.keys()}"
        assert record["iteration"] == 1
        assert "scenario_yaml" in record, f"Missing 'scenario_yaml': {record.keys()}"
        assert "run_id" in record, f"Missing 'run_id': {record.keys()}"
        assert "status" in record, f"Missing 'status': {record.keys()}"
        assert "integrations" in record, f"Missing 'integrations': {record.keys()}"

    def test_explore_summary_is_valid_json_array(self, tmp_path: Path) -> None:
        """Output file is a valid JSON array."""
        count_file = tmp_path / "llm-count.txt"
        out_file = tmp_path / "explore-out.json"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "1",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0
        data = json.loads(out_file.read_text())
        assert isinstance(data, list), f"Expected JSON array, got {type(data).__name__}"
        assert len(data) == 1


# ---------------------------------------------------------------------------
# VAL-LLM-016: feeds prior result back into next LLM prompt
# ---------------------------------------------------------------------------


class TestExploreFeedsPriorResult:
    """VAL-LLM-016: prior result is fed to LLM on iteration N>1."""

    def test_explore_iteration_1_has_no_prior_result_in_stdin(self, tmp_path: Path) -> None:
        """Iteration 1 stdin does NOT contain a prior-run reference."""
        count_file = tmp_path / "llm-count.txt"
        stdin_file = tmp_path / "llm-stdin.txt"
        out_file = tmp_path / "explore-out.json"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
                "LLM_STUB_STDIN_FILE": str(stdin_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "1",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"exit_code={result.exit_code}\nstderr={result.stderr}"
        # Iteration 1 prompt should be the scenario generator prompt,
        # not containing any "Prior iteration result" section
        assert stdin_file.exists(), "LLM_STUB_STDIN_FILE was not written"
        stdin_content = stdin_file.read_text()
        assert "chart-test-swarm scenario generator" in stdin_content.lower(), (
            f"Expected scenario generator prompt in stdin:\n{stdin_content[:500]}"
        )
        assert "Prior iteration result" not in stdin_content, (
            f"Iteration 1 should NOT have prior result reference:\n{stdin_content[:500]}"
        )

    def test_explore_iteration_2_has_prior_result_reference(self, tmp_path: Path) -> None:
        """Iteration 2 stdin includes the result from iteration 1."""
        count_file = tmp_path / "llm-count.txt"
        # The stub overwrites the stdin file on each invocation, so the LAST
        # write (iteration 2) will contain the prior-result reference.
        stdin_file = tmp_path / "llm-stdin.txt"
        out_file = tmp_path / "explore-out.json"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
                "LLM_STUB_STDIN_FILE": str(stdin_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager,nginx-ingress",
                "--max-iterations",
                "2",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"exit_code={result.exit_code}\nstderr={result.stderr}"
        # The iteration 2 prompt should include "Prior iteration result"
        assert stdin_file.exists(), "LLM_STUB_STDIN_FILE was not written"
        stdin_content = stdin_file.read_text()
        assert "Prior iteration result" in stdin_content, (
            f"Expected 'Prior iteration result' in iteration 2 prompt:\n{stdin_content[:1000]}"
        )
        # Should also contain the scenario generator template
        assert "chart-test-swarm scenario generator" in stdin_content.lower(), (
            f"Expected scenario generator prompt:\n{stdin_content[:500]}"
        )


# ---------------------------------------------------------------------------
# VAL-LLM-017: --output flag for file capture
# ---------------------------------------------------------------------------


class TestExploreOutputFlag:
    """VAL-LLM-017: --output writes to file, stdout is short."""

    def test_explore_output_writes_to_file(self, tmp_path: Path) -> None:
        """--output writes the summary JSON to the specified file."""
        count_file = tmp_path / "llm-count.txt"
        out_file = tmp_path / "explore-out.json"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "1",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"exit_code={result.exit_code}\nstderr={result.stderr}"
        assert out_file.exists(), f"Output file not created: {out_file}"
        records = json.loads(out_file.read_text())
        assert len(records) == 1

    def test_explore_output_stdout_is_short(self, tmp_path: Path) -> None:
        """With --output, stdout is <=2 lines and is a confirmation."""
        out_file = tmp_path / "explore-out.json"
        count_file = tmp_path / "llm-count.txt"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "1",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0
        stdout = result.stdout.strip()
        # Should NOT contain JSON array brackets
        assert "[" not in stdout or stdout.count("[") <= 1, (
            f"stdout should be confirmation, not JSON:\n{stdout}"
        )
        # Should be at most 2 non-empty lines
        lines = [line for line in stdout.split("\n") if line.strip()]
        assert len(lines) <= 2, f"stdout should be <=2 lines, got {len(lines)}:\n{stdout}"
        # Should mention the output path
        assert (
            str(out_file) in stdout
            or "Exploration complete" in stdout
            or "written" in stdout.lower()
        ), f"stdout missing confirmation: {stdout}"


# ---------------------------------------------------------------------------
# VAL-LLM-019: refuse overwrite without --force
# ---------------------------------------------------------------------------


class TestExploreForceOverwrite:
    """VAL-LLM-019: refuses overwrite without --force."""

    def test_explore_refuses_overwrite_existing_file(self, tmp_path: Path) -> None:
        """--output on existing non-empty file exits non-zero."""
        out_file = tmp_path / "exists.json"
        original_content = "existing content"
        out_file.write_text(original_content)

        count_file = tmp_path / "llm-count.txt"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "1",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code != 0, (
            f"Expected non-zero exit for overwrite refusal, got {result.exit_code}"
        )
        combined = result.stdout + result.stderr
        assert "--force" in combined, f"Expected --force suggestion:\n{combined}"
        # Content preserved
        assert out_file.read_text() == original_content, "Original file content was modified!"

    def test_explore_force_overwrites_existing_file(self, tmp_path: Path) -> None:
        """--output --force overwrites existing file."""
        out_file = tmp_path / "force-test.json"
        out_file.write_text("old content")
        count_file = tmp_path / "llm-count.txt"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "1",
                "--output",
                str(out_file),
                "--force",
            ],
            env=env,
        )
        assert result.exit_code == 0, f"exit_code={result.exit_code}\nstderr={result.stderr}"
        content = out_file.read_text()
        assert "old content" not in content, "File was not overwritten"
        assert "iteration" in content, f"New content missing expected data:\n{content[:200]}"


# ---------------------------------------------------------------------------
# VAL-LLM-020: incremental summary writes (crash-safe)
# ---------------------------------------------------------------------------


class TestExploreIncrementalSummary:
    """VAL-LLM-020: incremental writes survive crashes."""

    def test_explore_crash_iter2_leaves_partial_summary(self, tmp_path: Path) -> None:
        """LLM crashes (exit 137) on iter 2 → partial summary with 1 record."""
        out_file = tmp_path / "explore-out.json"
        count_file = tmp_path / "llm-count.txt"
        env = _make_env(
            {
                "LLM_STUB_PLAN": "pass,crash-exit-137",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "3",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        # Should exit non-zero (crash)
        assert result.exit_code != 0, f"Expected non-zero exit for crash, got {result.exit_code}"
        # Summary file should exist with exactly 1 record
        assert out_file.exists(), f"Output file not created: {out_file}"
        records = json.loads(out_file.read_text())
        assert len(records) == 1, f"Expected exactly 1 record after crash, got {len(records)}"
        # The record should be valid JSON
        assert records[0]["iteration"] == 1
        assert records[0]["status"] in ("PASS", "RUN_DISPATCHED")
        # Stderr should mention the crash
        combined = result.stdout + result.stderr
        assert (
            "exit 137" in combined.lower()
            or "137" in combined.lower()
            or "crash" in combined.lower()
        ), f"Expected crash mention:\n{combined}"


# ---------------------------------------------------------------------------
# VAL-LLM-021: generated_by provenance
# ---------------------------------------------------------------------------


class TestExploreGeneratedBy:
    """VAL-LLM-021: scenarios carry generated_by provenance."""

    def test_explore_scenario_has_generated_by(self, tmp_path: Path) -> None:
        """Generated scenario YAML includes generated_by mapping."""
        count_file = tmp_path / "llm-count.txt"
        out_file = tmp_path / "explore-out.json"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "1",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0
        records = json.loads(out_file.read_text())
        assert len(records) == 1
        scenario_yaml = records[0].get("scenario_yaml", "")
        assert "generated_by:" in scenario_yaml, (
            f"Expected generated_by in scenario:\n{scenario_yaml[:500]}"
        )
        assert "by:" in scenario_yaml, f"Expected 'by:' field:\n{scenario_yaml[:500]}"
        assert "explore" in scenario_yaml, (
            f"Expected 'explore' value for by:\n{scenario_yaml[:500]}"
        )
        assert "skill_version:" in scenario_yaml, (
            f"Expected 'skill_version:' field:\n{scenario_yaml[:500]}"
        )


# ---------------------------------------------------------------------------
# VAL-LLM-022: prefix-violation rejection before cluster spin-up
# ---------------------------------------------------------------------------


class TestExplorePrefixViolation:
    """VAL-LLM-022: prefix violation rejected before cluster spin-up."""

    def test_explore_rejects_prefix_violation(self, tmp_path: Path) -> None:
        """LLM proposes scenario with escaped-cluster name → rejected."""
        out_file = tmp_path / "explore-out.json"
        count_file = tmp_path / "llm-count.txt"
        # Plan: iter1=valid, iter2=prefix-violation, iter3=valid
        env = _make_env(
            {
                "LLM_STUB_PLAN": "pass,prefix-violation,pass",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "3",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"exit_code={result.exit_code}\nstderr={result.stderr}"
        records = json.loads(out_file.read_text())
        assert len(records) == 3, f"Expected 3 records, got {len(records)}"

        # Iteration 1 should be PASS
        assert records[0]["status"] in ("PASS", "RUN_DISPATCHED"), (
            f"Expected iter1 PASS, got {records[0]['status']}"
        )

        # Iteration 2 should be REJECTED with prefix violation
        assert records[1]["status"] == "REJECTED", (
            f"Expected iter2 REJECTED, got {records[1]['status']}"
        )
        assert (
            "prefix" in records[1].get("error", "").lower()
            or "escaped" in records[1].get("error", "").lower()
        ), f"Expected prefix violation in error: {records[1].get('error')}"
        # Iteration 3 should be PASS
        assert records[2]["status"] in ("PASS", "RUN_DISPATCHED"), (
            f"Expected iter3 PASS, got {records[2]['status']}"
        )

        # Iteration 2 should NOT have a run_id (no cluster was created)
        assert not records[1].get("run_id"), (
            f"Expected no run_id for rejected iteration, got: {records[1].get('run_id')}"
        )

    def test_explore_rejects_schema_violation(self, tmp_path: Path) -> None:
        """LLM proposes schema-failing scenario → rejected."""
        out_file = tmp_path / "explore-out.json"
        count_file = tmp_path / "llm-count.txt"
        env = _make_env(
            {
                "LLM_STUB_PLAN": "pass,schema-fail,pass",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "3",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        assert result.exit_code == 0, f"exit_code={result.exit_code}\nstderr={result.stderr}"
        records = json.loads(out_file.read_text())
        assert len(records) == 3
        # Iteration 2 should be REJECTED with schema validation error
        assert records[1]["status"] == "REJECTED", f"Expected REJECTED, got {records[1]['status']}"
        assert (
            "schema" in records[1].get("error", "").lower()
            or "validation" in records[1].get("error", "").lower()
        ), f"Expected schema error: {records[1].get('error')}"


# ---------------------------------------------------------------------------
# Explore help + edge cases
# ---------------------------------------------------------------------------


class TestExploreHelp:
    """generate explore --help exits 0 and shows flags."""

    def test_explore_help_exits_0(self) -> None:
        """generate explore --help exits 0."""
        result = runner.invoke(app, ["generate", "explore", "--help"])
        assert result.exit_code == 0, f"exit_code={result.exit_code}\nstderr={result.stderr}"

    def test_explore_help_shows_chart_flag(self) -> None:
        """--chart flag documented."""
        result = runner.invoke(app, ["generate", "explore", "--help"])
        assert "--chart" in result.stdout, f"Expected --chart in help:\n{result.stdout}"

    def test_explore_help_shows_integrations_flag(self) -> None:
        """--integrations flag documented."""
        result = runner.invoke(app, ["generate", "explore", "--help"])
        assert "--integrations" in result.stdout, (
            f"Expected --integrations in help:\n{result.stdout}"
        )

    def test_explore_help_shows_max_iterations_flag(self) -> None:
        """--max-iterations flag documented."""
        result = runner.invoke(app, ["generate", "explore", "--help"])
        assert "--max-iterations" in result.stdout, (
            f"Expected --max-iterations in help:\n{result.stdout}"
        )

    def test_explore_help_shows_budget_flag(self) -> None:
        """--budget flag documented."""
        result = runner.invoke(app, ["generate", "explore", "--help"])
        assert "--budget" in result.stdout
        assert "--output" in result.stdout
        assert "--force" in result.stdout


class TestExploreEdgeCases:
    """Edge case tests."""

    def test_explore_missing_integrations_exits_nonzero(self, tmp_path: Path) -> None:
        """Empty integrations list exits non-zero."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "",
                "--max-iterations",
                "1",
            ],
            env=env,
        )
        assert result.exit_code != 0, (
            f"Expected non-zero exit for empty integrations, got {result.exit_code}"
        )

    def test_explore_missing_chart_exits_nonzero(self, tmp_path: Path) -> None:
        """Non-existent chart path exits non-zero."""
        count_file = tmp_path / "llm-count.txt"
        env = _make_env(
            {
                "LLM_STUB_MODE": "valid",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                "/tmp/nonexistent-chart",
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "1",
            ],
            env=env,
        )
        assert result.exit_code != 0, (
            f"Expected non-zero exit for missing chart, got {result.exit_code}"
        )

    def test_explore_llm_yaml_parse_error_rejected(self, tmp_path: Path) -> None:
        """LLM emits unparseable YAML → iteration rejected."""
        out_file = tmp_path / "explore-out.json"
        count_file = tmp_path / "llm-count.txt"
        env = _make_env(
            {
                "LLM_STUB_MODE": "invalid-yaml",
                "LLM_STUB_COUNT_FILE": str(count_file),
            }
        )

        result = runner.invoke(
            app,
            [
                "generate",
                "explore",
                "--chart",
                str(CHART_PATH),
                "--integrations",
                "cert-manager",
                "--max-iterations",
                "1",
                "--output",
                str(out_file),
            ],
            env=env,
        )
        # Should exit 0 (iteration was rejected, not a fatal error)
        assert result.exit_code == 0, f"exit_code={result.exit_code}\nstderr={result.stderr}"
        records = json.loads(out_file.read_text())
        assert len(records) == 1
        assert records[0]["status"] == "REJECTED", f"Expected REJECTED, got {records[0]['status']}"
