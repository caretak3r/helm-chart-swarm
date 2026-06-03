"""testgrid CLI — build static HTML dashboards from chart-test-swarm runs."""

from __future__ import annotations

import argparse
import json as _json
import sys
from pathlib import Path
from typing import Any

from .catalog import catalog_to_yaml, generate_catalog
from .collect import OrphanRunError, Run, collect_run, list_runs
from .render import (
    HomeSummary,
    build_support_matrix,
    render_home,
    render_index,
    render_recommendations,
    render_run,
    render_runs,
    render_support_matrix,
    render_versions,
    support_matrix_run_counts,
)
from .versions import get_resolved_config, load_project_overrides

# chart-test-swarm repo root: cli.py is at engine/testgrid/src/testgrid/cli.py
DEFAULT_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_REPORTS = DEFAULT_ROOT / "reports"
DEFAULT_OUT = DEFAULT_ROOT / "engine" / "testgrid" / "dist"
DEFAULT_SCENARIOS = DEFAULT_ROOT / "examples" / "sample-product-chart" / "chart-test" / "scenarios"


def cmd_build(args: argparse.Namespace) -> int:
    reports = Path(args.reports).resolve()
    out = Path(args.out).resolve()
    scenarios_dir = Path(args.scenarios).resolve() if args.scenarios else None

    run_ids = [args.run] if args.run else list_runs(reports)

    for rid in run_ids:
        try:
            run = collect_run(reports, rid)
        except (FileNotFoundError, OrphanRunError):
            continue
        path = render_run(run, out)
        passed = sum(1 for s in run.scenarios if s.status == "PASS")
        print(f"  {rid:30s}  {passed}/{len(run.scenarios)} scenarios PASS  →  {path}")

    all_runs: list[Run] = []
    for rid in list_runs(reports):
        try:
            all_runs.append(collect_run(reports, rid))
        except (FileNotFoundError, OrphanRunError):
            continue

    if all_runs:
        index_path = render_index(all_runs, out)
        print(f"  {'index':30s}  ({len(all_runs)} run(s))             →  {index_path}")
        runs_path = render_runs(all_runs, out)
        print(f"  {'runs':30s}  ({len(all_runs)} run(s))             →  {runs_path}")
    else:
        print(f"no runs under {reports}/", file=sys.stderr)

    # f12-5: render support matrix if scenarios_dir is provided.
    # This is rendered even when there are no runs — the matrix shows
    # all catalog scenarios with UNTESTED/AUTHORED status.
    coverage_pct = 0.0
    if scenarios_dir and scenarios_dir.is_dir():
        sm_path = render_support_matrix(
            scenarios_dir=scenarios_dir,
            reports_dir=reports if reports.is_dir() else None,
            runs=all_runs,
            out_dir=out,
        )
        print(f"  {'support-matrix':30s}  →  {sm_path}")
        # Compute coverage % for the home page from the support-matrix output.
        coverage_pct = _compute_coverage_pct(
            scenarios_dir, reports if reports.is_dir() else None, all_runs
        )

    # Compute open recommendation count from reports/recommendations.json (if present).
    open_rec_count = _load_open_rec_count(reports)

    # Determine version config status (project versions.yaml presence).
    # The project dir is one level up from scenarios (chart-test/scenarios → chart-test).
    version_status = "default"
    if scenarios_dir is not None:
        project_chart_test = scenarios_dir.parent
        project_versions_yaml = project_chart_test / "versions.yaml"
        if project_versions_yaml.is_file():
            version_status = "configured"

    # f1-1: render home page as the new landing page.
    summary = HomeSummary(
        run_count=len(all_runs),
        coverage_pct=coverage_pct,
        open_rec_count=open_rec_count,
        version_status=version_status,
    )
    home_path = render_home(summary, out)
    print(f"  {'home':30s}  →  {home_path}")

    # Stub pages for navigation end-to-end
    recs_path = render_recommendations(out)
    print(f"  {'recommendations':30s}  →  {recs_path}")

    # Versions dashboard — pass merged config + project overrides for full display.
    versions_project_dir: Path | None = None
    versions_merged: dict[str, Any] | None = None
    versions_overrides: dict[str, Any] | None = None
    if scenarios_dir is not None:
        # project_dir is two levels up from scenarios (scenarios → chart-test → project)
        versions_project_dir = scenarios_dir.parent.parent
        try:
            versions_merged = get_resolved_config(project_dir=versions_project_dir)
            versions_overrides = load_project_overrides(versions_project_dir)
        except Exception:
            versions_merged = None
            versions_overrides = None
    vers_path = render_versions(
        out,
        merged_config=versions_merged,
        project_overrides=versions_overrides,
        project_dir=versions_project_dir,
    )
    print(f"  {'versions':30s}  →  {vers_path}")

    # Return 0 if we produced at least a support-matrix, runs.html, home.html, or index.html.
    has_output = (
        (out / "support-matrix.html").is_file()
        or (out / "index.html").is_file()
        or (out / "runs.html").is_file()
        or (out / "home.html").is_file()
    )
    return 0 if has_output else 1


