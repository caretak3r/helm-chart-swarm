"""Tests for M3 dashboard run discovery: list_runs() durable discovery.

Covers:
  VAL-DASHBOARD-001: Non-run- prefixed dir with run-meta.yaml is discovered
  VAL-DASHBOARD-002: Real dir + symlink sharing a run_id yield exactly one run
  VAL-DASHBOARD-003: Existing run-* runs still listed; run-test-* still excluded
"""

from __future__ import annotations

import os
from pathlib import Path

import yaml

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_run_meta(run_dir: Path, run_id: str) -> None:
    """Write a minimal run-meta.yaml into *run_dir*."""
    meta = {"run_id": run_id, "timestamp_utc": "2026-01-01T00:00:00Z", "num_agents": 1}
    (run_dir / "run-meta.yaml").write_text(yaml.dump(meta))


def _make_valid_run_dir(reports: Path, dir_name: str, run_id: str) -> Path:
    """Create a minimal valid run directory with run-meta.yaml."""
    d = reports / dir_name
    d.mkdir(parents=True, exist_ok=True)
    _write_run_meta(d, run_id)
    # Also add a scenarios-snapshot to avoid orphan-detection
    (d / "scenarios-snapshot.yaml").write_text("scenarios: []\n")
    return d


# ---------------------------------------------------------------------------
# VAL-DASHBOARD-001: Non-run- prefixed run is discovered
# ---------------------------------------------------------------------------


