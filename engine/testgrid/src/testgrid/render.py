"""Render a Run into static HTML + JSON.

The renderer is intentionally JS-free — `<details>` handles expansion.
One sibling stylesheet per output dir; no asset hashing yet.
"""

from __future__ import annotations

import dataclasses
import json
import shutil
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from jinja2 import Environment, PackageLoader, select_autoescape

from .catalog import NOT_YET_RUN, generate_catalog
from .collect import CLOUD_PROVIDERS, STATUS_RANK, Run, Scenario

STATUS_CSS = {
    "PASS": "status-pass",
    "FAIL": "status-fail",
    "PARTIAL": "status-partial",
    "INCONCLUSIVE": "status-inconclusive",
    "INTERRUPTED": "status-interrupted",
    "UNTESTED": "status-untested",
    "AUTHORED": "status-authored",
    "UNKNOWN": "status-unknown",
}

# Chart-test-swarm mechanism vocabulary. Free-form, but these are the
# categories the dashboard knows how to group.
MECHANISM_CATEGORIES = ["addon", "subchart", "mesh", "ingress", "customer", "cloud", "version"]


# ---------------------------------------------------------------------------
# Variant grouping (F2.2)
# ---------------------------------------------------------------------------

GROUPING_THRESHOLD = 3
"""Minimum number of scenarios sharing a (category, integration) before
they are collapsed under a single integration header row."""


@dataclass
class VariantGroup:
    """A group of scenarios that share the same ``(category, integration)``.

    Rendered as a collapsible ``<details>`` block with the integration as
    the header summary and each variant member as a row in a sub-table.
    """

    category: str
    """e.g. ``certificates``, ``ingress-controllers``, ``service-mesh``."""

    integration: str
    """e.g. ``cert-manager``, ``traefik``, ``istio-ingress-gateway``."""

    scenarios: list[Scenario] = field(default_factory=list)
    """The variant scenarios belonging to this group."""

    @property
    def key(self) -> str:
        """Stable identifier for the group, e.g. ``certificates:cert-manager``."""
        return f"{self.category}:{self.integration}"

    @property
    def anchor(self) -> str:
        """HTML-safe anchor id for the group."""
        return f"group--{self.category}--{self.integration}"

    @property
    def variant_count(self) -> int:
        return len(self.scenarios)

    @property
    def rolled_status(self) -> str:
        """Worst-of-set status using ``STATUS_RANK`` ordering."""
        if not self.scenarios:
            return "UNTESTED"
        return min(
            (s.status for s in self.scenarios),
            key=lambda st: STATUS_RANK.get(st, 99),
        )

    @property
    def status_counts(self) -> dict[str, int]:
        """Per-status count across all variant scenarios."""
        counts: dict[str, int] = {}
        for s in self.scenarios:
            counts[s.status] = counts.get(s.status, 0) + 1
        return counts

    @property
    def status_breakdown(self) -> str:
        """Human-readable breakdown, e.g. ``"1 FAIL / 2 PASS"``.

        Iterates ``STATUS_RANK`` keys in rank order so adding a new status
        to ``STATUS_RANK`` automatically surfaces in breakdown text.
        Any statuses present in counts but not in ``STATUS_RANK`` (e.g.
        ``UNKNOWN``) are appended at the end.
        """
        parts: list[str] = []
        seen: set[str] = set()
        for st in STATUS_RANK:
            cnt = self.status_counts.get(st, 0)
            if cnt > 0:
                parts.append(f"{cnt} {st}")
                seen.add(st)
        # Append any statuses not in STATUS_RANK (e.g. UNKNOWN).
        for st, cnt in sorted(self.status_counts.items()):
            if cnt > 0 and st not in seen:
                parts.append(f"{cnt} {st}")
        return " / ".join(parts) if parts else "0 UNTESTED"


def _primary_mechanism_key(mechanisms: list[str]) -> tuple[str, str] | None:
    """Extract the ``(category, integration)`` key from a scenario's
    mechanism list.

    Uses the first mechanism that has at least two colon-separated parts
    (``category:integration`` or ``category:integration:variant``).
    Returns ``None`` if no suitable mechanism is found.
    """
    for m in mechanisms:
        parts = m.split(":")
        if len(parts) >= 2:
            return parts[0], parts[1]
    return None


