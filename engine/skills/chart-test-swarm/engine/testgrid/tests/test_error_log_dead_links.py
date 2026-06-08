"""Tests for VAL-DASH-033 fix: error-log dead links (f-fix-error-log-dead-links).

Validates:
  - Error-log entries in failed scenario cards render as <code>, not <a href>
  - No <a> tags with href pointing to absolute filesystem paths remain in the
    rendered dashboard
  - The log_dir value is still displayed for diagnostic reference
  - All existing dashboard artifact tests still pass
"""

from __future__ import annotations

import re
from pathlib import Path

import yaml


def _write_yaml(path: Path, data: object) -> None:
    path.write_text(yaml.dump(data, default_flow_style=False), encoding="utf-8")


def _build_fail_run_with_log_dir(
    reports_dir: Path,
    run_id: str,
    *,
    log_dir: str,
    fail_msg: str | None = None,
) -> Path:
    """Create a synthetic run with a FAIL scenario that has a log_dir."""
    run_dir = reports_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    _write_yaml(
        run_dir / "run-meta.yaml",
        {
            "run_id": run_id,
            "timestamp_utc": "2026-05-20T10:15:00Z",
            "num_agents": 1,
            "suite": "test",
        },
    )

    _write_yaml(
        run_dir / "scenarios-snapshot.yaml",
        {
            "scenarios": [
                {
                    "id": "sc-fail-with-log",
                    "name": "Scenario with log dir",
                    "description": "A failing scenario with a log directory",
                    "cluster": {"provider": "kind"},
                    "mechanisms": ["certificates:cert-manager:fail"],
                    "tags": ["tls"],
                }
            ],
        },
    )

    agent_dir = run_dir / "agent-1"
    agent_dir.mkdir()
    result_entry: dict[str, object] = {
        "scenario_id": "sc-fail-with-log",
        "status": "FAIL",
        "duration_s": 42,
        "log_dir": log_dir,
        "asserts": [{"type": "pods-ready", "status": "FAIL", "notes": "pod crashloop backoff"}],
    }
    if fail_msg:
        result_entry["fail_msg"] = fail_msg
    _write_yaml(
        agent_dir / "result.yaml",
        {"agent": 1, "results": [result_entry]},
    )

    # Create a minimal artifacts bundle so the scenario is "rich"
    art = agent_dir / "artifacts"
    art.mkdir(parents=True, exist_ok=True)
    (art / "scenario.yaml").write_text("id: sc-fail-with-log\n", encoding="utf-8")
    (art / "applied-overrides.yaml").write_text("{}\n", encoding="utf-8")
    (art / "fixtures").mkdir()
    (art / "manifests").mkdir()

    return run_dir