def _compute_coverage_pct(
    scenarios_dir: Path,
    reports_dir: Path | None,
    runs: list[Run],
) -> float:
    """Compute what fraction of runnable catalog scenarios have been run.

    Authored-only (cloud) scenarios are excluded from both the numerator
    and the denominator.  Returns 0.0 when there are no runnable scenarios.
    """
    import tempfile

    # Build matrix in a temporary catalog dir so we don't clobber the real one.
    with tempfile.TemporaryDirectory() as tmp:
        catalog_dist = Path(tmp) / "catalog"
        matrix = build_support_matrix(scenarios_dir, reports_dir, runs, catalog_dist)

    all_entries = [e for entries in matrix.values() for e in entries]
    counts = support_matrix_run_counts(all_entries)
    total_runnable = sum(1 for e in all_entries if not e.is_authored_only)
    if total_runnable == 0:
        return 0.0
    return round(counts.get("run", 0) / total_runnable * 100, 1)


def _load_open_rec_count(reports_dir: Path) -> int:
    """Read the open recommendation count from ``reports/recommendations.json``.

    Returns 0 when the file does not exist or cannot be parsed.
    """
    rec_json = reports_dir / "recommendations.json"
    if not rec_json.is_file():
        return 0
    try:
        data = _json.loads(rec_json.read_text(encoding="utf-8"))
        return sum(1 for r in data.get("recommendations", []) if r.get("status") == "open")
    except Exception:
        return 0


def cmd_catalog(args: argparse.Namespace) -> int:
    """Generate a deterministic catalog.yaml from the scenarios tree."""
    scenarios_dir = Path(args.scenarios).resolve()
    reports_dir = Path(args.reports).resolve() if args.reports else None
    out_path = Path(args.out).resolve() if args.out else None

    if not scenarios_dir.is_dir():
        print(f"scenarios dir not found: {scenarios_dir}", file=sys.stderr)
        return 1

    catalog = generate_catalog(scenarios_dir, reports_dir=reports_dir)
    yaml_text = catalog_to_yaml(catalog)

    if out_path:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(yaml_text, encoding="utf-8")
        # Count scenarios for summary
        total = sum(
            len(entries) for integrations in catalog.values() for entries in integrations.values()
        )
        print(f"  catalog: {total} scenarios across {len(catalog)} categories  →  {out_path}")
    else:
        sys.stdout.write(yaml_text)

    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="testgrid", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    build = sub.add_parser("build", help="render dashboards (default: all runs)")
    build.add_argument(
        "--reports", default=str(DEFAULT_REPORTS), help="reports dir containing run-<id>/ subdirs"
    )
    build.add_argument("--out", default=str(DEFAULT_OUT), help="output dir for static HTML")
    build.add_argument("--run", help="render only this run id (e.g. run-20260520-101500)")
    build.add_argument(
        "--scenarios",
        default=str(DEFAULT_SCENARIOS),
        help="scenarios dir for support matrix generation",
    )
    build.set_defaults(func=cmd_build)

    catalog = sub.add_parser("catalog", help="generate catalog.yaml from the scenarios tree")
    catalog.add_argument(
        "--scenarios",
        default=str(DEFAULT_SCENARIOS),
        help="scenarios dir containing category/<scenario>.yaml files",
    )
    catalog.add_argument(
        "--reports",
        default=str(DEFAULT_REPORTS),
        help="reports dir for resolving overrides references (optional)",
    )
    catalog.add_argument("--out", help="output path for catalog.yaml (default: stdout)")
    catalog.set_defaults(func=cmd_catalog)

    args = p.parse_args(argv)
    func = args.func
    return int(func(args))


if __name__ == "__main__":
    sys.exit(main())
