"""Tests for inline artifact/error codeblocks on the run page.

Validates:
  - ``_read_capped_text``: line cap, byte cap, missing file
  - error-snippet extraction: marker-anchored window + tail fallback
  - relevant-log resolution: assert log vs stage log vs last-modified fallback
  - ``render_run`` embeds artifact content inline, copies the relevant log into
    the dist tree, and renders truncation notices + "view full file" links.
"""

from __future__ import annotations

import re
from pathlib import Path

import yaml


def _write_yaml(path: Path, data: object) -> None:
    path.write_text(yaml.dump(data, default_flow_style=False), encoding="utf-8")


# ---------------------------------------------------------------------------
# Unit tests — _read_capped_text / _cap_text
# ---------------------------------------------------------------------------


class TestReadCappedText:
    def test_caps_by_lines(self, tmp_path: Path) -> None:
        from testgrid.render import _read_capped_text

        p = tmp_path / "big.log"
        p.write_text("\n".join(f"line {i}" for i in range(500)), encoding="utf-8")

        text, truncated, total_lines = _read_capped_text(p, max_lines=200, max_bytes=10_000_000)
        assert truncated is True
        assert total_lines == 500
        assert len(text.splitlines()) == 200

    def test_caps_by_bytes(self, tmp_path: Path) -> None:
        from testgrid.render import _read_capped_text

        p = tmp_path / "wide.log"
        # Few lines but very large total byte size -> byte cap hits first.
        p.write_text("x" * 200_000 + "\n" + "y" * 10, encoding="utf-8")

        text, truncated, _total = _read_capped_text(p, max_lines=10_000, max_bytes=65536)
        assert truncated is True
        assert len(text.encode("utf-8")) <= 65536

    def test_missing_file_returns_empty(self, tmp_path: Path) -> None:
        from testgrid.render import _read_capped_text

        text, truncated, total_lines = _read_capped_text(tmp_path / "nope.log")
        assert text == ""
        assert truncated is False
        assert total_lines == 0

    def test_small_file_not_truncated(self, tmp_path: Path) -> None:
        from testgrid.render import _read_capped_text

        p = tmp_path / "small.yaml"
        p.write_text("id: thing\nname: x\n", encoding="utf-8")
        text, truncated, total_lines = _read_capped_text(p)
        assert truncated is False
        assert total_lines == 2
        assert "id: thing" in text


# ---------------------------------------------------------------------------
# Unit tests — error snippet extraction
# ---------------------------------------------------------------------------


class TestExtractLogSnippet:
    def test_marker_anchored_window(self, tmp_path: Path) -> None:
        from testgrid.render import _extract_log_snippet

        lines = [f"step {i}" for i in range(100)]
        lines[80] = "ERROR: something blew up"
        p = tmp_path / "run.log"
        p.write_text("\n".join(lines), encoding="utf-8")

        window, total = _extract_log_snippet(p, before=20, tail=40)
        assert total == 100
        # Window starts ~20 lines before the last marker (line 80 -> 60).
        assert "step 60" in window
        assert "ERROR: something blew up" in window
        assert "step 59" not in window

    def test_tail_fallback_without_marker(self, tmp_path: Path) -> None:
        from testgrid.render import _extract_log_snippet

        lines = [f"line {i}" for i in range(100)]
        p = tmp_path / "clean.log"
        p.write_text("\n".join(lines), encoding="utf-8")

        window, total = _extract_log_snippet(p, before=20, tail=40)
        assert total == 100
        assert "line 99" in window
        assert "line 60" in window
        assert "line 59" not in window

    def test_empty_file(self, tmp_path: Path) -> None:
        from testgrid.render import _extract_log_snippet

        p = tmp_path / "empty.log"
        p.write_text("", encoding="utf-8")
        window, total = _extract_log_snippet(p)
        assert window == ""
        assert total == 0


# ---------------------------------------------------------------------------
# Unit tests — relevant-log resolution
# ---------------------------------------------------------------------------


