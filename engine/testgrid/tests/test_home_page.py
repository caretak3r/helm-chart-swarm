"""Tests for the home page landing page feature (f1-1-home-page-template).

Covers:
  VAL-HOME-001: home.html loads without errors (rendered without blank content)
  VAL-HOME-002: Four navigation cards are visible on home page
  VAL-HOME-006: Home page displays summary metric for matrix coverage
  VAL-HOME-007: Home page displays summary metric for run count
  VAL-HOME-008: Home page displays summary metric for open recommendation count
"""

from __future__ import annotations

from pathlib import Path

import pytest

from testgrid.collect import Run, Scenario
from testgrid.render import HomeSummary, render_home, render_runs


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_run(run_id: str, scenario_count: int = 2) -> Run:
    """Create a minimal Run with *scenario_count* PASS scenarios."""
    scenarios = [
        Scenario(id=f"scn-{i}", name=f"Scenario {i}", status="PASS") for i in range(scenario_count)
    ]
    return Run(run_id=run_id, scenarios=scenarios)


# ---------------------------------------------------------------------------
# render_home() — basic output
# ---------------------------------------------------------------------------


class TestRenderHome:
    """Tests for render_home() function."""

    def test_produces_home_html(self, tmp_path: Path) -> None:
        """render_home() writes home.html to the output directory."""
        summary = HomeSummary(run_count=3, coverage_pct=72.0, open_rec_count=2)
        result = render_home(summary, tmp_path)
        assert result == tmp_path / "home.html"
        assert result.is_file()

    def test_home_html_is_valid_html(self, tmp_path: Path) -> None:
        """home.html must contain an <html> element with non-empty content."""
        summary = HomeSummary(run_count=1, coverage_pct=50.0, open_rec_count=0)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert "<html" in html
        assert "</html>" in html
        assert len(html) > 200  # Must have substantive content

    def test_home_html_has_four_cards(self, tmp_path: Path) -> None:
        """home.html must contain all four navigation card labels (VAL-HOME-002)."""
        summary = HomeSummary(run_count=5, coverage_pct=80.0, open_rec_count=3)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert "Support Matrix" in html
        assert "Run History" in html
        assert "Recommendations" in html
        assert "Versions" in html

    def test_home_html_cards_link_to_pages(self, tmp_path: Path) -> None:
        """Each card must link to its respective page."""
        summary = HomeSummary(run_count=2, coverage_pct=60.0, open_rec_count=1)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert "support-matrix.html" in html
        assert "runs.html" in html
        assert "recommendations.html" in html
        assert "versions.html" in html

    def test_home_html_shows_run_count(self, tmp_path: Path) -> None:
        """home.html must display the run count metric (VAL-HOME-007)."""
        summary = HomeSummary(run_count=7, coverage_pct=55.0, open_rec_count=0)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert "7" in html  # run count

    def test_home_html_shows_coverage_pct(self, tmp_path: Path) -> None:
        """home.html must display the coverage percentage metric (VAL-HOME-006)."""
        summary = HomeSummary(run_count=3, coverage_pct=72.5, open_rec_count=0)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert "72" in html  # coverage pct

    def test_home_html_shows_open_rec_count(self, tmp_path: Path) -> None:
        """home.html must display the open recommendation count (VAL-HOME-008)."""
        summary = HomeSummary(run_count=2, coverage_pct=40.0, open_rec_count=5)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert "5" in html  # open rec count

    def test_home_html_shows_version_status(self, tmp_path: Path) -> None:
        """home.html must display a version config status string."""
        summary = HomeSummary(
            run_count=1, coverage_pct=0.0, open_rec_count=0, version_status="configured"
        )
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert "configured" in html.lower()

    def test_home_html_copies_style_css(self, tmp_path: Path) -> None:
        """render_home() must copy style.css alongside home.html."""
        summary = HomeSummary(run_count=0)
        render_home(summary, tmp_path)
        assert (tmp_path / "style.css").is_file()

    def test_home_html_zero_runs_still_renders(self, tmp_path: Path) -> None:
        """render_home() must work with zero runs without crashing."""
        summary = HomeSummary(run_count=0, coverage_pct=0.0, open_rec_count=0)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert "<html" in html
        # Zero values should still be displayed (not blank)
        assert "0" in html

    def test_home_html_coverage_pct_displayed_as_number(self, tmp_path: Path) -> None:
        """Coverage must render as a numeric value, not 'undefined' or 'NaN'."""
        summary = HomeSummary(run_count=1, coverage_pct=100.0, open_rec_count=0)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert "undefined" not in html
        assert "NaN" not in html
        assert "100" in html  # 100% coverage

    def test_home_html_cards_have_clickable_links(self, tmp_path: Path) -> None:
        """Each card must be a clickable anchor (href) not just text."""
        summary = HomeSummary(run_count=1, coverage_pct=50.0, open_rec_count=0)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert 'href="support-matrix.html"' in html
        assert 'href="runs.html"' in html
        assert 'href="recommendations.html"' in html
        assert 'href="versions.html"' in html

    def test_home_summary_default_values(self) -> None:
        """HomeSummary dataclass has sensible defaults."""
        summary = HomeSummary()
        assert summary.run_count == 0
        assert summary.coverage_pct == 0.0
        assert summary.open_rec_count == 0
        assert summary.version_status == "default"

    def test_render_home_creates_output_dir(self, tmp_path: Path) -> None:
        """render_home() must create the output dir if it does not exist."""
        out_dir = tmp_path / "new_dir"
        assert not out_dir.exists()
        summary = HomeSummary(run_count=1)
        render_home(summary, out_dir)
        assert out_dir.is_dir()
        assert (out_dir / "home.html").is_file()


