"""Tests for the Getting Started page feature (f-gs-1-getting-started-page).

Covers:
  VAL-GS-001: Getting Started page loads successfully
  VAL-GS-002: Prerequisites section shows tool detection results
  VAL-GS-003: Step-by-step workflow displayed
  VAL-GS-004: Commands are copy-able
  VAL-GS-005: Steps link to relevant dashboard pages
  VAL-GS-006: Cluster status detected and displayed
  VAL-GS-007: Nav bar includes Getting Started link
  VAL-GS-008: Home page includes Getting Started card
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch

from testgrid.render import (
    HomeSummary,
    PrereqStatus,
    check_cluster_status,
    detect_prerequisites,
    render_getting_started,
    render_home,
)

# -----------------------------------------------------------------------------
# Prerequisites detection tests
# -----------------------------------------------------------------------------


class TestDetectPrerequisites:
    """VAL-GS-002: Prerequisites section shows tool detection results."""

    def test_detects_installed_tools(self) -> None:
        """detect_prerequisites returns True for tools that are installed."""
        prereqs = detect_prerequisites()
        # On the test system, we expect at least some tools to be installed
        # based on the earlier check
        assert isinstance(prereqs, dict)
        assert "kind" in prereqs
        assert "k3d" in prereqs
        assert "kubectl" in prereqs
        assert "helm" in prereqs
        assert "yq" in prereqs
        assert "jq" in prereqs
        assert "uv" in prereqs

    def test_returns_bool_values(self) -> None:
        """Each prerequisite value is a boolean."""
        prereqs = detect_prerequisites()
        for tool, installed in prereqs.items():
            assert isinstance(installed, bool), f"{tool} should be bool, got {type(installed)}"

    def test_shutil_which_called_for_each_tool(self) -> None:
        """detect_prerequisites uses shutil.which for each tool."""
        with patch("testgrid.render.shutil.which") as mock_which:
            mock_which.side_effect = lambda cmd: (
                f"/path/to/{cmd}" if cmd in ["kind", "kubectl"] else None
            )
            detect_prerequisites()
            assert (
                mock_which.call_count >= 7
            )  # At least 7 tools checked (kind, k3d, kubectl, helm, yq, jq, uv)
            mock_which.assert_any_call("kind")
            mock_which.assert_any_call("k3d")
            mock_which.assert_any_call("kubectl")
            mock_which.assert_any_call("helm")

    def test_install_hints_for_missing_tools(self) -> None:
        """PrereqStatus dataclass includes install hints."""
        status = PrereqStatus(
            name="kind",
            installed=False,
            install_hint="brew install kind",
        )
        assert status.name == "kind"
        assert status.installed is False
        assert "brew install" in status.install_hint


# -----------------------------------------------------------------------------
# Cluster status detection tests
# -----------------------------------------------------------------------------


class TestCheckClusterStatus:
    """VAL-GS-006: Cluster status detected and displayed."""

    def test_detects_running_cluster(self) -> None:
        """check_cluster_status returns True when kind cluster is running."""
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                stdout="chart-test-swarm-test\n",
                returncode=0,
            )
            result = check_cluster_status()
            assert result is True

    def test_detects_no_running_cluster(self) -> None:
        """check_cluster_status returns False when no kind cluster exists."""
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                stdout="\n",
                returncode=0,
            )
            result = check_cluster_status()
            assert result is False

    def test_detects_other_clusters_only(self) -> None:
        """check_cluster_status returns False when only non-CTS clusters exist."""
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                stdout="some-other-cluster\n",
                returncode=0,
            )
            result = check_cluster_status()
            assert result is False

    def test_handles_kind_not_installed(self) -> None:
        """check_cluster_status handles kind command not found gracefully."""
        with patch("subprocess.run") as mock_run:
            mock_run.side_effect = FileNotFoundError("kind not found")
            result = check_cluster_status()
            assert result is False

    def test_handles_subprocess_error(self) -> None:
        """check_cluster_status handles subprocess errors gracefully."""
        with patch("subprocess.run") as mock_run:
            mock_run.side_effect = subprocess.CalledProcessError(1, "kind")
            result = check_cluster_status()
            assert result is False


# -----------------------------------------------------------------------------
# Render Getting Started page tests
# -----------------------------------------------------------------------------


class TestRenderGettingStarted:
    """VAL-GS-001: Getting Started page renders correctly."""

    def test_produces_getting_started_html(self, tmp_path: Path) -> None:
        """render_getting_started writes getting-started.html."""
        prereqs = {"kind": True, "kubectl": True, "helm": True, "yq": True, "jq": True, "uv": True}
        result = render_getting_started(
            prereqs=prereqs,
            cluster_running=True,
            out_dir=tmp_path,
        )
        assert result == tmp_path / "getting-started.html"
        assert result.is_file()

    def test_html_contains_title(self, tmp_path: Path) -> None:
        """getting-started.html has appropriate title."""
        prereqs = {"kind": True, "kubectl": True, "helm": True, "yq": True, "jq": True, "uv": True}
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "Getting Started" in html

    def test_html_is_valid_html(self, tmp_path: Path) -> None:
        """getting-started.html is valid HTML with proper structure."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "<!DOCTYPE html>" in html
        assert "</html>" in html
        assert "<head>" in html
        assert "<body>" in html

    def test_copies_style_css(self, tmp_path: Path) -> None:
        """render_getting_started copies style.css alongside HTML."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        assert (tmp_path / "style.css").is_file()

    def test_creates_output_dir_if_missing(self, tmp_path: Path) -> None:
        """render_getting_started creates output directory if it doesn't exist."""
        out_dir = tmp_path / "new_dist"
        assert not out_dir.exists()
        prereqs = {"kind": True, "kubectl": True, "helm": True, "yq": True, "jq": True, "uv": True}
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=out_dir)
        assert out_dir.is_dir()


