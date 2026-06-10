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
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

# Cloud-platform scenarios that were authored but never run locally.
CLOUD_PROVIDERS = frozenset({"gke", "eks", "aks"})

STATUS_RANK = {
    "FAIL": 0,
    "PARTIAL": 1,
    "UNTESTED": 2,
    "INCONCLUSIVE": 3,
    "INTERRUPTED": 4,
    "SKIP": 5,
    "AUTHORED": 6,
    "PASS": 7,
}

KNOWN_STATUSES = frozenset(STATUS_RANK.keys()) | {"UNKNOWN"}
"""The set of status strings the collector recognizes.

Any ``result.yaml`` whose ``status`` is not in this set is normalized to
``"UNKNOWN"`` and surfaced visibly in the dashboard rather than being
silently CSS-coerced to ``status-unknown``.
"""


@dataclass
class Assertion:
    type: str
    status: str
    notes: str = ""
    depth_level: str = ""


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
    # F2.1 / M11: artifact links for the dashboard scenario card.
    # Keys: "scenario" (str), "overrides" (str), "fixtures" (list[str]),
    #       "manifests" (list[str]).
    # Values are RELATIVE paths within the artifact bundle (relative to
    # artifact_dir), e.g. "scenario.yaml", "fixtures/tls.crt".
    # Empty dict means no artifacts/ bundle exists.
    # After render.py processes these, they become relative hrefs for HTML.
    artifact_links: dict[str, Any] = field(default_factory=dict)
    # M11: absolute source path of the artifacts/ directory, set by collect_run().
    # Used by render.py to copy artifact files into the dist tree.
    # None when no artifacts/ bundle exists for this scenario.
    artifact_dir: Path | None = None

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


class OrphanRunError(Exception):
    """Raised when a run directory has no valid metadata (no snapshot, no agent results)."""

    def __init__(self, run_dir: Path) -> None:
        super().__init__(f"orphan run dir: {run_dir}")
        self.run_dir = run_dir


def _load_yaml(path: Path) -> Any:
    with path.open() as f:
        return yaml.safe_load(f)


def load_snapshot(run_dir: Path) -> list[Scenario]:
    """The snapshot lists every scenario dispatched in this run."""
    snap_path = run_dir / "scenarios-snapshot.yaml"
    if not snap_path.exists():
        return []
    try:
        doc = _load_yaml(snap_path) or {}
    except yaml.YAMLError as exc:
        print(f"warn: corrupt {snap_path} — {exc}", file=sys.stderr)
        return []
    scenarios: list[Scenario] = []
    for s in doc.get("scenarios", []) or []:
        cluster = s.get("cluster", {}) or {}
        addons = [
            p.get("release", p.get("chart", "")) for p in (cluster.get("preinstall", []) or [])
        ]
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
    try:
        return _load_yaml(meta_path) or {}
    except yaml.YAMLError as exc:
        print(f"warn: corrupt {meta_path} — {exc}", file=sys.stderr)
        return {}