def build_variant_groups(run: Run) -> tuple[list[VariantGroup], list[Scenario]]:
    """Partition *run.scenarios* into integration groups and standalones.

    **Groups**: Scenarios that share a ``(category, integration)`` key AND
    have at least ``GROUPING_THRESHOLD`` members are collapsed into a
    ``VariantGroup``.

    **Standalone**: Every scenario NOT in a qualifying group — this includes
    scenarios with no mechanisms, scenarios whose group has fewer than the
    threshold, and scenarios whose mechanism key could not be determined.

    Returns ``(groups, standalone)``.
    """
    # Bucket by (category, integration) key.
    buckets: dict[tuple[str, str], list[Scenario]] = defaultdict(list)
    unkeyed: list[Scenario] = []

    for s in run.scenarios:
        key = _primary_mechanism_key(s.mechanisms)
        if key is None:
            unkeyed.append(s)
        else:
            buckets[key].append(s)

    groups: list[VariantGroup] = []
    standalone: list[Scenario] = []

    for (cat, integ), members in sorted(buckets.items()):
        if len(members) >= GROUPING_THRESHOLD:
            groups.append(VariantGroup(category=cat, integration=integ, scenarios=members))
        else:
            standalone.extend(members)

    standalone.extend(unkeyed)
    return groups, standalone


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


CLOUD_TOOLTIP = "authored, not run locally"


def _is_cloud_provider(provider: str) -> bool:
    """Return True if *provider* is a cloud platform (gke, eks, aks)."""
    return provider in CLOUD_PROVIDERS


def _make_env() -> Environment:
    env = Environment(
        loader=PackageLoader("testgrid", "templates"),
        autoescape=select_autoescape(["html", "j2"]),
        trim_blocks=True,
        lstrip_blocks=True,
    )
    env.globals.update(
        status_class=status_class,
        rollup_status=rollup_status,
        is_cloud_provider=_is_cloud_provider,
        cloud_tooltip=CLOUD_TOOLTIP,
        cloud_providers=CLOUD_PROVIDERS,
    )
    env.filters["basename"] = lambda p: Path(str(p)).name if p else ""
    return env


def _copy_assets(out_dir: Path) -> None:
    css_src = Path(__file__).parent / "templates" / "style.css"
    shutil.copy(css_src, out_dir / "style.css")


def _copy_artifact_bundle(
    scenario_id: str,
    artifact_dir: Path,
    artifact_links: dict[str, Any],
    run_out_dir: Path,
) -> dict[str, Any]:
    """Copy artifact files from *artifact_dir* into the dist tree and return relative hrefs.

    For each key in *artifact_links* (which holds relative paths within the bundle,
    e.g. ``"scenario.yaml"`` or ``["fixtures/tls.crt"]``), this function:

    1. Copies the source file from ``artifact_dir/<rel_path>`` to
       ``run_out_dir/<scenario_id>/artifacts/<rel_path>`` (byte-identical via
       ``shutil.copy2``).
    2. Returns a new dict whose values are relative hrefs suitable for use in
       the rendered HTML, e.g. ``"<scenario_id>/artifacts/scenario.yaml"``.

    Relative hrefs are relative to ``run_out_dir/index.html`` — the run page that
    contains the scenario card.  They never begin with ``/``, ``file:``,
    ``http(s):``, or a host filesystem prefix.

    The original *artifact_dir* (under ``reports/``) is never modified.
    Parent directories under the dest tree are created as needed.
    Files are copied in deterministic (sorted) order for reproducible builds.
    """
    rel_hrefs: dict[str, Any] = {}
    scenario_art_dir = run_out_dir / scenario_id / "artifacts"

    if "scenario" in artifact_links:
        src = artifact_dir / artifact_links["scenario"]
        dst = scenario_art_dir / "scenario.yaml"
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(src), str(dst))
        rel_hrefs["scenario"] = f"{scenario_id}/artifacts/scenario.yaml"

    if "overrides" in artifact_links:
        src = artifact_dir / artifact_links["overrides"]
        dst = scenario_art_dir / "applied-overrides.yaml"
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(src), str(dst))
        rel_hrefs["overrides"] = f"{scenario_id}/artifacts/applied-overrides.yaml"

    if "fixtures" in artifact_links:
        fixture_hrefs: list[str] = []
        for rel_path in sorted(artifact_links["fixtures"]):
            src = artifact_dir / rel_path
            dst = scenario_art_dir / rel_path
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(src), str(dst))
            fixture_hrefs.append(f"{scenario_id}/artifacts/{rel_path}")
        rel_hrefs["fixtures"] = sorted(fixture_hrefs)

    if "manifests" in artifact_links:
        manifest_hrefs: list[str] = []
        for rel_path in sorted(artifact_links["manifests"]):
            src = artifact_dir / rel_path
            dst = scenario_art_dir / rel_path
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(src), str(dst))
            manifest_hrefs.append(f"{scenario_id}/artifacts/{rel_path}")
        rel_hrefs["manifests"] = sorted(manifest_hrefs)

    return rel_hrefs