class TestGettingStartedPrerequisitesSection:
    """VAL-GS-002: Prerequisites section shows tool detection results."""

    def test_shows_all_required_tools(self, tmp_path: Path) -> None:
        """Page lists all required tools: kind, k3d, kubectl, helm, yq, jq, uv."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # Check for Kubernetes (kind/k3d) display label
        assert "Kubernetes (kind/k3d)" in html
        assert "kubectl" in html
        assert "helm" in html
        assert "yq" in html
        assert "jq" in html
        assert "uv" in html

    def test_shows_green_checkmark_for_installed(self, tmp_path: Path) -> None:
        """Installed tools show green checkmark."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": False,
            "helm": False,
            "yq": False,
            "jq": False,
            "uv": False,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # Check for checkmark indicators (could be check emoji, icon class, etc.)
        assert "✓" in html or "check" in html.lower() or "installed" in html.lower()

    def test_shows_red_x_for_missing(self, tmp_path: Path) -> None:
        """Missing tools show red X."""
        prereqs = {
            "kind": False,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # Check for X indicators
        assert "✗" in html or "missing" in html.lower() or "not found" in html.lower()

    def test_shows_install_hints_for_missing(self, tmp_path: Path) -> None:
        """Missing tools show install hints."""
        prereqs = {
            "kind": False,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        hints = {"kind": "brew install kind"}
        render_getting_started(prereqs=prereqs, hints=hints, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "brew install" in html or "install" in html.lower()

    def test_k3d_appears_in_prerequisites(self, tmp_path: Path) -> None:
        """k3d is detected and appears in the prerequisites section."""
        prereqs = {
            "kind": False,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # k3d should appear with the combined display name
        assert "Kubernetes (kind/k3d)" in html

    def test_kind_and_k3d_share_display_name(self, tmp_path: Path) -> None:
        """Both kind and k3d show 'Kubernetes (kind/k3d)' as the display label."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # Should have two occurrences of "Kubernetes (kind/k3d)" - one for kind, one for k3d
        display_name_count = html.count("Kubernetes (kind/k3d)")
        assert display_name_count >= 2, (
            "Expected at least 2 occurrences of 'Kubernetes (kind/k3d)', "
            f"found {display_name_count}"
        )

    def test_seven_tools_detected(self, tmp_path: Path) -> None:
        """All 7 tools (kind, k3d, kubectl, helm, yq, jq, uv) are detected."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # Count the prerequisite items
        prereq_items = html.count("prereq-item")
        # Should have 7 prerequisite items (one per tool)
        assert prereq_items >= 7, f"Expected at least 7 prereq items, found {prereq_items}"


class TestGettingStartedClusterSection:
    """VAL-GS-006: Cluster status detected and displayed."""

    def test_shows_running_status(self, tmp_path: Path) -> None:
        """When cluster is running, page shows 'running' status."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "running" in html.lower()

    def test_shows_not_running_status(self, tmp_path: Path) -> None:
        """When cluster is not running, page shows 'not running' status."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=False, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "not running" in html.lower() or "stopped" in html.lower()


class TestGettingStartedStepsSection:
    """VAL-GS-003: Step-by-step workflow displayed."""

    def test_shows_all_six_steps(self, tmp_path: Path) -> None:
        """Page shows all 6 numbered steps."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # Check for numbered steps
        for i in range(1, 7):
            assert str(i) in html, f"Step {i} not found"

    def test_step_1_is_verify(self, tmp_path: Path) -> None:
        """Step 1 is 'Verify' with make verify command."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "verify" in html.lower()
        assert "make verify" in html

    def test_step_2_is_create_cluster(self, tmp_path: Path) -> None:
        """Step 2 is 'Create cluster' with make up command."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "cluster" in html.lower()
        assert "make up" in html

    def test_step_3_is_run_scenarios(self, tmp_path: Path) -> None:
        """Step 3 is 'Run scenarios' with chart-test-swarm run command."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "run" in html.lower() or "scenario" in html.lower()
        assert "chart-test-swarm run" in html

    def test_step_4_is_view_results(self, tmp_path: Path) -> None:
        """Step 4 is 'View results' with link to runs.html."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "view" in html.lower() or "result" in html.lower()
        assert "runs.html" in html

    def test_step_5_is_fix_failures(self, tmp_path: Path) -> None:
        """Step 5 is 'Fix failures' with link to recommendations.html."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "fix" in html.lower() or "failure" in html.lower()
        assert "recommendations.html" in html

    def test_step_6_is_teardown(self, tmp_path: Path) -> None:
        """Step 6 is 'Tear down' with make down command."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "tear" in html.lower() or "down" in html.lower()
        assert "make down" in html


class TestGettingStartedCopyableCommands:
    """VAL-GS-004: Commands are copy-able."""

    def test_commands_in_code_blocks(self, tmp_path: Path) -> None:
        """Commands are wrapped in code/pre blocks."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "<code>" in html or "<pre>" in html

    def test_has_copy_buttons(self, tmp_path: Path) -> None:
        """Commands have copy buttons."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # Check for copy button indicators
        assert "copy" in html.lower() or "btn-copy" in html or "onclick" in html.lower()

    def test_copyable_commands_are_selectable(self, tmp_path: Path) -> None:
        """Command text is user-selectable."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "user-select" in html or "select-all" in html or "pre" in html


class TestGettingStartedNavBar:
    """VAL-GS-007: Nav bar includes Getting Started link."""

    def test_nav_bar_present(self, tmp_path: Path) -> None:
        """getting-started.html includes the shared nav bar."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "<nav" in html

    def test_getting_started_link_in_nav(self, tmp_path: Path) -> None:
        """Nav bar includes link to getting-started.html."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert 'href="getting-started.html"' in html or "Getting Started" in html

    def test_active_page_highlighted(self, tmp_path: Path) -> None:
        """Getting Started page has active state in nav."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert 'aria-current="page"' in html or "nav-active" in html

    def test_all_five_nav_links(self, tmp_path: Path) -> None:
        """Nav bar includes all 5 links: Home, Matrix, Runs, Recommendations, Versions."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "home.html" in html
        assert "support-matrix.html" in html
        assert "runs.html" in html
        assert "recommendations.html" in html
        assert "versions.html" in html


# -----------------------------------------------------------------------------
# Home page Getting Started card tests
# -----------------------------------------------------------------------------


class TestHomePageGettingStartedCard:
    """VAL-GS-008: Home page includes Getting Started card."""

    def test_home_has_five_cards(self, tmp_path: Path) -> None:
        """home.html has 5 navigation cards (including Getting Started)."""
        summary = HomeSummary(run_count=2, pass_rate_pct=50.0, open_rec_count=0)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        # Count home-card elements
        card_count = html.count("home-card")
        assert card_count >= 5, f"Expected at least 5 cards, found {card_count}"

    def test_getting_started_card_label(self, tmp_path: Path) -> None:
        """One card is labeled 'Getting Started'."""
        summary = HomeSummary(run_count=2, pass_rate_pct=50.0, open_rec_count=0)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert "Getting Started" in html

    def test_getting_started_card_links_to_page(self, tmp_path: Path) -> None:
        """Getting Started card links to getting-started.html."""
        summary = HomeSummary(run_count=2, pass_rate_pct=50.0, open_rec_count=0)
        render_home(summary, tmp_path)
        html = (tmp_path / "home.html").read_text(encoding="utf-8")
        assert 'href="getting-started.html"' in html


# -----------------------------------------------------------------------------
# Integration tests
# -----------------------------------------------------------------------------


class TestGettingStartedIntegration:
    """Integration tests combining render functions."""

    def test_render_with_real_prerequisites(self, tmp_path: Path) -> None:
        """render_getting_started works with actual prerequisite detection."""
        prereqs = detect_prerequisites()
        cluster_running = check_cluster_status()
        result = render_getting_started(
            prereqs=prereqs,
            cluster_running=cluster_running,
            out_dir=tmp_path,
        )
        assert result.is_file()
        html = result.read_text(encoding="utf-8")
        assert "<!DOCTYPE html>" in html

    def test_full_page_build_integration(self, tmp_path: Path) -> None:
        """All render functions work together."""

        # Build home page
        summary = HomeSummary(run_count=1, pass_rate_pct=50.0, open_rec_count=0)
        render_home(summary, tmp_path)

        # Build getting started page
        prereqs = detect_prerequisites()
        cluster_running = check_cluster_status()
        render_getting_started(
            prereqs=prereqs,
            cluster_running=cluster_running,
            out_dir=tmp_path,
        )

        # Both files exist
        assert (tmp_path / "home.html").is_file()
        assert (tmp_path / "getting-started.html").is_file()

        # Both have nav bars with Getting Started link
        home_html = (tmp_path / "home.html").read_text(encoding="utf-8")
        gs_html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "getting-started.html" in home_html
        assert "getting-started.html" in gs_html


# -----------------------------------------------------------------------------
# Step links tests (VAL-GS-005)
# -----------------------------------------------------------------------------


class TestGettingStartedStepLinks:
    """VAL-GS-005: Steps link to relevant dashboard pages."""

    def test_step_4_links_to_runs_html(self, tmp_path: Path) -> None:
        """Step 4 (View results) links to runs.html."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # Find Step 4 section and check for runs.html link
        assert "runs.html" in html

    def test_step_5_links_to_recommendations_html(self, tmp_path: Path) -> None:
        """Step 5 (Fix failures) links to recommendations.html."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "recommendations.html" in html


# -----------------------------------------------------------------------------
# Tool status indicator styling tests
# -----------------------------------------------------------------------------


class TestToolStatusStyling:
    """Tests for checkmark/X styling in prerequisites."""

    def test_installed_tool_has_green_class(self, tmp_path: Path) -> None:
        """Installed tools have CSS class for green styling."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": False,
            "helm": False,
            "yq": False,
            "jq": False,
            "uv": False,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # Look for installed/pass class
        assert "tool-installed" in html or "prereq-installed" in html or "status-pass" in html

    def test_missing_tool_has_red_class(self, tmp_path: Path) -> None:
        """Missing tools have CSS class for red styling."""
        prereqs = {
            "kind": False,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # Look for missing/fail class
        assert "tool-missing" in html or "prereq-missing" in html or "status-fail" in html


# -----------------------------------------------------------------------------
# PrereqStatus dataclass tests
# -----------------------------------------------------------------------------


def test_prereq_status_defaults() -> None:
    """PrereqStatus has sensible defaults."""
    status = PrereqStatus(name="test-tool", installed=True)
    assert status.name == "test-tool"
    assert status.installed is True
    assert status.install_hint == ""  # Default empty
    assert status.display_name == ""  # Default empty


def test_prereq_status_with_hint() -> None:
    """PrereqStatus can include install hint."""
    status = PrereqStatus(
        name="kind",
        installed=False,
        install_hint="brew install kind",
    )
    assert status.install_hint == "brew install kind"


def test_prereq_status_with_display_name() -> None:
    """PrereqStatus can include display_name for combined labels."""
    status = PrereqStatus(
        name="kind",
        installed=True,
        display_name="Kubernetes (kind/k3d)",
    )
    assert status.name == "kind"
    assert status.display_name == "Kubernetes (kind/k3d)"


# -----------------------------------------------------------------------------
# One-command fastest-path section tests (VAL-GSU-001..003)
# -----------------------------------------------------------------------------


class TestOneCommandSection:
    """VAL-GSU-001: One-command fastest-path section present."""

    def test_one_command_section_visible(self, tmp_path: Path) -> None:
        """One-command section heading is visible on the page."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "Fastest Path" in html
        assert "One Command" in html

    def test_section_describes_what_command_does(self, tmp_path: Path) -> None:
        """The one-command section describes the single command's capabilities."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "verify" in html.lower() or "verifies" in html.lower()
        assert "cluster" in html.lower()
        assert "support matrix" in html.lower() or "matrix" in html.lower()
        assert "dashboard" in html.lower()
        assert "auto-fix" in html.lower() or "auto-fixes" in html.lower()

    def test_section_surfaces_helm_swarm_test_skill(self, tmp_path: Path) -> None:
        """The section mentions /helm-swarm-test Droid skill."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "/helm-swarm-test" in html

    def test_section_surfaces_chart_test_swarm_test_cli(self, tmp_path: Path) -> None:
        """The section mentions chart-test-swarm test CLI."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "chart-test-swarm test" in html

    def test_one_command_section_appears_before_workflow(self, tmp_path: Path) -> None:
        """One-command section appears before the step-by-step workflow."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        fp_pos = html.index("Fastest Path")
        wf_pos = html.index("Workflow")
        assert fp_pos < wf_pos, "One-command section should appear before Workflow section"


class TestOneCommandCopyable:
    """VAL-GSU-002: One-command section shows copy-able command."""

    def test_command_in_code_block(self, tmp_path: Path) -> None:
        """The chart-test-swarm test command is in a code block."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # The command should appear inside a code block within the one-command section
        assert "<code>chart-test-swarm test</code>" in html

    def test_command_has_copy_button(self, tmp_path: Path) -> None:
        """The command in the one-command section has a copy button."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # The one-command card must contain a copy button
        assert 'class="btn-copy"' in html

    def test_command_uses_same_copy_pattern_as_steps(self, tmp_path: Path) -> None:
        """The one-command section uses the same copy affordance pattern as steps."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        # Both use copyToClipboard function
        assert "copyToClipboard" in html


class TestOneCommandNoRegression:
    """VAL-GSU-003: Existing Getting Started content remains intact."""

    def test_prerequisites_section_unchanged(self, tmp_path: Path) -> None:
        """Prerequisites section still renders correctly."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "Prerequisites" in html
        assert "Kubernetes (kind/k3d)" in html
        assert "kubectl" in html
        assert "helm" in html

    def test_cluster_status_unchanged(self, tmp_path: Path) -> None:
        """Cluster status section still renders correctly."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "Cluster Status" in html
        # running status should be shown
        assert "Running" in html

    def test_all_six_steps_unchanged(self, tmp_path: Path) -> None:
        """All 6 numbered steps still present."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        for i in range(1, 7):
            assert str(i) in html, f"Step {i} not found"
        assert "make verify" in html
        assert "make up" in html
        assert "chart-test-swarm run" in html
        assert "runs.html" in html
        assert "recommendations.html" in html
        assert "make down" in html

    def test_nav_bar_still_present(self, tmp_path: Path) -> None:
        """Nav bar still renders correctly."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "<nav" in html
        assert 'href="getting-started.html"' in html

    def test_copy_functionality_still_present(self, tmp_path: Path) -> None:
        """The copyToClipboard JavaScript function still exists."""
        prereqs = {
            "kind": True,
            "k3d": True,
            "kubectl": True,
            "helm": True,
            "yq": True,
            "jq": True,
            "uv": True,
        }
        render_getting_started(prereqs=prereqs, cluster_running=True, out_dir=tmp_path)
        html = (tmp_path / "getting-started.html").read_text(encoding="utf-8")
        assert "function copyToClipboard" in html