def _scenario_from_result(doc: dict[str, Any], agent: int | None) -> Scenario:
    """Build a Scenario record from a single result.yaml document."""
    raw_status = (doc.get("status") or "UNTESTED").strip()
    if raw_status not in KNOWN_STATUSES:
        print(
            f"warn: unknown status '{raw_status}' in result.yaml"
            f" (scenario_id={doc.get('scenario_id', '?')}) — normalizing to UNKNOWN",
            file=sys.stderr,
        )
        raw_status = "UNKNOWN"
    asserts = [
        Assertion(
            type=a.get("type", ""),
            status=(a.get("status") or "UNKNOWN").strip(),
            notes=(a.get("notes") or "").strip(),
            depth_level=str(a.get("depth_level", "") or "").strip(),
        )
        for a in (doc.get("asserts") or [])
    ]
    return Scenario(
        id=doc.get("scenario_id", ""),
        status=raw_status,
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
            print(f"warn: skipping malformed {path}: {exc}", file=sys.stderr)
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


def load_scenario_results(run_dir: Path) -> list[tuple[Scenario, Path]]:
    """Discover scenario-*/result.yaml docs under *run_dir*.

    The curated-live dispatch writes per-scenario results as
    ``scenario-<id>-<ts>/result.yaml`` (run-scenario.sh output format).
    This function discovers those files and returns
    ``(Scenario, artifact_dir_path)`` tuples so the caller can also
    locate the per-scenario ``artifacts/`` bundle.

    When a per-scenario result.yaml fails to parse (e.g. inconsistent
    indentation in multi-line notes), a minimal Scenario record is
    created with the status from the aggregate result.yaml fallback.

    Returns a list of ``(scenario, artifact_dir)`` tuples.  The
    ``artifact_dir`` may point to a non-existent path if the scenario
    had no artifacts/ bundle.
    """
    # Load top-level result.yaml as fallback for malformed per-scenario files.
    fallback: dict[str, str] = {}
    top_result_path = run_dir / "result.yaml"
    if top_result_path.is_file():
        try:
            top_doc = _load_yaml(top_result_path) or {}
            for entry in top_doc.get("scenarios", []) or []:
                sid = entry.get("id", "")
                sst = entry.get("status", "")
                if sid and sst:
                    fallback[sid] = sst
        except yaml.YAMLError:
            pass

    out: list[tuple[Scenario, Path]] = []
    # Track which scenario ids we successfully parsed from per-scenario files.
    parsed_ids: set[str] = set()
    for path in sorted(glob.glob(str(run_dir / "scenario-*/result.yaml"))):
        scenario_dir = Path(path).parent
        artifact_dir = scenario_dir / "artifacts"
        try:
            doc = _load_yaml(Path(path)) or {}
        except yaml.YAMLError as exc:
            # Try to extract the scenario_id from the directory name.
            # Format: scenario-<id>-<timestamp>
            scenario_id = _extract_scenario_id_from_dir(scenario_dir.name)
            if scenario_id and scenario_id in fallback:
                out.append(
                    (
                        Scenario(
                            id=scenario_id,
                            status=fallback[scenario_id],
                            agent=None,
                            log_dir="",
                            fail_msg="result.yaml had parse errors; status from aggregate",
                        ),
                        artifact_dir,
                    )
                )
                parsed_ids.add(scenario_id)
            else:
                print(
                    f"warn: skipping malformed {path}: {exc}",
                    file=sys.stderr,
                )
            continue
        if "scenario_id" not in doc:
            continue
        scenario = _scenario_from_result(doc, agent=None)
        out.append((scenario, artifact_dir))
        parsed_ids.add(scenario.id)

    # Fill in any scenarios from the top-level fallback that weren't
    # found in per-scenario dirs (e.g. cloud-authored scenarios that
    # were never dispatched but still appear in the aggregate).
    for sid, sst in fallback.items():
        if sid not in parsed_ids:
            out.append(
                (
                    Scenario(id=sid, status=sst, agent=None),
                    run_dir / "artifacts",  # fallback, may not exist
                )
            )

    return out


def _extract_scenario_id_from_dir(dir_name: str) -> str:
    """Extract the scenario id from a ``scenario-<id>-<ts>`` directory name.

    The timestamp suffix is the last two hyphen-separated parts
    (date + time, e.g. ``20260602-234626``). Everything between
    ``scenario-`` and the timestamp is the scenario id with hyphens
    restored.

    Example: ``scenario-ingress-controllers-contour-basic-httpproxy-20260602-235135``
    → ``ingress-controllers-contour-basic-httpproxy``
    """
    if not dir_name.startswith("scenario-"):
        return ""
    body = dir_name[len("scenario-") :]
    # The timestamp suffix is <YYYYMMDD>-<HHMMSS> — the last two parts.
    parts = body.rsplit("-", 2)
    if len(parts) < 3:
        return ""
    # parts[0] is the scenario id, parts[1] and parts[2] are the timestamp.
    # Validate that the last two parts look like a timestamp.
    ts_candidate = f"{parts[-2]}-{parts[-1]}"
    if len(ts_candidate) == 15 and ts_candidate[8] == "-":
        return parts[0]
    # Fallback: if the timestamp doesn't match, return the whole body
    # minus the last two parts.
    return body[: -(len(parts[-1]) + len(parts[-2]) + 2)]


def _collect_artifact_links(artifact_dir: Path) -> dict[str, Any]:
    """Scan an ``artifacts/`` directory and return relative-path locators.

    Keys:
      - ``"scenario"``: relative path ``"scenario.yaml"`` (if the file exists)
      - ``"overrides"``: relative path ``"applied-overrides.yaml"`` (if the file exists)
      - ``"fixtures"``: list of relative paths to files under ``artifacts/fixtures/``
        (e.g. ``["fixtures/tls.crt"]``); always present when ``fixtures/`` dir exists,
        even if empty.
      - ``"manifests"``: list of relative paths to YAML files under ``artifacts/manifests/``
        (e.g. ``["manifests/deployment.yaml"]``); always present when ``manifests/`` dir
        exists, even if empty.

    All paths are relative to *artifact_dir* so they are portable across machines.
    Returns an empty dict if *artifact_dir* does not exist or is not a directory.
    """
    if not artifact_dir.is_dir():
        return {}

    links: dict[str, Any] = {}

    if (artifact_dir / "scenario.yaml").is_file():
        links["scenario"] = "scenario.yaml"

    if (artifact_dir / "applied-overrides.yaml").is_file():
        links["overrides"] = "applied-overrides.yaml"

    fixtures_dir = artifact_dir / "fixtures"
    if fixtures_dir.is_dir():
        # Relative to artifact_dir: "fixtures/<name>"
        fixture_files = sorted(
            str(p.relative_to(artifact_dir)) for p in fixtures_dir.iterdir() if p.is_file()
        )
        links["fixtures"] = fixture_files  # always present (empty list if no files)

    manifests_dir = artifact_dir / "manifests"
    if manifests_dir.is_dir():
        manifest_files: list[str] = []
        # Recursively collect all YAML files under manifests/, relative to artifact_dir
        for p in sorted(manifests_dir.rglob("*.yaml")):
            if p.is_file():
                manifest_files.append(str(p.relative_to(artifact_dir)))
        links["manifests"] = manifest_files  # always present (empty list if no files)

    return links


def collect_run(reports_dir: Path, run_id: str) -> Run:
    run_dir = reports_dir / run_id
    if not run_dir.is_dir():
        raise FileNotFoundError(f"run dir not found: {run_dir}")

    # Detect orphaned run dirs: no scenarios-snapshot.yaml AND no
    # agent-*/result.yaml files AND no scenario-*/result.yaml files.
    has_snapshot = (run_dir / "scenarios-snapshot.yaml").exists()
    has_agent_results = any(run_dir.glob("agent-*/result.yaml"))
    has_scenario_results = any(run_dir.glob("scenario-*/result.yaml"))
    if not has_snapshot and not has_agent_results and not has_scenario_results:
        print(
            f"warn: skipped orphaned run dir {run_dir.name}"
            f" (no snapshot, no agent/scenario results)",
            file=sys.stderr,
        )
        raise OrphanRunError(run_dir)

    scenarios = load_snapshot(run_dir)
    agent_results = load_agent_results(run_dir)
    scenario_results = load_scenario_results(run_dir)

    by_id = {s.id: s for s in scenarios}

    # Merge agent results into snapshot scenarios.
    for res in agent_results:
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

    # Merge per-scenario results (from scenario-<id>-<ts>/result.yaml).
    # Also build a lookup: scenario_id → artifact_dir for per-scenario
    # artifact population below.
    scenario_artifact_dirs: dict[str, Path] = {}
    for res, art_dir in scenario_results:
        scenario_artifact_dirs[res.id] = art_dir
        if res.id in by_id:
            s = by_id[res.id]
            s.status = res.status
            s.asserts = res.asserts
            s.duration_s = res.duration_s
            s.log_dir = res.log_dir
            s.fail_stage = res.fail_stage
            s.fail_msg = res.fail_msg
        else:
            scenarios.append(res)

    # F2.3: cloud-platform scenarios (gke, eks, aks) always display AUTHORED
    # because they were authored but never actually run locally.
    for s in scenarios:
        if s.cluster_provider in CLOUD_PROVIDERS:
            s.status = "AUTHORED"

    # M11: populate artifact dir and relative links per scenario.
    # Three resolution paths:
    #   1. Per-scenario artifact dirs from scenario-<id>-<ts>/artifacts/
    #   2. Per-agent artifact dirs from agent-<n>/artifacts/
    #   3. Run-level artifacts/ as fallback
    # Cache: agent_n → (source_artifact_dir_or_None, relative_links_dict)
    artifact_info_cache: dict[int | None, tuple[Path | None, dict[str, Any]]] = {}
    for s in scenarios:
        # First: check per-scenario artifact dir (from scenario-*/ directories)
        per_scenario_art_dir = scenario_artifact_dirs.get(s.id)
        if per_scenario_art_dir is not None and per_scenario_art_dir.is_dir():
            _links = _collect_artifact_links(per_scenario_art_dir)
            if _links:
                s.artifact_dir = per_scenario_art_dir
                s.artifact_links = _links
                continue

        # Second: check per-agent artifact dir
        agent = s.agent
        if agent not in artifact_info_cache:
            if agent is not None:
                _adir: Path = run_dir / f"agent-{agent}" / "artifacts"
            else:
                # UNTESTED / no agent assigned — try run-level artifacts as fallback
                _adir = run_dir / "artifacts"
            _links = _collect_artifact_links(_adir)
            # Store None for artifact_dir when no artifacts exist (avoids spurious copies)
            artifact_info_cache[agent] = (_adir if _links else None, _links)
        _src_dir, _rel_links = artifact_info_cache[agent]
        s.artifact_dir = _src_dir
        s.artifact_links = dict(_rel_links)  # defensive copy per scenario

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


def discover_integrations(integrations_dir: Path) -> dict[str, list[str]]:
    """Walk category subdirs under integrations_dir and return
    ``{category: [primer_stem, ...]}`` where primer_stem is the filename
    minus the ``.md`` suffix.

    Only files matching ``*.md`` inside *subdirectories* are discovered —
    stray ``.md`` files at the top level are ignored (post-F1.3 they
    should not exist).
    """
    if not integrations_dir.is_dir():
        return {}
    result: dict[str, list[str]] = {}
    for child in sorted(integrations_dir.iterdir()):
        if not child.is_dir():
            continue
        primers = sorted(p.stem for p in child.iterdir() if p.is_file() and p.suffix == ".md")
        if primers:
            result[child.name] = primers
    return result


def list_runs(reports_dir: Path) -> list[str]:
    """List valid run directories under *reports_dir*.

    Returns sorted directory names matching ``run-*`` but EXCLUDING
    ``run-test-*`` — those are stub artifacts left by the integration
    test suite and must never appear in the dashboard build.
    """
    if not reports_dir.is_dir():
        return []
    return sorted(
        p.name
        for p in reports_dir.iterdir()
        if p.is_dir() and p.name.startswith("run-") and not p.name.startswith("run-test-")
    )