class TestNonRunPrefixedDirDiscovered:
    """VAL-DASHBOARD-001: A run directory that contains a valid run-meta.yaml
    MUST be listed even when its directory name does NOT start with `run-`."""

    def test_sealed_dir_with_meta_discovered(self, tmp_path: Path) -> None:
        """A dir named 'sealed-clean-6' with valid run-meta.yaml IS listed."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        _make_valid_run_dir(reports, "sealed-clean-6", "sealed-clean-6")

        runs = list_runs(reports)
        assert "sealed-clean-6" in runs, (
            "Non-run--prefixed dir with valid run-meta.yaml must be discovered"
        )

    def test_dir_without_run_meta_skipped(self, tmp_path: Path) -> None:
        """A dir without run-meta.yaml is skipped."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        d = reports / "some-random-dir"
        d.mkdir()

        runs = list_runs(reports)
        assert "some-random-dir" not in runs, (
            "Directories without valid run-meta.yaml must be skipped"
        )

    def test_dir_with_missing_run_id_skipped(self, tmp_path: Path) -> None:
        """A dir with run-meta.yaml but no run_id key is skipped."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        d = reports / "no-run-id"
        d.mkdir()
        (d / "run-meta.yaml").write_text("num_agents: 1\n")

        runs = list_runs(reports)
        assert "no-run-id" not in runs, (
            "Directories whose run-meta.yaml lacks run_id must be skipped"
        )

    def test_dir_with_empty_run_id_skipped(self, tmp_path: Path) -> None:
        """A dir with an empty run_id in run-meta.yaml is skipped."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        d = reports / "empty-run-id"
        d.mkdir()
        (d / "run-meta.yaml").write_text("run_id:\n")

        runs = list_runs(reports)
        assert "empty-run-id" not in runs, (
            "Directories with empty run_id must be skipped"
        )

    def test_dir_with_corrupt_yaml_skipped(self, tmp_path: Path) -> None:
        """A dir with a corrupt/unparseable run-meta.yaml is skipped without crash."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        d = reports / "corrupt-meta"
        d.mkdir()
        (d / "run-meta.yaml").write_text("{ this is not valid yaml: [\n")

        runs = list_runs(reports)
        assert "corrupt-meta" not in runs, (
            "Directories with unparseable run-meta.yaml must be skipped without crash"
        )

    def test_multiple_non_run_prefix_dirs_discovered(self, tmp_path: Path) -> None:
        """Multiple non-run--prefixed dirs are all discovered."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        _make_valid_run_dir(reports, "sealed-clean-6", "sealed-clean-6")
        _make_valid_run_dir(reports, "sealed-final-3", "sealed-final-3")

        runs = list_runs(reports)
        assert "sealed-clean-6" in runs
        assert "sealed-final-3" in runs

    def test_scenario_dirs_without_meta_not_listed(self, tmp_path: Path) -> None:
        """scenario-* dirs without run-meta.yaml are NOT listed by list_runs()
        (they are single-scenario dirs handled separately)."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        d = reports / "scenario-some-test-20260601-010101"
        d.mkdir()
        # No run-meta.yaml, just a result.yaml
        (d / "result.yaml").write_text("scenario_id: some-test\nstatus: PASS\n")

        runs = list_runs(reports)
        assert "scenario-some-test-20260601-010101" not in runs, (
            "scenario-* dirs without run-meta.yaml are single-scenario results, "
            "not run-level directories"
        )


# ---------------------------------------------------------------------------
# VAL-DASHBOARD-002: Runs de-duplicated by run_id
# ---------------------------------------------------------------------------


class TestRunDedupByRunId:
    """VAL-DASHBOARD-002: When two directories share a run_id, exactly ONE entry
    is produced."""

    def test_real_dir_and_symlink_dedup_to_one(self, tmp_path: Path) -> None:
        """A real dir 'sealed-clean-6' and a symlink 'run-sealed-clean-6'
        pointing to it share one run_id and collapse to exactly one entry."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        real_dir = _make_valid_run_dir(reports, "sealed-clean-6", "sealed-clean-6")
        symlink = reports / "run-sealed-clean-6"
        os.symlink(str(real_dir), str(symlink))

        runs = list_runs(reports)
        # Both share run_id "sealed-clean-6" — exactly one entry
        count = sum(1 for r in runs if r in ("sealed-clean-6", "run-sealed-clean-6"))
        assert count == 1, (
            f"Expected exactly 1 entry for run_id 'sealed-clean-6', got {count}: {runs}"
        )

    def test_dedup_prefers_real_dir_over_symlink(self, tmp_path: Path) -> None:
        """When deduplicating, the real directory is preferred over the symlink
        (deterministic tie-break)."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        real_dir = _make_valid_run_dir(reports, "sealed-clean-6", "sealed-clean-6")
        symlink = reports / "run-sealed-clean-6"
        os.symlink(str(real_dir), str(symlink))

        runs = list_runs(reports)
        # The real dir name should be the one kept
        assert "sealed-clean-6" in runs, "Real directory should be the dedup winner"

    def test_dedup_prefers_shorter_name_when_both_real(self, tmp_path: Path) -> None:
        """When both directories with the same run_id are real dirs (not symlinks),
        prefer the shorter directory name for determinism."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        _make_valid_run_dir(reports, "long-name-a", "shared-run-id")
        _make_valid_run_dir(reports, "short-a", "shared-run-id")

        runs = list_runs(reports)
        # Both share run_id "shared-run-id" — only one should appear
        count = sum(1 for r in runs if r in ("long-name-a", "short-a"))
        assert count == 1, f"Expected 1 entry, got {count}: {runs}"
        # The shorter name should win
        assert "short-a" in runs, "Shorter directory name should be the dedup winner"

    def test_dedup_prefers_shorter_name_when_both_symlinks(self, tmp_path: Path) -> None:
        """When both entries sharing a run_id are symlinks, prefer the shorter name."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        # Create a real dir to symlink to
        real_dir = _make_valid_run_dir(reports, "real-target", "shared-run-id")

        symlink_long = reports / "symlink-long-name-x"
        symlink_short = reports / "sym-short"
        os.symlink(str(real_dir), str(symlink_long))
        os.symlink(str(real_dir), str(symlink_short))

        runs = list_runs(reports)
        # All three share run_id "shared-run-id" — exactly one entry
        candidates = {"real-target", "symlink-long-name-x", "sym-short"}
        count = sum(1 for r in runs if r in candidates)
        assert count == 1, f"Expected 1 entry, got {count}: {runs}"
        # The real dir should win (real over symlink)
        assert "real-target" in runs, "Real directory should be the dedup winner"


# ---------------------------------------------------------------------------
# VAL-DASHBOARD-003: Backward compatibility preserved
# ---------------------------------------------------------------------------


class TestBackwardCompatibility:
    """VAL-DASHBOARD-003: Existing run-* runs still appear; run-test-* excluded."""

    def test_existing_run_prefixed_runs_still_listed(self, tmp_path: Path) -> None:
        """run-* directories with valid run-meta.yaml are still listed."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        _make_valid_run_dir(reports, "run-full-bench-final-4", "run-full-bench-final-4")
        _make_valid_run_dir(reports, "run-20260520-101500", "run-20260520-101500")

        runs = list_runs(reports)
        assert "run-full-bench-final-4" in runs, "Existing run-* run must still be listed"
        assert "run-20260520-101500" in runs, "Existing run-* run must still be listed"

    def test_run_test_dirs_always_excluded(self, tmp_path: Path) -> None:
        """run-test-* directories are ALWAYS excluded, even if they have
        valid run-meta.yaml."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        # Create a run-test-* dir with valid run-meta.yaml
        d = reports / "run-test-20260601-070133-7511"
        d.mkdir()
        _write_run_meta(d, "some-run-id")
        (d / "scenarios-snapshot.yaml").write_text("scenarios: []\n")

        runs = list_runs(reports)
        assert "run-test-20260601-070133-7511" not in runs, (
            "run-test-* dirs must always be excluded regardless of content"
        )

    def test_mixed_prefix_scenario(self, tmp_path: Path) -> None:
        """A mix of run-*, non-run-, run-test-*, and bare dirs: only valid
        run dirs (excluding run-test-*) appear."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        _make_valid_run_dir(reports, "run-full-bench-final-4", "run-full-bench-final-4")
        _make_valid_run_dir(reports, "sealed-clean-6", "sealed-clean-6")
        # run-test-* with run-meta.yaml (should be excluded)
        d_test = reports / "run-test-20260601-070133-7511"
        d_test.mkdir()
        _write_run_meta(d_test, "some-id")
        (d_test / "scenarios-snapshot.yaml").write_text("scenarios: []\n")
        # Bare dir without run-meta
        (reports / "no-meta-here").mkdir()

        runs = list_runs(reports)
        assert "run-full-bench-final-4" in runs
        assert "sealed-clean-6" in runs
        assert "run-test-20260601-070133-7511" not in runs
        assert "no-meta-here" not in runs

    def test_excludes_empty_reports_dir(self, tmp_path: Path) -> None:
        """Empty reports dir returns empty list."""
        from testgrid.collect import list_runs

        reports = tmp_path / "reports"
        reports.mkdir()
        runs = list_runs(reports)
        assert runs == []

    def test_excludes_nonexistent_reports_dir(self) -> None:
        """Nonexistent reports dir returns empty list, no crash."""
        from testgrid.collect import list_runs

        runs = list_runs(Path("/nonexistent/path/12345"))
        assert runs == []