def render_run(run: Run, out_dir: Path) -> Path:
    env = _make_env()
    tpl = env.get_template("run.html.j2")
    run_dir = out_dir / run.run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    # Deterministic ordering: sort scenarios lexicographically by id
    # before building variant groups and rendering.
    run.scenarios.sort(key=lambda s: s.id)
    # Re-sort variant group members for deterministic sub-table ordering.
    # Also sort standalone scenarios within the run (already done above).

    # M11: copy artifact files into dist tree and replace artifact_links with
    # relative hrefs (relative to run_dir/index.html).  Scenarios without an
    # artifact_dir (legacy runs or UNTESTED) are left with an empty dict.
    for s in run.scenarios:
        if s.artifact_dir is not None and s.artifact_links:
            s.artifact_links = _copy_artifact_bundle(
                s.id, s.artifact_dir, s.artifact_links, run_dir
            )

    groups, standalone = build_variant_groups(run)
    # Ensure variant group members are sorted lexicographically.
    for g in groups:
        g.scenarios.sort(key=lambda s: s.id)
    standalone.sort(key=lambda s: s.id)

    html = tpl.render(
        run=run,
        mechanisms_by_category=mechanisms_by_category(run),
        variant_groups=groups,
        standalone_scenarios=standalone,
        VariantGroup=VariantGroup,
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


# ---------------------------------------------------------------------------
# Support matrix (f12-5, VAL-CAT-008..011)
# ---------------------------------------------------------------------------

AUTHORED_ONLY_TIERS: frozenset[str] = frozenset({"authored-only"})
"""Tier values that indicate a scenario was authored but not run locally."""


@dataclass
class SupportMatrixEntry:
    """A single scenario row in the support-matrix view.

    Derived from the catalog and cross-referenced with run results.
    """

    scenario_id: str
    name: str
    category: str
    integration_key: str
    tier: str | None
    status: str
    scenario_href: str | None
    """Relative href to the scenario YAML in the dist tree, or None."""
    overrides_href: str | None
    """Relative href to the applied-overrides YAML in the dist tree, or None."""
    is_authored_only: bool
    """True when tier is authored-only or provider is a cloud platform."""

    @property
    def display_status(self) -> str:
        """Status to display in the matrix cell.

        Authored-only entries always display ``AUTHORED`` regardless of
        any stored status, per VAL-CAT-010.
        """
        if self.is_authored_only:
            return "AUTHORED"
        return self.status


def _resolve_scenario_status(
    scenario_id: str,
    runs: list[Run],
) -> str:
    """Find the latest run status for *scenario_id* across all runs.

    Returns ``"UNTESTED"`` when no run contains the scenario.
    """
    latest_status = "UNTESTED"
    for run in runs:
        for s in run.scenarios:
            if s.id == scenario_id:
                latest_status = s.status
    return latest_status


def _copy_catalog_scenario_yaml(
    scenarios_dir: Path,
    catalog_entry: dict[str, Any],
    catalog_dist_dir: Path,
) -> str:
    """Copy a scenario YAML from the scenarios tree into dist/catalog/.

    Returns the relative href (from the support-matrix page) to the
    copied file, e.g. ``catalog/certificates/cert-manager-self-signed.yaml``.
    """
    rel_path: str = str(catalog_entry["path"])
    src = scenarios_dir / rel_path
    if not src.is_file():
        return rel_path  # Graceful: href points at would-be location

    dst = catalog_dist_dir / rel_path
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(src), str(dst))
    return f"catalog/{rel_path}"


def _copy_catalog_overrides(
    reports_dir: Path | None,
    catalog_entry: dict[str, Any],
    catalog_dist_dir: Path,
) -> str | None:
    """Copy applied-overrides from the reports tree into dist/catalog/.

    Returns the relative href (from the support-matrix page) to the
    copied file, e.g. ``catalog/overrides/<scenario-id>.yaml``,
    or ``None`` when no overrides are available.
    """
    overrides_ref = catalog_entry.get("overrides")
    if overrides_ref is None or overrides_ref == NOT_YET_RUN or reports_dir is None:
        return None

    src = reports_dir / overrides_ref
    if not src.is_file():
        return None

    scenario_id = catalog_entry["id"]
    dst = catalog_dist_dir / "overrides" / f"{scenario_id}.yaml"
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(src), str(dst))
    return f"catalog/overrides/{scenario_id}.yaml"