class TestErrorLogNoDeadLinks:
    """VAL-DASH-033 fix: error-log links use <code> not <a href> for log_dir."""

    def test_error_log_renders_as_code_not_anchor(self, tmp_path: Path) -> None:
        """Error-log entries in failed scenario cards render as <code> element,
        not <a href> (f-fix-error-log-dead-links expectedBehavior #1)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_fail_run_with_log_dir(
            reports, "run-fail-code", log_dir="/tmp/chart-test-swarm/scenario-12345/"
        )

        run = collect_run(reports, "run-fail-code")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-fail-code" / "index.html").read_text(encoding="utf-8")

        # The error-log dd should contain a <code> element, not an <a href>
        # Find the error-log section
        assert "error-log" in html, "FAIL card should have error-log element"

        # The log_dir value should be inside a <code> element, not inside an <a href>
        # Check that the log directory path appears (for diagnostic reference)
        assert "scenario-12345" in html, "log_dir value should still be displayed for reference"

        # Check that there is NO <a href> with the absolute filesystem path
        # within the error-log section
        error_log_match = re.search(r'<dd class="error-log">.*?</dd>', html, re.DOTALL)
        assert error_log_match, "Should find error-log dd element"
        error_log_html = error_log_match.group(0)

        # Must NOT contain <a href= with the filesystem path
        assert '<a href="/tmp/' not in error_log_html, (
            "error-log must not render log_dir as <a href> with absolute path"
        )
        assert "<code>" in error_log_html, "error-log should render log_dir inside a <code> element"

    def test_no_absolute_filesystem_href_in_error_log(self, tmp_path: Path) -> None:
        """No <a> tags with href pointing to absolute filesystem paths remain in
        the rendered dashboard (f-fix-error-log-dead-links expectedBehavior #2)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_fail_run_with_log_dir(
            reports, "run-abs-path", log_dir="/tmp/chart-test-swarm/customer-A-istio-12348/"
        )

        run = collect_run(reports, "run-abs-path")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-abs-path" / "index.html").read_text(encoding="utf-8")

        # No <a> tag anywhere in the HTML should have an href starting with /tmp/
        # (which would be an absolute filesystem path)
        absolute_href_matches = re.findall(r'<a\s+href="(/[^"]*)"', html)
        for href in absolute_href_matches:
            assert not href.startswith("/tmp/"), (
                f"Found <a> tag with absolute filesystem path href: {href}"
            )
            assert not href.startswith("/Users/"), (
                f"Found <a> tag with absolute filesystem path href: {href}"
            )
            assert not href.startswith("/home/"), (
                f"Found <a> tag with absolute filesystem path href: {href}"
            )

    def test_log_dir_value_still_displayed(self, tmp_path: Path) -> None:
        """The log_dir value is still displayed for diagnostic reference
        (f-fix-error-log-dead-links expectedBehavior #3)."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_fail_run_with_log_dir(
            reports, "run-log-display", log_dir="/tmp/chart-test-swarm/test-scenario-logs/"
        )

        run = collect_run(reports, "run-log-display")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-log-display" / "index.html").read_text(encoding="utf-8")

        # The log_dir value should still be visible in the rendered HTML
        # (as text within <code>, not as a clickable link)
        assert "test-scenario-logs" in html, (
            "log_dir value should still be displayed for diagnostic reference"
        )

        # It should appear within a <code> element in the error-log section
        error_log_match = re.search(r'<dd class="error-log">.*?</dd>', html, re.DOTALL)
        assert error_log_match, "Should find error-log dd element"
        error_log_html = error_log_match.group(0)
        assert "<code>" in error_log_html, "log_dir should be wrapped in <code>"

    def test_log_dir_with_both_fail_msg_and_log(self, tmp_path: Path) -> None:
        """FAIL card with both fail_msg and log_dir shows both, with log_dir
        rendered as <code> not <a>."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_fail_run_with_log_dir(
            reports,
            "run-fail-both",
            log_dir="/tmp/chart-test-swarm/cluster-up-logs/",
            fail_msg="Cluster creation failed: timeout",
        )

        run = collect_run(reports, "run-fail-both")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-fail-both" / "index.html").read_text(encoding="utf-8")

        assert "error-summary" in html
        assert "Cluster creation failed" in html
        assert "error-log" in html
        assert "cluster-up-logs" in html

        # error-log should be <code>, not <a href>
        error_log_match = re.search(r'<dd class="error-log">.*?</dd>', html, re.DOTALL)
        assert error_log_match, "Should find error-log dd element"
        error_log_html = error_log_match.group(0)
        assert "<code>" in error_log_html, "log_dir should be in <code>"
        assert '<a href="/tmp/' not in error_log_html, (
            "log_dir must not be an <a href> with absolute path"
        )

    def test_no_dead_links_in_served_dashboard(self, tmp_path: Path) -> None:
        """VAL-DASH-033: No dead in-tree links anywhere on the served dashboard.
        After the fix, error-log sections do not produce <a href> links to
        absolute filesystem paths that would 404 over HTTP."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_fail_run_with_log_dir(
            reports, "run-dead-link-check", log_dir="/tmp/chart-test-swarm/istio-12348/"
        )

        run = collect_run(reports, "run-dead-link-check")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-dead-link-check" / "index.html").read_text(encoding="utf-8")

        # Find ALL <a> tags in the HTML and check none point to absolute paths
        all_anchors = re.findall(r'<a\s[^>]*href="([^"]*)"', html)
        for href in all_anchors:
            # In-tree links should be relative
            # Skip external URLs (out of scope for VAL-DASH-033)
            if href.startswith("http://") or href.startswith("https://"):
                continue
            # Must not be an absolute filesystem path
            assert not href.startswith("/tmp/"), f"Dead link: {href}"
            assert not href.startswith("/Users/"), f"Dead link: {href}"
            assert not href.startswith("/home/"), f"Dead link: {href}"
            assert not href.startswith("file:"), f"Dead link: {href}"

    def test_pass_card_no_error_log(self, tmp_path: Path) -> None:
        """PASS scenario cards do not render error-log elements."""
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()

        # Build a simple PASS run
        run_id = "run-pass-no-log"
        run_dir = reports / run_id
        run_dir.mkdir(parents=True)

        _write_yaml(run_dir / "run-meta.yaml", {"run_id": run_id})
        _write_yaml(
            run_dir / "scenarios-snapshot.yaml",
            {
                "scenarios": [
                    {
                        "id": "sc-pass",
                        "name": "Passing scenario",
                        "cluster": {"provider": "kind"},
                        "mechanisms": ["certificates:cert-manager"],
                        "tags": ["tls"],
                    }
                ],
            },
        )

        agent_dir = run_dir / "agent-1"
        agent_dir.mkdir()
        _write_yaml(
            agent_dir / "result.yaml",
            {
                "agent": 1,
                "results": [
                    {
                        "scenario_id": "sc-pass",
                        "status": "PASS",
                        "duration_s": 10,
                        "asserts": [{"type": "pods-ready", "status": "PASS", "notes": "ok"}],
                    }
                ],
            },
        )
        art = agent_dir / "artifacts"
        art.mkdir()
        (art / "scenario.yaml").write_text("id: sc-pass\n", encoding="utf-8")
        (art / "applied-overrides.yaml").write_text("{}\n", encoding="utf-8")
        (art / "fixtures").mkdir()
        (art / "manifests").mkdir()

        run = collect_run(reports, run_id)
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / run_id / "index.html").read_text(encoding="utf-8")
        # PASS cards should not have error-log section at all
        assert 'class="error-log"' not in html, "PASS card should not have error-log element"