class TestResolveRelevantLog:
    def _logs_dir(self, tmp_path: Path) -> Path:
        d = tmp_path / "logs"
        d.mkdir()
        return d

    def test_prefers_assert_log_by_index_and_type(self, tmp_path: Path) -> None:
        from testgrid.collect import Assertion
        from testgrid.render import _resolve_relevant_log

        logs = self._logs_dir(tmp_path)
        (logs / "assert-0-annotations-present.log").write_text("a", encoding="utf-8")
        (logs / "cluster-up.log").write_text("b", encoding="utf-8")

        asserts = [Assertion(type="annotations-present", status="FAIL", notes="x")]
        resolved = _resolve_relevant_log(logs, "", asserts)
        assert resolved is not None
        assert resolved.name == "assert-0-annotations-present.log"

    def test_assert_log_glob_fallback(self, tmp_path: Path) -> None:
        from testgrid.collect import Assertion
        from testgrid.render import _resolve_relevant_log

        logs = self._logs_dir(tmp_path)
        # Index doesn't match (3), but type-globbed file exists.
        (logs / "assert-2-pods-ready.log").write_text("a", encoding="utf-8")

        asserts = [
            Assertion(type="other", status="PASS", notes=""),
            Assertion(type="other2", status="PASS", notes=""),
            Assertion(type="other3", status="PASS", notes=""),
            Assertion(type="pods-ready", status="FAIL", notes="x"),
        ]
        resolved = _resolve_relevant_log(logs, "", asserts)
        assert resolved is not None
        assert resolved.name == "assert-2-pods-ready.log"

    def test_stage_log_when_no_assert_match(self, tmp_path: Path) -> None:
        from testgrid.render import _resolve_relevant_log

        logs = self._logs_dir(tmp_path)
        (logs / "cluster-up.log").write_text("boom", encoding="utf-8")

        resolved = _resolve_relevant_log(logs, "cluster-up", asserts=[])
        assert resolved is not None
        assert resolved.name == "cluster-up.log"

    def test_last_modified_fallback(self, tmp_path: Path) -> None:
        import os
        import time

        from testgrid.render import _resolve_relevant_log

        logs = self._logs_dir(tmp_path)
        old = logs / "preinstall.log"
        new = logs / "product-install.log"
        old.write_text("old", encoding="utf-8")
        new.write_text("new", encoding="utf-8")
        # Make `new` clearly the most recent.
        past = time.time() - 1000
        os.utime(old, (past, past))

        resolved = _resolve_relevant_log(logs, "", asserts=[])
        assert resolved is not None
        assert resolved.name == "product-install.log"

    def test_no_logs_dir_returns_none(self, tmp_path: Path) -> None:
        from testgrid.render import _resolve_relevant_log

        resolved = _resolve_relevant_log(tmp_path / "missing", "stage", asserts=[])
        assert resolved is None


# ---------------------------------------------------------------------------
# Integration — render_run embeds content / copies logs / truncation notices
# ---------------------------------------------------------------------------


def _build_fail_run_with_logs(
    reports_dir: Path,
    run_id: str,
    *,
    scenario_yaml_lines: int = 5,
) -> None:
    """Build a FAIL scenario run with a full artifacts bundle including logs."""
    run_dir = reports_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    _write_yaml(run_dir / "run-meta.yaml", {"run_id": run_id, "num_agents": 1})
    _write_yaml(
        run_dir / "scenarios-snapshot.yaml",
        {
            "scenarios": [
                {
                    "id": "annotations-on",
                    "name": "Annotations on",
                    "cluster": {"provider": "kind"},
                    "mechanisms": ["capability:annotations"],
                    "tags": ["annotations"],
                }
            ]
        },
    )

    sc_dir = run_dir / "scenario-annotations-on-20260609-085542"
    sc_dir.mkdir()
    _write_yaml(
        sc_dir / "result.yaml",
        {
            "scenario_id": "annotations-on",
            "status": "FAIL",
            "log_dir": str(sc_dir / "artifacts" / "logs"),
            "asserts": [
                {
                    "type": "annotations-present",
                    "status": "FAIL",
                    "notes": "missing annotation 'example.com/owner=team-x' on Service/sample",
                }
            ],
        },
    )

    art = sc_dir / "artifacts"
    art.mkdir()
    sc_yaml = "\n".join(f"key{i}: value{i}" for i in range(scenario_yaml_lines))
    (art / "scenario.yaml").write_text(sc_yaml + "\n", encoding="utf-8")
    (art / "applied-overrides.yaml").write_text("{}\n", encoding="utf-8")
    (art / "fixtures").mkdir()
    mf = art / "manifests"
    mf.mkdir()
    (mf / "services.yaml").write_text(
        "kind: Service\nmetadata:\n  name: sample\n", encoding="utf-8"
    )
    logs = art / "logs"
    logs.mkdir()
    (logs / "assert-0-annotations-present.log").write_text(
        "checking annotations\n"
        "  missing annotation 'example.com/owner=team-x' on Service/sample\n"
        "FAIL: 1 annotation check(s) failed\n",
        encoding="utf-8",
    )
    (logs / "cluster-up.log").write_text("cluster created ok\n", encoding="utf-8")