# ---------------------------------------------------------------------------
# render_runs() — produces runs.html
# ---------------------------------------------------------------------------


class TestRenderRuns:
    """Tests for render_runs() function."""

    def test_produces_runs_html(self, tmp_path: Path) -> None:
        """render_runs() writes runs.html (not index.html) to the output directory."""
        runs = [_make_run("run-001")]
        result = render_runs(runs, tmp_path)
        assert result == tmp_path / "runs.html"
        assert result.is_file()

    def test_runs_html_is_valid_html(self, tmp_path: Path) -> None:
        """runs.html must contain <html> with non-empty content."""
        runs = [_make_run("run-001"), _make_run("run-002")]
        render_runs(runs, tmp_path)
        html = (tmp_path / "runs.html").read_text(encoding="utf-8")
        assert "<html" in html
        assert "</html>" in html

    def test_runs_html_lists_runs(self, tmp_path: Path) -> None:
        """runs.html must display the run IDs."""
        runs = [_make_run("run-alpha"), _make_run("run-beta")]
        render_runs(runs, tmp_path)
        html = (tmp_path / "runs.html").read_text(encoding="utf-8")
        assert "run-alpha" in html
        assert "run-beta" in html

    def test_runs_html_sorted_descending(self, tmp_path: Path) -> None:
        """Runs must be sorted in reverse chronological (desc) order by run_id."""
        runs = [_make_run("run-20260101"), _make_run("run-20260103"), _make_run("run-20260102")]
        render_runs(runs, tmp_path)
        html = (tmp_path / "runs.html").read_text(encoding="utf-8")
        pos1 = html.find("run-20260103")
        pos2 = html.find("run-20260102")
        pos3 = html.find("run-20260101")
        assert pos1 < pos2 < pos3, "Runs must appear in descending order by run_id"

    def test_runs_html_copies_style_css(self, tmp_path: Path) -> None:
        """render_runs() must copy style.css alongside runs.html."""
        runs = [_make_run("run-001")]
        render_runs(runs, tmp_path)
        assert (tmp_path / "style.css").is_file()

    def test_runs_html_empty_runs(self, tmp_path: Path) -> None:
        """render_runs() must work with an empty list without crashing."""
        render_runs([], tmp_path)
        html = (tmp_path / "runs.html").read_text(encoding="utf-8")
        assert "<html" in html

    def test_runs_html_does_not_produce_index_html(self, tmp_path: Path) -> None:
        """render_runs() must not create index.html — only runs.html."""
        runs = [_make_run("run-001")]
        render_runs(runs, tmp_path)
        assert not (tmp_path / "index.html").exists()
        assert (tmp_path / "runs.html").exists()

    def test_render_runs_creates_output_dir(self, tmp_path: Path) -> None:
        """render_runs() must create the output dir if it does not exist."""
        out_dir = tmp_path / "new_dir"
        assert not out_dir.exists()
        render_runs([], out_dir)
        assert out_dir.is_dir()
        assert (out_dir / "runs.html").is_file()

    def test_runs_html_links_to_run_detail_pages(self, tmp_path: Path) -> None:
        """runs.html must link to per-run detail pages."""
        runs = [_make_run("run-abc")]
        render_runs(runs, tmp_path)
        html = (tmp_path / "runs.html").read_text(encoding="utf-8")
        # Should link to run-abc/index.html (run detail page)
        assert "run-abc" in html


# ---------------------------------------------------------------------------
# render_index() backward-compat — must still work
# ---------------------------------------------------------------------------


class TestRenderIndexBackwardCompat:
    """Ensure render_index() still produces index.html for existing callers."""

    def test_render_index_still_produces_index_html(self, tmp_path: Path) -> None:
        """render_index() (legacy) must still produce index.html."""
        from testgrid.render import render_index

        runs = [_make_run("run-001")]
        result = render_index(runs, tmp_path)
        assert result == tmp_path / "index.html"
        assert (tmp_path / "index.html").is_file()
