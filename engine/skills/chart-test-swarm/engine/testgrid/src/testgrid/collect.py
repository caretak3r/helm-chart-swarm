"""Collect a single chart-test-swarm run into the dashboard data model.

Reads:
  <reports>/<run-id>/run-meta.yaml             (run-level metadata)
  <reports>/<run-id>/scenarios-snapshot.yaml   (which scenarios were dispatched)
  <reports>/<run-id>/agent-*/result.yaml       (per-scenario results from each agent)

OR — for single-scenario runs (run-scenario.sh output):
  <reports>/scenario-<id>-<ts>/result.yaml

Emits a Run dataclass that render.py consumes. No HTML here.
"""

from __future__ import annotations

import glob
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

STATUS_RANK = {
    "FAIL": 0,
    "PARTIAL": 1,
    "INCONCLUSIVE": 2,
    "UNTESTED": 3,
    "PASS": 4,
}


@dataclass
class Assertion:
    type: str
    status: str
    notes: str = ""


@dataclass
class Scenario:
    id: str
    name: str = ""
    description: str = ""
    cluster_provider: str = ""
    cluster_addons: list[str] = field(default_factory=list)
    mechanisms: list[str] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)
    labels: dict[str, str] = field(default_factory=dict)
    # Populated from agent results:
    status: str = "UNTESTED"
    asserts: list[Assertion] = field(default_factory=list)
    duration_s: float = 0.0
    agent: int | None = None
    log_dir: str = ""
    fail_stage: str = ""
    fail_msg: str = ""

    @property
    def rolled_status(self) -> str:
        return self.status

    @property
    def asserts_passed(self) -> int:
        return sum(1 for a in self.asserts if a.status == "PASS")

    @property
    def asserts_total(self) -> int:
        return len(self.asserts)


