"""testgrid CLI — build static HTML dashboards from chart-test-swarm runs."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .collect import collect_run, list_runs
from .render import render_index, render_run

# chart-test-swarm repo root: cli.py is at engine/testgrid/src/testgrid/cli.py
DEFAULT_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_REPORTS = DEFAULT_ROOT / "reports"
DEFAULT_OUT = DEFAULT_ROOT / "engine" / "testgrid" / "dist"


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
        except FileNotFoundError as exc:
            print(f"warn: {exc}", file=sys.stderr)
            continue
        path = render_run(run, out)
        passed = sum(1 for s in run.scenarios if s.status == "PASS")
        print(f"  {rid:30s}  {passed}/{len(run.scenarios)} scenarios PASS  →  {path}")

    all_runs: list = []
    for rid in list_runs(reports):
        try:
            all_runs.append(collect_run(reports, rid))
        except FileNotFoundError:
            continue

    if not all_runs:
        return 1

    index_path = render_index(all_runs, out)
    print(f"  {'index':30s}  ({len(all_runs)} run(s))             →  {index_path}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="testgrid", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    build = sub.add_parser("build", help="render dashboards (default: all runs)")
    build.add_argument("--reports", default=str(DEFAULT_REPORTS),
                       help="reports dir containing run-<id>/ subdirs")
    build.add_argument("--out", default=str(DEFAULT_OUT),
                       help="output dir for static HTML")
    build.add_argument("--run", help="render only this run id (e.g. run-20260520-101500)")
    build.set_defaults(func=cmd_build)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