class TestRenderInlineContent:
    def test_scenario_yaml_content_embedded(self, tmp_path: Path) -> None:
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_fail_run_with_logs(reports, "run-inline-1")

        run = collect_run(reports, "run-inline-1")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-inline-1" / "index.html").read_text(encoding="utf-8")
        # Inline scenario YAML content is embedded inside a codeblock.
        assert "key0: value0" in html
        assert "codeblock-pre" in html
        # The full-file link is still present and relative.
        assert 'data-artifact="scenario"' in html
        assert "annotations-on/artifacts/scenario.yaml" in html

    def test_error_content_codeblock_from_assert_notes(self, tmp_path: Path) -> None:
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_fail_run_with_logs(reports, "run-inline-2")

        run = collect_run(reports, "run-inline-2")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-inline-2" / "index.html").read_text(encoding="utf-8")
        # Error content codeblock built from FAIL assert notes (no fail_msg).
        assert "error-summary" in html
        assert "missing annotation" in html
        # The assert type heads the error text.
        assert "annotations-present:" in html

    def test_focused_log_snippet_embedded_and_log_copied(self, tmp_path: Path) -> None:
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_fail_run_with_logs(reports, "run-inline-3")

        run = collect_run(reports, "run-inline-3")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        run_dist = out / "run-inline-3"
        html = (run_dist / "index.html").read_text(encoding="utf-8")

        # Focused log snippet from the resolved assert log is embedded.
        assert "error-snippet" in html
        assert "FAIL: 1 annotation check(s) failed" in html
        assert "assert-0-annotations-present.log" in html

        # The relevant log file is copied into the dist tree and is servable.
        copied = (
            run_dist / "annotations-on" / "artifacts" / "logs" / "assert-0-annotations-present.log"
        )
        assert copied.is_file()
        assert "FAIL" in copied.read_text(encoding="utf-8")

        # "View full log" relative link present (no absolute filesystem href).
        assert 'data-log="full"' in html
        for href in re.findall(r'<a\s[^>]*href="([^"]*)"', html):
            if href.startswith("http://") or href.startswith("https://"):
                continue
            assert not href.startswith("/"), f"absolute href: {href}"
            assert not href.startswith("file:"), f"file href: {href}"

    def test_log_dir_path_still_shown_as_code(self, tmp_path: Path) -> None:
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_fail_run_with_logs(reports, "run-inline-4")

        run = collect_run(reports, "run-inline-4")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-inline-4" / "index.html").read_text(encoding="utf-8")
        m = re.search(r'<dd class="error-log">.*?</dd>', html, re.DOTALL)
        assert m, "error-log dd should be present"
        assert "<code>" in m.group(0)
        assert "/artifacts/logs" in m.group(0)

    def test_truncation_notice_and_view_full_file(self, tmp_path: Path) -> None:
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        # 400-line scenario.yaml triggers the 200-line cap.
        _build_fail_run_with_logs(reports, "run-inline-5", scenario_yaml_lines=400)

        run = collect_run(reports, "run-inline-5")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-inline-5" / "index.html").read_text(encoding="utf-8")
        assert "codeblock-trunc" in html
        assert re.search(r"Truncated — \d+ of \d+ lines\.", html), "expected truncation notice"
        # Full file still copied + linked.
        assert (out / "run-inline-5" / "annotations-on" / "artifacts" / "scenario.yaml").is_file()

    def test_copy_button_and_script_present(self, tmp_path: Path) -> None:
        from testgrid.collect import collect_run
        from testgrid.render import render_run

        reports = tmp_path / "reports"
        reports.mkdir()
        _build_fail_run_with_logs(reports, "run-inline-6")

        run = collect_run(reports, "run-inline-6")
        out = tmp_path / "dist"
        out.mkdir()
        render_run(run, out)

        html = (out / "run-inline-6" / "index.html").read_text(encoding="utf-8")
        assert 'class="copy-btn"' in html
        assert "navigator.clipboard" in html