@dataclass
class Run:
    run_id: str
    timestamp_utc: str = ""
    num_agents: int = 0
    project_name: str = ""
    chart_name: str = ""
    chart_version: str = ""
    suite: str = ""
    cluster_provider: str = ""
    k8s_version: str = ""
    scenarios: list[Scenario] = field(default_factory=list)

    @property
    def status_counts(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for s in self.scenarios:
            counts[s.status] = counts.get(s.status, 0) + 1
        return counts

    @property
    def mechanism_index(self) -> dict[str, list[Scenario]]:
        idx: dict[str, list[Scenario]] = {}
        for s in self.scenarios:
            for m in s.mechanisms:
                idx.setdefault(m, []).append(s)
        return dict(sorted(idx.items()))

    @property
    def tag_index(self) -> dict[str, list[Scenario]]:
        idx: dict[str, list[Scenario]] = {}
        for s in self.scenarios:
            for t in s.tags:
                idx.setdefault(t, []).append(s)
        return dict(sorted(idx.items()))


def _load_yaml(path: Path) -> Any:
    with path.open() as f:
        return yaml.safe_load(f)


def load_snapshot(run_dir: Path) -> list[Scenario]:
    """The snapshot lists every scenario dispatched in this run."""
    snap_path = run_dir / "scenarios-snapshot.yaml"
    if not snap_path.exists():
        return []
    doc = _load_yaml(snap_path) or {}
    scenarios: list[Scenario] = []
    for s in doc.get("scenarios", []) or []:
        cluster = s.get("cluster", {}) or {}
        addons = [p.get("release", p.get("chart", ""))
                  for p in (cluster.get("preinstall", []) or [])]
        scenarios.append(
            Scenario(
                id=s["id"],
                name=s.get("name", ""),
                description=s.get("description", ""),
                cluster_provider=cluster.get("provider", ""),
                cluster_addons=[a for a in addons if a],
                mechanisms=list(s.get("mechanisms", []) or []),
                tags=list(s.get("tags", []) or []),
                labels=dict(s.get("labels", {}) or {}),
            )
        )
    return scenarios


def load_run_meta(run_dir: Path) -> dict[str, Any]:
    meta_path = run_dir / "run-meta.yaml"
    if not meta_path.exists():
        return {}
    return _load_yaml(meta_path) or {}


def _scenario_from_result(doc: dict[str, Any], agent: int | None) -> Scenario:
    """Build a Scenario record from a single result.yaml document."""
    asserts = [
        Assertion(
            type=a.get("type", ""),
            status=(a.get("status") or "UNKNOWN").strip(),
            notes=(a.get("notes") or "").strip(),
        )
        for a in (doc.get("asserts") or [])
    ]
    return Scenario(
        id=doc.get("scenario_id", ""),
        status=(doc.get("status") or "UNTESTED").strip(),
        asserts=asserts,
        duration_s=float(doc.get("duration_s", 0) or 0),
        agent=agent,
        log_dir=str(doc.get("log_dir", "") or ""),
        fail_stage=str(doc.get("fail_stage", "") or ""),
        fail_msg=str(doc.get("fail_msg", "") or "").strip(),
    )


def load_agent_results(run_dir: Path) -> list[Scenario]:
    """Flatten agent-*/result.yaml docs into Scenario records (results only,
    no scenario metadata — that comes from the snapshot)."""
    out: list[Scenario] = []
    for path in sorted(glob.glob(str(run_dir / "agent-*/result.yaml"))):
        agent_dir = os.path.basename(os.path.dirname(path))
        agent_suffix = agent_dir.replace("agent-", "")
        agent_n = int(agent_suffix) if agent_suffix.isdigit() else None
        try:
            doc = _load_yaml(Path(path)) or {}
        except yaml.YAMLError as exc:
            print(f"warn: skipping malformed {path}: {exc}")
            continue
        # Two formats supported:
        #  A) single scenario doc (from run-scenario.sh)
        #  B) {agent: N, results: [docs...]} (from dispatched swarm)
        if "results" in doc:
            for r in doc["results"]:
                out.append(_scenario_from_result(r, doc.get("agent", agent_n)))
        elif "scenario_id" in doc:
            out.append(_scenario_from_result(doc, agent_n))
    return out


def collect_run(reports_dir: Path, run_id: str) -> Run:
    run_dir = reports_dir / run_id
    if not run_dir.is_dir():
        raise FileNotFoundError(f"run dir not found: {run_dir}")

    scenarios = load_snapshot(run_dir)
    by_id = {s.id: s for s in scenarios}

    for res in load_agent_results(run_dir):
        if res.id in by_id:
            s = by_id[res.id]
            s.status = res.status
            s.asserts = res.asserts
            s.duration_s = res.duration_s
            s.agent = res.agent
            s.log_dir = res.log_dir
            s.fail_stage = res.fail_stage
            s.fail_msg = res.fail_msg
        else:
            # Result without a snapshot entry — keep it; surfaces as orphan.
            scenarios.append(res)

    meta = load_run_meta(run_dir)
    project = meta.get("project", {}) or {}
    chart = meta.get("chart", {}) or {}
    return Run(
        run_id=str(meta.get("run_id", run_id)),
        timestamp_utc=str(meta.get("timestamp_utc", "") or ""),
        num_agents=int(meta.get("num_agents", 0) or 0),
        project_name=str(project.get("name", "") or ""),
        chart_name=str(chart.get("name", "") or ""),
        chart_version=str(chart.get("version", "") or ""),
        suite=str(meta.get("suite", "") or ""),
        cluster_provider=str(meta.get("cluster_provider", "") or ""),
        k8s_version=str(meta.get("k8s_version", "") or ""),
        scenarios=scenarios,
    )


def list_runs(reports_dir: Path) -> list[str]:
    if not reports_dir.is_dir():
        return []
    return sorted(
        p.name for p in reports_dir.iterdir()
        if p.is_dir() and p.name.startswith("run-")
    )
