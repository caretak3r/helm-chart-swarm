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

from jinja2 import Environment, PackageLoader, select_autoescape

from .collect import CLOUD_PROVIDERS, STATUS_RANK, Run, Scenario

STATUS_CSS = {
    "PASS": "status-pass",
    "FAIL": "status-fail",
    "PARTIAL": "status-partial",
    "INCONCLUSIVE": "status-inconclusive",
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


def _run_to_json(run: Run) -> str:
    return json.dumps(dataclasses.asdict(run), indent=2, default=str)
