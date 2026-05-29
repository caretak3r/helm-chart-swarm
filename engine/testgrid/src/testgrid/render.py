"""Render a Run into static HTML + JSON.

The renderer is intentionally JS-free — `<details>` handles expansion.
One sibling stylesheet per output dir; no asset hashing yet.
"""

from __future__ import annotations

import dataclasses
import json
import shutil
from pathlib import Path

from jinja2 import Environment, PackageLoader, select_autoescape

from .collect import STATUS_RANK, Run, Scenario

STATUS_CSS = {
    "PASS": "status-pass",
    "FAIL": "status-fail",
    "PARTIAL": "status-partial",
    "INCONCLUSIVE": "status-inconclusive",
    "UNTESTED": "status-untested",
}

# Chart-test-swarm mechanism vocabulary. Free-form, but these are the
# categories the dashboard knows how to group.
MECHANISM_CATEGORIES = ["addon", "subchart", "mesh", "ingress", "customer", "cloud", "version"]


def status_class(status: str) -> str:
    return STATUS_CSS.get(status, "status-unknown")


def mechanism_category(m: str) -> str:
    return m.split(":", 1)[0] if ":" in m else "other"


def mechanisms_by_category(run: Run) -> dict[str, list[tuple[str, list[Scenario]]]]:
    idx = run.mechanism_index
    grouped: dict[str, list[tuple[str, list[Scenario]]]] = {}
    for cat in MECHANISM_CATEGORIES:
        items = [(m, ss) for m, ss in idx.items() if mechanism_category(m) == cat]
        if items:
            grouped[cat] = items
    # Anything else falls under "other"
    other = [(m, ss) for m, ss in idx.items() if mechanism_category(m) not in MECHANISM_CATEGORIES]
    if other:
        grouped["other"] = other
    return grouped


def rollup_status(scenarios: list[Scenario]) -> str:
    if not scenarios:
        return "UNTESTED"
    return min((s.status for s in scenarios), key=lambda st: STATUS_RANK.get(st, 99))


def _make_env() -> Environment:
    env = Environment(
        loader=PackageLoader("testgrid", "templates"),
        autoescape=select_autoescape(["html"]),
        trim_blocks=True,
        lstrip_blocks=True,
    )
    env.globals.update(
        status_class=status_class,
        rollup_status=rollup_status,
    )
    env.filters["basename"] = lambda p: Path(str(p)).name if p else ""
    return env


def _copy_assets(out_dir: Path) -> None:
    css_src = Path(__file__).parent / "templates" / "style.css"
    shutil.copy(css_src, out_dir / "style.css")


def render_run(run: Run, out_dir: Path) -> Path:
    env = _make_env()
    tpl = env.get_template("run.html.j2")
    run_dir = out_dir / run.run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    html = tpl.render(
        run=run,
        mechanisms_by_category=mechanisms_by_category(run),
    )
    (run_dir / "index.html").write_text(html, encoding="utf-8")
    (run_dir / "run.json").write_text(_run_to_json(run), encoding="utf-8")
    _copy_assets(run_dir)
    return run_dir / "index.html"


def render_index(runs: list[Run], out_dir: Path) -> Path:
    env = _make_env()
    tpl = env.get_template("index.html.j2")
    out_dir.mkdir(parents=True, exist_ok=True)
    runs_sorted = sorted(runs, key=lambda r: r.run_id, reverse=True)
    html = tpl.render(runs=runs_sorted)
    out_path = out_dir / "index.html"
    out_path.write_text(html, encoding="utf-8")
    _copy_assets(out_dir)
    return out_path


def _run_to_json(run: Run) -> str:
    return json.dumps(dataclasses.asdict(run), indent=2, default=str)
