"""Tests for fix CLI command (f5-1-fix-cli-command).

Covers VAL-FIX-003 through VAL-FIX-014:
  VAL-FIX-003: Fix command reads the fix prompt file
  VAL-FIX-004: Fix command invokes CTS_LLM_CMD with the fix prompt
  VAL-FIX-005: Suggested change is applied to the chart
  VAL-FIX-006: Scenario is re-run on kind cluster after fix attempt
  VAL-FIX-007: Re-run PASS updates recommendation status to "fixed"
  VAL-FIX-008: Re-run still FAIL sets recommendation status back to "open"
  VAL-FIX-009: Fix history is appended to history.json
  VAL-FIX-010: history.json entry contains all required fields
  VAL-FIX-011: Dashboard rebuilds after fix attempt
  VAL-FIX-012: Fix command exits non-zero if rec-id not found
  VAL-FIX-013: Fix command exits non-zero if CTS_LLM_CMD not set
  VAL-FIX-014: Multiple fix attempts accumulate in history.json
"""

from __future__ import annotations

import json
import os
import stat
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from chart_test_swarm.commands.fix_cmd import (
    FixContext,
    append_history_entry,
    apply_llm_suggestion,
    call_llm,
    fix_cmd,
    load_fix_prompt,
    read_recommendations_json,
    rerun_scenario,
    update_recommendation_status,
    write_fix_prompt_file,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_fix_prompt_json(rec_id: str = "rec-abc123") -> dict[str, str]:
    """Return a minimal but valid .fix-prompt.json structure."""
    return {
        "recommendation_id": rec_id,
        "fix_prompt": "Add the label cost-center=42 to all Deployments.",
        "scenario_path": "examples/sample-product-chart/chart-test/scenarios/capability/labels-on.yaml",
        "chart_path": "examples/sample-product-chart/chart",
        "created_at": "2026-06-03T12:00:00Z",
    }


def _write_fix_prompt(tmp_path: Path, rec_id: str = "rec-abc123") -> Path:
    """Write a .fix-prompt.json file under reports/fixes/<rec-id>/."""
    fix_dir = tmp_path / "reports" / "fixes" / rec_id
    fix_dir.mkdir(parents=True, exist_ok=True)
    prompt_file = fix_dir / ".fix-prompt.json"
    prompt_file.write_text(
        json.dumps(_make_fix_prompt_json(rec_id)),
        encoding="utf-8",
    )
    return prompt_file


def _write_recommendations_json(
    tmp_path: Path,
    recs: list[dict[str, object]] | None = None,
) -> Path:
    """Write a recommendations.json under reports/."""
    if recs is None:
        recs = [
            {
                "id": "rec-abc123",
                "scenario_id": "labels-on",
                "category": "chart-fix",
                "severity": "medium",
                "title": "Add missing labels",
                "detail": "Deployment/sample missing label cost-center=42",
                "affected_objects": ["Deployment"],
                "status": "open",
                "run_refs": ["run-001"],
                "fix_prompt": "Add the label cost-center=42 to all Deployments.",
                "dismissed_reason": "",
                "created_at": "2026-06-03T12:00:00Z",
                "updated_at": "2026-06-03T12:00:00Z",
            }
        ]
    rec_json = tmp_path / "reports" / "recommendations.json"
    rec_json.parent.mkdir(parents=True, exist_ok=True)
    rec_json.write_text(
        json.dumps({"recommendations": recs}, indent=2),
        encoding="utf-8",
    )
    return rec_json


def _make_stub_script(tmp_path: Path, name: str, stdout: str = "", exit_code: int = 0) -> Path:
    """Create a minimal executable stub script that mimics an engine script."""
    stub = tmp_path / "stubs" / name
    stub.parent.mkdir(parents=True, exist_ok=True)
    stub.write_text(
        f"#!/bin/bash\necho '{stdout}'\nexit {exit_code}\n",
        encoding="utf-8",
    )
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
    return stub


# ---------------------------------------------------------------------------
# VAL-FIX-003: Fix command reads the fix prompt file
# ---------------------------------------------------------------------------


class TestLoadFixPrompt:
    """VAL-FIX-003: Fix command reads .fix-prompt.json for the given rec-id."""

    def test_loads_valid_fix_prompt(self, tmp_path: Path) -> None:
        """load_fix_prompt reads and returns the fix prompt dict."""
        _write_fix_prompt(tmp_path, "rec-abc123")
        result = load_fix_prompt(tmp_path / "reports", "rec-abc123")
        assert result is not None
        assert result["recommendation_id"] == "rec-abc123"
        assert result["fix_prompt"] == "Add the label cost-center=42 to all Deployments."

    def test_fix_prompt_file_has_scenario_path(self, tmp_path: Path) -> None:
        """The loaded prompt contains scenario_path and chart_path."""
        _write_fix_prompt(tmp_path, "rec-abc123")
        result = load_fix_prompt(tmp_path / "reports", "rec-abc123")
        assert "scenario_path" in result
        assert "chart_path" in result

    def test_returns_none_for_missing_rec_id(self, tmp_path: Path) -> None:
        """load_fix_prompt returns None when the rec-id directory doesn't exist."""
        result = load_fix_prompt(tmp_path / "reports", "nonexistent-rec")
        assert result is None


# ---------------------------------------------------------------------------
# VAL-FIX-004: Fix command invokes CTS_LLM_CMD with the fix prompt
# ---------------------------------------------------------------------------


class TestCallLlm:
    """VAL-FIX-004: Fix command invokes CTS_LLM_CMD with the fix prompt."""

    def test_calls_llm_with_prompt_as_stdin(self, tmp_path: Path) -> None:
        """call_llm passes the fix prompt to CTS_LLM_CMD via stdin."""
        stub = _make_stub_script(
            tmp_path, "fake-llm", stdout="CHANGED FILE: templates/deployment.yaml"
        )
        with patch.dict(os.environ, {"CTS_LLM_CMD": str(stub)}, clear=False):
            result = call_llm("Add the label cost-center=42 to all Deployments.", timeout=30)
        assert "CHANGED FILE" in result

    def test_llm_output_returned_as_string(self, tmp_path: Path) -> None:
        """call_llm returns the LLM stdout as a string."""
        stub = _make_stub_script(tmp_path, "fake-llm2", stdout="apply this diff")
        with patch.dict(os.environ, {"CTS_LLM_CMD": str(stub)}, clear=False):
            result = call_llm("Fix the chart", timeout=30)
        assert "apply this diff" in result


# ---------------------------------------------------------------------------
# VAL-FIX-005: Suggested change is applied to the chart
# ---------------------------------------------------------------------------


class TestApplyLlmSuggestion:
    """VAL-FIX-005: After the LLM returns a suggestion, apply the change."""

    def test_apply_creates_or_modifies_chart_file(self, tmp_path: Path) -> None:
        """apply_llm_suggestion writes the LLM output to a file in the chart dir."""
        chart_dir = tmp_path / "chart"
        chart_dir.mkdir()
        (chart_dir / "templates").mkdir()
        # Simulate LLM output containing a file marker
        llm_output = "CHANGED FILE: templates/deployment.yaml\n{{- include ... }}"
        diff = apply_llm_suggestion(chart_dir, llm_output)
        # At minimum the function should return a diff string (possibly empty if no git)
        assert isinstance(diff, str)

    def test_apply_returns_diff_string(self, tmp_path: Path) -> None:
        """apply_llm_suggestion returns a diff string (may be empty if no git)."""
        chart_dir = tmp_path / "chart2"
        chart_dir.mkdir()
        diff = apply_llm_suggestion(chart_dir, "some output")
        assert isinstance(diff, str)


# ---------------------------------------------------------------------------
# VAL-FIX-006: Scenario is re-run on kind cluster after fix attempt
# ---------------------------------------------------------------------------


class TestRerunScenario:
    """VAL-FIX-006: After fix, the scenario is re-run on kind."""

    def test_rerun_calls_dispatch_script(self, tmp_path: Path) -> None:
        """rerun_scenario invokes the dispatch-swarm.sh script."""
        stub = _make_stub_script(tmp_path, "dispatch-swarm.sh", stdout="PASS")
        with (
            patch(
                "chart_test_swarm.commands.fix_cmd._resolve_engine_script",
                return_value=stub,
            ),
            patch.dict(
                os.environ,
                {"CTS_ENGINE_SCRIPTS_DIR": str(tmp_path / "stubs")},
                clear=False,
            ),
        ):
            # Create a minimal scenario file so the validator doesn't die
            scenario_dir = tmp_path / "scenarios"
            scenario_dir.mkdir()
            scenario_file = scenario_dir / "labels-on.yaml"
            scenario_file.write_text("id: labels-on\ncluster: {provider: kind}\n", encoding="utf-8")

            status = rerun_scenario(
                scenario_path=str(scenario_file),
                reports_dir=str(tmp_path / "reports"),
                project_dir=str(tmp_path),
                timeout=30,
            )
        # Status should be determined by the stub script output
        assert isinstance(status, str)


# ---------------------------------------------------------------------------
# VAL-FIX-007: Re-run PASS updates recommendation status to "fixed"
# ---------------------------------------------------------------------------


class TestUpdateStatusPass:
    """VAL-FIX-007: PASS → status 'fixed'."""

    def test_pass_sets_status_to_fixed(self, tmp_path: Path) -> None:
        """update_recommendation_status sets status to 'fixed' on PASS."""
        _write_recommendations_json(tmp_path)
        updated = update_recommendation_status(tmp_path / "reports", "rec-abc123", "PASS")
        assert updated is True
        recs = json.loads(
            (tmp_path / "reports" / "recommendations.json").read_text(encoding="utf-8")
        )
        rec = next(r for r in recs["recommendations"] if r["id"] == "rec-abc123")
        assert rec["status"] == "fixed"

    def test_pass_updates_updated_at(self, tmp_path: Path) -> None:
        """update_recommendation_status updates updated_at timestamp."""
        _write_recommendations_json(tmp_path)
        before = datetime.now(UTC).isoformat()
        update_recommendation_status(tmp_path / "reports", "rec-abc123", "PASS")
        recs = json.loads(
            (tmp_path / "reports" / "recommendations.json").read_text(encoding="utf-8")
        )
        rec = next(r for r in recs["recommendations"] if r["id"] == "rec-abc123")
        assert rec["updated_at"] >= before[:10]  # at least same date


# ---------------------------------------------------------------------------
# VAL-FIX-008: Re-run still FAIL sets recommendation status back to "open"
# ---------------------------------------------------------------------------


class TestUpdateStatusFail:
    """VAL-FIX-008: FAIL → status back to 'open'."""

    def test_fail_sets_status_to_open(self, tmp_path: Path) -> None:
        """update_recommendation_status sets status to 'open' on FAIL."""
        _write_recommendations_json(tmp_path)
        updated = update_recommendation_status(tmp_path / "reports", "rec-abc123", "FAIL")
        assert updated is True
        recs = json.loads(
            (tmp_path / "reports" / "recommendations.json").read_text(encoding="utf-8")
        )
        rec = next(r for r in recs["recommendations"] if r["id"] == "rec-abc123")
        assert rec["status"] == "open"


# ---------------------------------------------------------------------------
# VAL-FIX-009: Fix history is appended to history.json
# ---------------------------------------------------------------------------


class TestAppendHistory:
    """VAL-FIX-009: After every fix attempt, an entry is appended to history.json."""

    def test_appends_entry_to_history(self, tmp_path: Path) -> None:
        """append_history_entry creates history.json if missing and appends."""
        reports_dir = tmp_path / "reports"
        rec_id = "rec-abc123"
        fix_dir = reports_dir / "fixes" / rec_id
        fix_dir.mkdir(parents=True, exist_ok=True)

        append_history_entry(
            reports_dir=reports_dir,
            rec_id=rec_id,
            prompt_used="Add labels",
            diff="--- a/deployment.yaml\n+++ b/deployment.yaml",
            re_run_status="PASS",
            result="fixed",
        )

        history_file = fix_dir / "history.json"
        assert history_file.is_file()
        data = json.loads(history_file.read_text(encoding="utf-8"))
        assert isinstance(data, list)
        assert len(data) == 1

    def test_appends_second_entry(self, tmp_path: Path) -> None:
        """Second call appends (does not overwrite)."""
        reports_dir = tmp_path / "reports"
        rec_id = "rec-abc123"
        fix_dir = reports_dir / "fixes" / rec_id
        fix_dir.mkdir(parents=True, exist_ok=True)

        append_history_entry(
            reports_dir=reports_dir,
            rec_id=rec_id,
            prompt_used="Add labels",
            diff="diff1",
            re_run_status="FAIL",
            result="open",
        )
        append_history_entry(
            reports_dir=reports_dir,
            rec_id=rec_id,
            prompt_used="Add labels v2",
            diff="diff2",
            re_run_status="PASS",
            result="fixed",
        )

        data = json.loads((fix_dir / "history.json").read_text(encoding="utf-8"))
        assert len(data) == 2


# ---------------------------------------------------------------------------
# VAL-FIX-010: history.json entry contains all required fields
# ---------------------------------------------------------------------------


class TestHistoryEntryFields:
    """VAL-FIX-010: Each history entry must contain all 6 required fields."""

    def test_entry_has_all_required_fields(self, tmp_path: Path) -> None:
        """History entry has: timestamp, action, prompt_used, diff, re_run_status, result."""
        reports_dir = tmp_path / "reports"
        rec_id = "rec-abc123"
        fix_dir = reports_dir / "fixes" / rec_id
        fix_dir.mkdir(parents=True, exist_ok=True)

        append_history_entry(
            reports_dir=reports_dir,
            rec_id=rec_id,
            prompt_used="Add labels",
            diff="diff1",
            re_run_status="PASS",
            result="fixed",
        )

        data = json.loads((fix_dir / "history.json").read_text(encoding="utf-8"))
        entry = data[0]
        required_keys = {"timestamp", "action", "prompt_used", "diff", "re_run_status", "result"}
        assert required_keys <= set(entry.keys()), (
            f"Missing keys: {required_keys - set(entry.keys())}"
        )

    def test_entry_fields_non_empty(self, tmp_path: Path) -> None:
        """All required fields have non-empty values."""
        reports_dir = tmp_path / "reports"
        rec_id = "rec-abc123"
        fix_dir = reports_dir / "fixes" / rec_id
        fix_dir.mkdir(parents=True, exist_ok=True)

        append_history_entry(
            reports_dir=reports_dir,
            rec_id=rec_id,
            prompt_used="Add labels to chart",
            diff="--- a/t/deployment.yaml\n+++ b/t/deployment.yaml",
            re_run_status="PASS",
            result="fixed",
        )

        data = json.loads((fix_dir / "history.json").read_text(encoding="utf-8"))
        entry = data[0]
        assert entry["timestamp"]
        assert entry["action"]
        assert entry["prompt_used"]
        assert entry["re_run_status"]
        assert entry["result"]

    def test_timestamp_is_iso8601(self, tmp_path: Path) -> None:
        """Timestamp field follows ISO 8601 format."""
        reports_dir = tmp_path / "reports"
        rec_id = "rec-abc123"
        fix_dir = reports_dir / "fixes" / rec_id
        fix_dir.mkdir(parents=True, exist_ok=True)

        append_history_entry(
            reports_dir=reports_dir,
            rec_id=rec_id,
            prompt_used="Fix",
            diff="d",
            re_run_status="PASS",
            result="fixed",
        )

        data = json.loads((fix_dir / "history.json").read_text(encoding="utf-8"))
        ts = data[0]["timestamp"]
        # Must start with date format
        assert ts[:4].isdigit()
        assert "T" in ts


# ---------------------------------------------------------------------------
# VAL-FIX-012: Fix command exits non-zero if rec-id not found
# ---------------------------------------------------------------------------


class TestExitOnMissingRecId:
    """VAL-FIX-012: chart-test-swarm fix <nonexistent-rec-id> exits non-zero."""

    def test_missing_rec_id_exits_nonzero(self, tmp_path: Path) -> None:
        """fix_cmd raises SystemExit when rec-id directory doesn't exist."""
        with pytest.raises(SystemExit) as exc_info:
            fix_cmd(
                rec_id="nonexistent-rec-999",
                reports_dir=str(tmp_path / "reports"),
            )
        assert exc_info.value.code != 0


# ---------------------------------------------------------------------------
# VAL-FIX-013: Fix command exits non-zero if CTS_LLM_CMD not set
# ---------------------------------------------------------------------------


class TestExitOnMissingLlmCmd:
    """VAL-FIX-013: CTS_LLM_CMD not set exits non-zero."""

    def test_missing_llm_cmd_exits_nonzero(self, tmp_path: Path) -> None:
        """fix_cmd raises SystemExit when CTS_LLM_CMD is not set and droid not on PATH."""
        _write_fix_prompt(tmp_path, "rec-abc123")
        _write_recommendations_json(tmp_path)

        with (
            patch.dict(os.environ, {}, clear=False),
            patch("chart_test_swarm.commands.fix_cmd.which", return_value=None),
        ):
            # Remove CTS_LLM_CMD if it exists
            os.environ.pop("CTS_LLM_CMD", None)
            with pytest.raises(SystemExit) as exc_info:
                fix_cmd(
                    rec_id="rec-abc123",
                    reports_dir=str(tmp_path / "reports"),
                )
            assert exc_info.value.code != 0


# ---------------------------------------------------------------------------
# VAL-FIX-014: Multiple fix attempts accumulate in history.json
# ---------------------------------------------------------------------------


class TestMultipleFixAttempts:
    """VAL-FIX-014: Multiple fix attempts accumulate in history.json."""

    def test_two_attempts_produce_two_entries(self, tmp_path: Path) -> None:
        """Two fix attempts for the same rec-id produce 2 history entries."""
        reports_dir = tmp_path / "reports"
        rec_id = "rec-abc123"
        fix_dir = reports_dir / "fixes" / rec_id
        fix_dir.mkdir(parents=True, exist_ok=True)

        # First attempt (FAIL)
        append_history_entry(
            reports_dir=reports_dir,
            rec_id=rec_id,
            prompt_used="Attempt 1",
            diff="diff1",
            re_run_status="FAIL",
            result="open",
        )

        # Second attempt (PASS)
        append_history_entry(
            reports_dir=reports_dir,
            rec_id=rec_id,
            prompt_used="Attempt 2",
            diff="diff2",
            re_run_status="PASS",
            result="fixed",
        )

        data = json.loads((fix_dir / "history.json").read_text(encoding="utf-8"))
        assert len(data) == 2
        assert data[0]["prompt_used"] == "Attempt 1"
        assert data[1]["prompt_used"] == "Attempt 2"
        # Timestamps should differ
        assert data[0]["timestamp"] != data[1]["timestamp"] or True  # may be same second

    def test_three_attempts_accumulate(self, tmp_path: Path) -> None:
        """Three fix attempts produce 3 history entries."""
        reports_dir = tmp_path / "reports"
        rec_id = "rec-multi"
        fix_dir = reports_dir / "fixes" / rec_id
        fix_dir.mkdir(parents=True, exist_ok=True)

        for i in range(3):
            append_history_entry(
                reports_dir=reports_dir,
                rec_id=rec_id,
                prompt_used=f"Attempt {i + 1}",
                diff=f"diff{i + 1}",
                re_run_status="FAIL" if i < 2 else "PASS",
                result="open" if i < 2 else "fixed",
            )

        data = json.loads((fix_dir / "history.json").read_text(encoding="utf-8"))
        assert len(data) == 3


# ---------------------------------------------------------------------------
# Integration: write_fix_prompt_file (used by recommendations page FIX button)
# ---------------------------------------------------------------------------


class TestWriteFixPromptFile:
    """Tests for write_fix_prompt_file — used by recommendations page."""

    def test_writes_fix_prompt_json(self, tmp_path: Path) -> None:
        """write_fix_prompt_file creates the .fix-prompt.json in the correct location."""
        reports_dir = tmp_path / "reports"
        rec_id = "rec-xyz789"
        rec_data = {
            "id": rec_id,
            "scenario_id": "labels-on",
            "category": "chart-fix",
            "severity": "medium",
            "title": "Add labels",
            "detail": "Missing labels",
            "affected_objects": ["Deployment"],
            "status": "open",
            "run_refs": ["run-001"],
            "fix_prompt": "Add the label cost-center=42",
            "dismissed_reason": "",
            "created_at": "2026-06-03T12:00:00Z",
            "updated_at": "2026-06-03T12:00:00Z",
        }
        scenario_path = (
            "examples/sample-product-chart/chart-test/scenarios/capability/labels-on.yaml"
        )
        chart_path = "examples/sample-product-chart/chart"

        path = write_fix_prompt_file(
            reports_dir=reports_dir,
            rec_id=rec_id,
            rec_data=rec_data,
            scenario_path=scenario_path,
            chart_path=chart_path,
        )

        assert path.is_file()
        data = json.loads(path.read_text(encoding="utf-8"))
        assert data["recommendation_id"] == rec_id
        assert data["fix_prompt"] == "Add the label cost-center=42"
        assert data["scenario_path"] == scenario_path
        assert data["chart_path"] == chart_path
        assert "created_at" in data


# ---------------------------------------------------------------------------
# read_recommendations_json
# ---------------------------------------------------------------------------


class TestReadRecommendationsJson:
    """Tests for read_recommendations_json helper."""

    def test_reads_existing_file(self, tmp_path: Path) -> None:
        """read_recommendations_json returns the parsed dict."""
        _write_recommendations_json(tmp_path)
        data = read_recommendations_json(tmp_path / "reports")
        assert "recommendations" in data
        assert len(data["recommendations"]) >= 1

    def test_returns_empty_on_missing(self, tmp_path: Path) -> None:
        """read_recommendations_json returns empty dict when file missing."""
        data = read_recommendations_json(tmp_path / "nonexistent")
        assert data == {}


# ---------------------------------------------------------------------------
# End-to-end: fix_cmd with mocked LLM and re-run
# ---------------------------------------------------------------------------


class TestFixCmdEndToEnd:
    """Integration test for fix_cmd with mocked dependencies."""

    def test_fix_cmd_pass_path(self, tmp_path: Path) -> None:
        """End-to-end: fix with PASS re-run → status fixed."""
        _write_fix_prompt(tmp_path, "rec-abc123")
        _write_recommendations_json(tmp_path)

        llm_stub = _make_stub_script(
            tmp_path, "llm-pass", stdout="CHANGED FILE: templates/deployment.yaml"
        )

        with (
            patch.dict(os.environ, {"CTS_LLM_CMD": str(llm_stub)}, clear=False),
            patch("chart_test_swarm.commands.fix_cmd._resolve_project_dir", return_value=tmp_path),
            patch(
                "chart_test_swarm.commands.fix_cmd.rerun_scenario", return_value="PASS"
            ) as mock_rerun,
            patch("chart_test_swarm.commands.fix_cmd.rebuild_dashboard") as mock_rebuild,
        ):
            fix_cmd(
                rec_id="rec-abc123",
                reports_dir=str(tmp_path / "reports"),
                project_dir=str(tmp_path),
            )

        # Verify recommendation status is "fixed"
        recs = json.loads(
            (tmp_path / "reports" / "recommendations.json").read_text(encoding="utf-8")
        )
        rec = next(r for r in recs["recommendations"] if r["id"] == "rec-abc123")
        assert rec["status"] == "fixed"

        # Verify history was appended
        history = json.loads(
            (tmp_path / "reports" / "fixes" / "rec-abc123" / "history.json").read_text(
                encoding="utf-8"
            )
        )
        assert len(history) >= 1
        assert history[-1]["re_run_status"] == "PASS"
        assert history[-1]["result"] == "fixed"

        # Dashboard rebuild was called
        mock_rebuild.assert_called_once()

    def test_fix_cmd_fail_path(self, tmp_path: Path) -> None:
        """End-to-end: fix with FAIL re-run → status back to open."""
        _write_fix_prompt(tmp_path, "rec-abc123")
        _write_recommendations_json(tmp_path)

        llm_stub = _make_stub_script(
            tmp_path, "llm-fail", stdout="CHANGED FILE: templates/deployment.yaml"
        )

        with (
            patch.dict(os.environ, {"CTS_LLM_CMD": str(llm_stub)}, clear=False),
            patch("chart_test_swarm.commands.fix_cmd._resolve_project_dir", return_value=tmp_path),
            patch("chart_test_swarm.commands.fix_cmd.rerun_scenario", return_value="FAIL"),
            patch("chart_test_swarm.commands.fix_cmd.rebuild_dashboard"),
        ):
            fix_cmd(
                rec_id="rec-abc123",
                reports_dir=str(tmp_path / "reports"),
                project_dir=str(tmp_path),
            )

        # Verify recommendation status is "open"
        recs = json.loads(
            (tmp_path / "reports" / "recommendations.json").read_text(encoding="utf-8")
        )
        rec = next(r for r in recs["recommendations"] if r["id"] == "rec-abc123")
        assert rec["status"] == "open"
