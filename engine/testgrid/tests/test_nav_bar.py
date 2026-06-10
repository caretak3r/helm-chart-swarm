"""Tests for the shared navigation bar feature (f1-2-nav-bar-all-pages).

Covers:
  VAL-HOME-003: Support Matrix card links to support-matrix.html
  VAL-HOME-004: Run History card links to runs.html
  VAL-HOME-005: Recommendations card links to recommendations.html
  VAL-HOME-009: Nav bar appears on all dashboard pages with all five links
  VAL-HOME-010: Nav bar highlights the active page
  VAL-HOME-011: Existing run detail pages still work after rename
"""

from __future__ import annotations

from pathlib import Path

import pytest

from testgrid.collect import Run, Scenario
from testgrid.render import (
    HomeSummary,
    render_home,
    render_run,
    render_runs,
    render_support_matrix,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

NAV_LINKS = [
    "home.html",
    "support-matrix.html",
    "runs.html",
    "recommendations.html",
    "versions.html",
]

NAV_LABELS = ["Home", "Matrix", "Runs", "Recommendations", "Versions"]


def _make_run(run_id: str, scenario_count: int = 1) -> Run:
    """Create a minimal Run with *scenario_count* PASS scenarios."""
    scenarios = [
        Scenario(id=f"scn-{i}", name=f"Scenario {i}", status="PASS") for i in range(scenario_count)
    ]
    return Run(run_id=run_id, scenarios=scenarios)


def _assert_nav_links_present(html: str, base: str = "") -> None:
    """Assert all 5 nav links are present in html, with optional base prefix."""
    for link in NAV_LINKS:
        href = f'href="{base}{link}"'
        assert href in html, f"Nav link {href!r} not found in rendered HTML"


def _assert_nav_labels_present(html: str) -> None:
    """Assert all 5 nav label texts are present in html."""
    for label in NAV_LABELS:
        assert label in html, f"Nav label {label!r} not found in rendered HTML"


def _assert_nav_element_present(html: str) -> None:
    """Assert a <nav> element is present."""
    assert "<nav" in html, "No <nav> element found in rendered HTML"


# ---------------------------------------------------------------------------
# VAL-HOME-003/004/005: Home page card links
# ---------------------------------------------------------------------------


class TestHomeLinkCards:
    """The home page card links navigate to the correct pages."""

    def test_support_matrix_card_links_to_support_matrix_html(self, tmp_path: Path) -> None:
        """Home page Support Matrix card must link to support-matrix.html (VAL-HOME-003)."""
        summary = HomeSummary(run_count=2, pass_rate_pct=50.0)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert 'href="support-matrix.html"' in html

    def test_run_history_card_links_to_runs_html(self, tmp_path: Path) -> None:
        """Home page Run History card must link to runs.html (VAL-HOME-004)."""
        summary = HomeSummary(run_count=3)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert 'href="runs.html"' in html

    def test_recommendations_card_links_to_recommendations_html(self, tmp_path: Path) -> None:
        """Home page Recommendations card must link to recommendations.html (VAL-HOME-005)."""
        summary = HomeSummary(run_count=1, open_rec_count=3)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert 'href="recommendations.html"' in html


# ---------------------------------------------------------------------------
# VAL-HOME-009: Nav bar on all pages with all five links
# ---------------------------------------------------------------------------


class TestNavBarAllPages:
    """Nav bar renders on all six page types with all five links."""

    def test_nav_bar_in_home_html(self, tmp_path: Path) -> None:
        """home.html must contain a nav bar with all five links (VAL-HOME-009)."""
        summary = HomeSummary(run_count=1)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        _assert_nav_element_present(html)
        _assert_nav_links_present(html, base="")
        _assert_nav_labels_present(html)

    def test_nav_bar_in_runs_html(self, tmp_path: Path) -> None:
        """runs.html must contain a nav bar with all five links (VAL-HOME-009)."""
        render_runs([_make_run("run-001")], tmp_path)
        html = (tmp_path / "runs.html").read_text(encoding="utf-8")
        _assert_nav_element_present(html)
        _assert_nav_links_present(html, base="")
        _assert_nav_labels_present(html)

    def test_nav_bar_in_support_matrix_html(self, tmp_path: Path) -> None:
        """support-matrix.html must contain a nav bar with all five links (VAL-HOME-009)."""
        scenarios_dir = Path(__file__).parent / "stubs" / "scenarios"
        render_support_matrix(
            scenarios_dir=scenarios_dir,
            reports_dir=None,
            runs=[],
            out_dir=tmp_path,
        )
        html = (tmp_path / "support-matrix.html").read_text(encoding="utf-8")
        _assert_nav_element_present(html)
        _assert_nav_links_present(html, base="")
        _assert_nav_labels_present(html)

    def test_nav_bar_in_run_detail_html(self, tmp_path: Path) -> None:
        """run detail page must contain a nav bar with all five links (VAL-HOME-009)."""
        run = _make_run("run-test-f1-2")
        render_run(run, tmp_path)
        html = (tmp_path / "run-test-f1-2" / "index.html").read_text(encoding="utf-8")
        _assert_nav_element_present(html)
        # Run detail is one level deep → links use ../
        _assert_nav_links_present(html, base="../")
        _assert_nav_labels_present(html)

    def test_nav_bar_in_recommendations_html(self, tmp_path: Path) -> None:
        """recommendations.html must contain a nav bar with all five links (VAL-HOME-009)."""
        from testgrid.render import render_recommendations

        render_recommendations(tmp_path)
        html = (tmp_path / "recommendations.html").read_text(encoding="utf-8")
        _assert_nav_element_present(html)
        _assert_nav_links_present(html, base="")
        _assert_nav_labels_present(html)

    def test_nav_bar_in_versions_html(self, tmp_path: Path) -> None:
        """versions.html must contain a nav bar with all five links (VAL-HOME-009)."""
        from testgrid.render import render_versions

        render_versions(tmp_path)
        html = (tmp_path / "versions.html").read_text(encoding="utf-8")
        _assert_nav_element_present(html)
        _assert_nav_links_present(html, base="")
        _assert_nav_labels_present(html)


# ---------------------------------------------------------------------------
# VAL-HOME-010: Active page is highlighted
# ---------------------------------------------------------------------------


class TestNavBarActiveHighlight:
    """The nav bar highlights the active page for each page type."""

    def test_home_page_active_in_home_html(self, tmp_path: Path) -> None:
        """On home.html, the Home nav link must be highlighted (VAL-HOME-010)."""
        summary = HomeSummary(run_count=1)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        # Active page: aria-current="page" on the Home link
        assert 'aria-current="page"' in html
        # The active element must be the Home link (appears before the aria-current attr)
        home_idx = html.find('href="home.html"')
        aria_idx = html.find('aria-current="page"')
        assert home_idx >= 0 and aria_idx >= 0
        # aria-current should appear close to the home href
        assert abs(home_idx - aria_idx) < 200, "aria-current not near home.html link"

    def test_runs_page_active_in_runs_html(self, tmp_path: Path) -> None:
        """On runs.html, the Runs nav link must be highlighted (VAL-HOME-010)."""
        render_runs([_make_run("run-001")], tmp_path)
        html = (tmp_path / "runs.html").read_text(encoding="utf-8")
        assert 'aria-current="page"' in html
        runs_idx = html.find('href="runs.html"')
        aria_idx = html.find('aria-current="page"')
        assert runs_idx >= 0 and aria_idx >= 0
        assert abs(runs_idx - aria_idx) < 200

    def test_matrix_page_active_in_support_matrix_html(self, tmp_path: Path) -> None:
        """On support-matrix.html, the Matrix nav link must be highlighted (VAL-HOME-010)."""
        scenarios_dir = Path(__file__).parent / "stubs" / "scenarios"
        render_support_matrix(
            scenarios_dir=scenarios_dir,
            reports_dir=None,
            runs=[],
            out_dir=tmp_path,
        )
        html = (tmp_path / "support-matrix.html").read_text(encoding="utf-8")
        assert 'aria-current="page"' in html
        matrix_idx = html.find('href="support-matrix.html"')
        aria_idx = html.find('aria-current="page"')
        assert matrix_idx >= 0 and aria_idx >= 0
        assert abs(matrix_idx - aria_idx) < 200

    def test_runs_page_active_in_run_detail_html(self, tmp_path: Path) -> None:
        """On run detail pages, the Runs nav link must be highlighted (VAL-HOME-010)."""
        run = _make_run("run-test-nav-active")
        render_run(run, tmp_path)
        html = (tmp_path / "run-test-nav-active" / "index.html").read_text(encoding="utf-8")
        assert 'aria-current="page"' in html

    def test_recommendations_page_active_in_recommendations_html(self, tmp_path: Path) -> None:
        """On recommendations.html, the Recommendations link is highlighted (VAL-HOME-010)."""
        from testgrid.render import render_recommendations

        render_recommendations(tmp_path)
        html = (tmp_path / "recommendations.html").read_text(encoding="utf-8")
        assert 'aria-current="page"' in html
        rec_idx = html.find('href="recommendations.html"')
        aria_idx = html.find('aria-current="page"')
        assert rec_idx >= 0 and aria_idx >= 0
        assert abs(rec_idx - aria_idx) < 200

    def test_versions_page_active_in_versions_html(self, tmp_path: Path) -> None:
        """On versions.html, the Versions nav link is highlighted (VAL-HOME-010)."""
        from testgrid.render import render_versions

        render_versions(tmp_path)
        html = (tmp_path / "versions.html").read_text(encoding="utf-8")
        assert 'aria-current="page"' in html
        ver_idx = html.find('href="versions.html"')
        aria_idx = html.find('aria-current="page"')
        assert ver_idx >= 0 and aria_idx >= 0
        assert abs(ver_idx - aria_idx) < 200

    def test_only_one_active_page_in_nav(self, tmp_path: Path) -> None:
        """Exactly one nav link must be active at a time (VAL-HOME-010)."""
        summary = HomeSummary(run_count=1)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        # Count occurrences of aria-current="page"
        count = html.count('aria-current="page"')
        assert count == 1, f"Expected exactly 1 aria-current='page', got {count}"


# ---------------------------------------------------------------------------
# VAL-HOME-011: Run detail pages still work with nav bar added
# ---------------------------------------------------------------------------


class TestRunDetailWithNavBar:
    """Run detail pages must remain fully functional after nav bar is added."""

    def test_run_detail_produces_index_html(self, tmp_path: Path) -> None:
        """render_run() still produces run_id/index.html (VAL-HOME-011)."""
        run = _make_run("run-val-011")
        path = render_run(run, tmp_path)
        assert path == tmp_path / "run-val-011" / "index.html"
        assert path.is_file()

    def test_run_detail_shows_run_content(self, tmp_path: Path) -> None:
        """Run detail page must still show run-specific content (VAL-HOME-011)."""
        run = _make_run("run-content-check")
        render_run(run, tmp_path)
        html = (tmp_path / "run-content-check" / "index.html").read_text(encoding="utf-8")
        assert "run-content-check" in html

    def test_run_detail_copies_style_css(self, tmp_path: Path) -> None:
        """Run detail page must have a local style.css (VAL-HOME-011)."""
        run = _make_run("run-style-check")
        render_run(run, tmp_path)
        assert (tmp_path / "run-style-check" / "style.css").is_file()

    def test_run_detail_nav_uses_parent_relative_links(self, tmp_path: Path) -> None:
        """Run detail nav must use ../ prefix so links resolve from subdirectory (VAL-HOME-011)."""
        run = _make_run("run-rellink")
        render_run(run, tmp_path)
        html = (tmp_path / "run-rellink" / "index.html").read_text(encoding="utf-8")
        # All top-level page links must have ../ prefix in run detail pages
        assert 'href="../home.html"' in html
        assert 'href="../runs.html"' in html
        assert 'href="../support-matrix.html"' in html
        assert 'href="../recommendations.html"' in html
        assert 'href="../versions.html"' in html

    def test_run_detail_does_not_have_flat_nav_links(self, tmp_path: Path) -> None:
        """Run detail page must NOT have flat (non-relative) nav links like href='runs.html'."""
        run = _make_run("run-no-flat-links")
        render_run(run, tmp_path)
        html = (tmp_path / "run-no-flat-links" / "index.html").read_text(encoding="utf-8")
        # These flat hrefs should not appear in the nav section of run detail pages.
        # We check inside the <nav> element only.
        nav_start = html.find("<nav")
        nav_end = html.find("</nav>", nav_start)
        assert nav_start >= 0 and nav_end >= 0
        nav_section = html[nav_start:nav_end]
        # Flat links should NOT appear inside the nav
        for link in NAV_LINKS:
            assert f'href="{link}"' not in nav_section, (
                f"Flat link href={link!r} found in nav section of run detail page"
            )


# ---------------------------------------------------------------------------
# CSS: Nav bar styling
# ---------------------------------------------------------------------------


class TestNavBarCSS:
    """style.css must contain nav bar styling."""

    def _get_style_css(self) -> str:
        style_path = Path(__file__).parent.parent / "src" / "testgrid" / "templates" / "style.css"
        return style_path.read_text(encoding="utf-8")

    def test_style_css_has_top_nav_class(self) -> None:
        """style.css must define .top-nav styles."""
        css = self._get_style_css()
        assert ".top-nav" in css

    def test_style_css_has_nav_item_class(self) -> None:
        """style.css must define .nav-item styles."""
        css = self._get_style_css()
        assert ".nav-item" in css

    def test_style_css_has_nav_active_class(self) -> None:
        """style.css must define .nav-active styles for active page highlighting."""
        css = self._get_style_css()
        assert ".nav-active" in css