def build_support_matrix(
    scenarios_dir: Path,
    reports_dir: Path | None,
    runs: list[Run],
    catalog_dist_dir: Path,
) -> dict[str, list[SupportMatrixEntry]]:
    """Build the support-matrix data structure from the catalog + runs.

    Copies scenario YAMLs and overrides into *catalog_dist_dir* so
    they can be served over HTTP.  Returns a mapping of
    ``category → [SupportMatrixEntry, ...]``, sorted lexicographically
    at every level.

    Authored-only entries (tier=authored-only or cloud provider) are
    marked ``is_authored_only=True`` so the template can display them
    with the AUTHORED badge and exclude them from run counts.
    """
    catalog_dist_dir.mkdir(parents=True, exist_ok=True)
    catalog = generate_catalog(scenarios_dir, reports_dir=reports_dir)

    matrix: dict[str, list[SupportMatrixEntry]] = {}
    for category, integrations in catalog.items():
        entries: list[SupportMatrixEntry] = []
        for integration_key, scenario_entries in integrations.items():
            for entry in scenario_entries:
                scenario_id = entry["id"]
                tier = entry.get("tier")

                # Determine if this is an authored-only entry.
                # Tier takes priority; also check cluster provider for
                # backward-compat scenarios without the tier field.
                is_authored = tier in AUTHORED_ONLY_TIERS
                # If tier is not set, check if the scenario YAML itself
                # declares a cloud provider.
                if not is_authored:
                    scenario_src = scenarios_dir / entry["path"]
                    scenario_doc = _load_scenario_yaml(scenario_src)
                    if scenario_doc is not None:
                        provider = ""
                        cluster = scenario_doc.get("cluster")
                        if isinstance(cluster, dict):
                            provider = cluster.get("provider", "")
                        if provider in CLOUD_PROVIDERS:
                            is_authored = True

                # Resolve status from latest run.
                raw_status = _resolve_scenario_status(scenario_id, runs)
                status = "AUTHORED" if is_authored else raw_status

                # Copy scenario YAML and overrides into dist tree.
                scenario_href = _copy_catalog_scenario_yaml(scenarios_dir, entry, catalog_dist_dir)
                overrides_href = _copy_catalog_overrides(reports_dir, entry, catalog_dist_dir)

                entries.append(
                    SupportMatrixEntry(
                        scenario_id=scenario_id,
                        name=entry.get("name", ""),
                        category=category,
                        integration_key=integration_key,
                        tier=tier,
                        status=status,
                        scenario_href=scenario_href,
                        overrides_href=overrides_href,
                        is_authored_only=is_authored,
                    )
                )
        # Sort entries lexicographically for determinism.
        entries.sort(key=lambda e: (e.integration_key, e.scenario_id))
        matrix[category] = entries

    # Sort categories lexicographically.
    return dict(sorted(matrix.items()))


def _load_scenario_yaml(path: Path) -> dict[str, Any] | None:
    """Load a scenario YAML, returning None on parse errors."""
    import yaml

    try:
        with path.open(encoding="utf-8") as f:
            doc = yaml.safe_load(f)
        if isinstance(doc, dict):
            return doc
    except (yaml.YAMLError, OSError):
        pass
    return None


def support_matrix_run_counts(
    entries: list[SupportMatrixEntry],
) -> dict[str, int]:
    """Compute run/pass/fail counts EXCLUDING authored-only entries.

    Per VAL-CAT-010, authored-only scenarios must not inflate the
    run/pass/fail tallies.
    """
    counts: dict[str, int] = {"run": 0, "PASS": 0, "FAIL": 0}
    for e in entries:
        if e.is_authored_only:
            continue
        if e.status not in ("UNTESTED",):
            counts["run"] += 1
        if e.status in STATUS_RANK:
            counts[e.status] = counts.get(e.status, 0) + 1
    return counts


def render_support_matrix(
    scenarios_dir: Path,
    reports_dir: Path | None,
    runs: list[Run],
    out_dir: Path,
) -> Path:
    """Render the support-matrix page into *out_dir*.

    Returns the path to the written ``support-matrix.html``.
    """
    catalog_dist_dir = out_dir / "catalog"
    matrix = build_support_matrix(scenarios_dir, reports_dir, runs, catalog_dist_dir)

    # Compute global counts (excluding authored-only).
    all_entries: list[SupportMatrixEntry] = []
    for entries in matrix.values():
        all_entries.extend(entries)
    global_counts = support_matrix_run_counts(all_entries)

    env = _make_env()
    tpl = env.get_template("support_matrix.html.j2")
    html = tpl.render(
        matrix=matrix,
        global_counts=global_counts,
        support_matrix_run_counts=support_matrix_run_counts,
    )
    out_path = out_dir / "support-matrix.html"
    out_path.write_text(html, encoding="utf-8")
    _copy_assets(out_dir)
    return out_path


def _run_to_json(run: Run) -> str:
    return json.dumps(dataclasses.asdict(run), indent=2, default=str)
