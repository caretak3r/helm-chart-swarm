"""Tests for f-misc-5: pytest temp-reports isolation.

Validates:
  - Integration tests that invoke build/render write run dirs into
    pytest tmp_path (or a temp directory OUTSIDE reports/), never into
    engine/testgrid/reports/ or the repo reports/.
  - list_runs() skips run-test-* dirs so accidental test writes don't
    pollute the dashboard build with orphan warnings.
  - After a full pytest run, reports/ contains no newly-created
    run-test-* orphan dirs.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

# Repo root: engine/testgrid/tests/ -> parents[3] = chart-test-swarm/
REPO_ROOT = Path(__file__).resolve().parents[3]
ENGINE_TESTGRID_REPORTS = REPO_ROOT / "engine" / "testgrid" / "reports"
REPO_REPORTS = REPO_ROOT / "reports"
RUN_STUB_PATH = REPO_ROOT / "engine" / "testgrid" / "tests" / "stubs" / "run-stub.sh"
STUB_PATH = REPO_ROOT / "engine" / "testgrid" / "tests" / "stubs" / "llm-stub.sh"


class TestRunStubReportsDirIsolation:
    """run-stub.sh must respect REPORTS_DIR and write outside the real
    reports/ tree."""

    def test_run_stub_uses_reports_dir_env_var(self, tmp_path: Path) -> None:
        """When REPORTS_DIR is set, run-stub.sh writes there, not to
        engine/testgrid/reports/."""
        target_dir = tmp_path / "test-reports"
        target_dir.mkdir()

        env = os.environ.copy()
        env["REPORTS_DIR"] = str(target_dir)

        result = subprocess.run(
            ["bash", str(RUN_STUB_PATH)],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0, f"run-stub.sh failed: {result.stderr}"

        # The stub should have created a run-test-* dir under target_dir
        test_runs = list(target_dir.glob("run-test-*"))
        assert len(test_runs) >= 1, (
            f"run-stub.sh did not write to REPORTS_DIR={target_dir}; "
            f"found dirs: {list(target_dir.iterdir())}"
        )

        # Verify result.yaml was written inside
        result_yaml = test_runs[0] / "result.yaml"
        assert result_yaml.is_file(), f"result.yaml missing in {test_runs[0]}"

    def test_run_stub_no_orphans_in_engine_testgrid_reports(self, tmp_path: Path) -> None:
        """After running run-stub.sh with REPORTS_DIR set, no new dirs
        appear under engine/testgrid/reports/."""
        # Snapshot before
        before = (
            set(
                p.name
                for p in ENGINE_TESTGRID_REPORTS.iterdir()
                if p.is_dir() and p.name.startswith("run-test-")
            )
            if ENGINE_TESTGRID_REPORTS.is_dir()
            else set()
        )

        target_dir = tmp_path / "test-reports"
        target_dir.mkdir()
        env = os.environ.copy()
        env["REPORTS_DIR"] = str(target_dir)

        subprocess.run(
            ["bash", str(RUN_STUB_PATH)],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )

        # Snapshot after
        after = (
            set(
                p.name
                for p in ENGINE_TESTGRID_REPORTS.iterdir()
                if p.is_dir() and p.name.startswith("run-test-")
            )
            if ENGINE_TESTGRID_REPORTS.is_dir()
            else set()
        )

        new_orphans = after - before
        assert new_orphans == set(), (
            f"run-stub.sh created orphan dirs in engine/testgrid/reports/: {new_orphans}"
        )

    def test_run_stub_writes_result_yaml_under_reports_dir(self, tmp_path: Path) -> None:
        """run-stub.sh creates a valid result.yaml with run_id starting
        with run-test- under REPORTS_DIR."""
        target_dir = tmp_path / "test-reports"
        target_dir.mkdir()

        env = os.environ.copy()
        env["REPORTS_DIR"] = str(target_dir)

        result = subprocess.run(
            ["bash", str(RUN_STUB_PATH)],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0

        # The stdout should contain the generated run ID
        run_id = result.stdout.strip()
        assert run_id.startswith("run-test-"), f"Expected run-test-* ID, got: {run_id}"

        # The dir should exist under REPORTS_DIR
        run_dir = target_dir / run_id
        assert run_dir.is_dir(), f"Run dir not found at {run_dir}"
        assert (run_dir / "result.yaml").is_file()
        assert (run_dir / "artifacts").is_dir()


class TestListRunsSkipsTestPrefix:
    """list_runs() must skip run-test-* dirs to prevent thousands of
    orphan warnings during testgrid build."""

    def test_list_runs_skips_run_test_dirs(self, tmp_path: Path) -> None:
        """list_runs() excludes directories matching run-test-*."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()

        # Create a real run dir
        (reports / "run-20260520-101500").mkdir()
        (reports / "run-20260520-101500" / "scenarios-snapshot.yaml").write_text("scenarios: []")

        # Create test-prefixed dirs (what run-stub.sh produces)
        (reports / "run-test-20260601-070133-7511").mkdir()
        (reports / "run-test-20260601-070134-7540").mkdir()

        runs = list_runs(reports)
        assert "run-20260520-101500" in runs, "Real run should be listed"
        assert "run-test-20260601-070133-7511" not in runs, (
            "run-test-* dirs should be excluded from list_runs()"
        )
        assert "run-test-20260601-070134-7540" not in runs, (
            "run-test-* dirs should be excluded from list_runs()"
        )

    def test_list_runs_includes_non_test_runs(self, tmp_path: Path) -> None:
        """list_runs() includes run-* dirs that don't have the test prefix."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()

        (reports / "run-20260520-101500").mkdir()
        (reports / "run-20260520-101501").mkdir()
        (reports / "run-f11-2-real-20260601-222435").mkdir()

        runs = list_runs(reports)
        assert "run-20260520-101500" in runs
        assert "run-20260520-101501" in runs
        assert "run-f11-2-real-20260601-222435" in runs

    def test_collect_run_skips_run_test_orphans_gracefully(self, tmp_path: Path) -> None:
        """collect_run() on a run-test-* dir raises OrphanRunError,
        not a crash."""
        from testgrid.collect import OrphanRunError, collect_run

        reports = tmp_path / "reports"
        reports.mkdir()
        test_dir = reports / "run-test-20260601-070133-7511"
        test_dir.mkdir()
        # Write a minimal result.yaml so it looks like a stub output
        (test_dir / "result.yaml").write_text(
            'run_id: "run-test-20260601-070133-7511"\nstatus: PASS\nscenarios: []\n'
        )

        with pytest.raises(OrphanRunError):
            collect_run(reports, "run-test-20260601-070133-7511")


class TestNoOrphanDirsAfterFullSuite:
    """After running the pytest suite, no new run-test-* dirs should
    appear under the real reports directories."""

    def test_engine_testgrid_reports_has_no_run_test_dirs(self) -> None:
        """engine/testgrid/reports/ should have zero run-test-* dirs
        (they should have been cleaned up)."""
        if not ENGINE_TESTGRID_REPORTS.is_dir():
            pytest.skip("engine/testgrid/reports/ does not exist yet")

        orphans = list(ENGINE_TESTGRID_REPORTS.glob("run-test-*"))
        assert orphans == [], (
            f"Found {len(orphans)} orphaned run-test-* dirs in "
            f"engine/testgrid/reports/. These should be cleaned up. "
            f"First 5: {[p.name for p in orphans[:5]]}"
        )

    def test_repo_reports_has_no_run_test_dirs(self) -> None:
        """The repo root reports/ should have zero run-test-* dirs."""
        if not REPO_REPORTS.is_dir():
            pytest.skip("reports/ does not exist yet")

        orphans = list(REPO_REPORTS.glob("run-test-*"))
        assert orphans == [], (
            f"Found {len(orphans)} orphaned run-test-* dirs in reports/. "
            f"These should be cleaned up. "
            f"First 5: {[p.name for p in orphans[:5]]}"
        )
