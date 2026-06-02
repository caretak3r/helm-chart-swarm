"""testgrid CLI — build static HTML dashboards from chart-test-swarm runs."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .catalog import catalog_to_yaml, generate_catalog
from .collect import OrphanRunError, Run, collect_run, list_runs
from .render import render_index, render_run

# chart-test-swarm repo root: cli.py is at engine/testgrid/src/testgrid/cli.py
DEFAULT_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_REPORTS = DEFAULT_ROOT / "reports"
DEFAULT_OUT = DEFAULT_ROOT / "engine" / "testgrid" / "dist"
DEFAULT_SCENARIOS = DEFAULT_ROOT / "examples" / "sample-product-chart" / "chart-test" / "scenarios"


def cmd_build(args: argparse.Namespace) -> int:
    reports = Path(args.reports).resolve()
    out = Path(args.out).resolve()

    run_ids = [args.run] if args.run else list_runs(reports)
    if not run_ids:
        print(f"no runs under {reports}/", file=sys.stderr)
        return 1

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

    if not all_runs:
        return 1

    index_path = render_index(all_runs, out)
    print(f"  {'index':30s}  ({len(all_runs)} run(s))             →  {index_path}")
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
