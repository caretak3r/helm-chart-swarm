"""Recommendations engine for chart-test-swarm.

Scans all FAIL scenario results across runs, auto-classifies failures into
typed categories, generates deterministic recommendation objects, deduplicates
across runs, and persists state to ``reports/recommendations.json``.

Usage
-----
::

    from testgrid.collect import collect_run, list_runs
    from testgrid.recommendations import (
        generate_recommendations,
        load_recommendations,
        save_recommendations,
        count_open_recommendations,
    )

    reports_dir = Path("reports")
    runs = [collect_run(reports_dir, rid) for rid in list_runs(reports_dir)]
    existing = load_recommendations(reports_dir)
    recs = generate_recommendations(runs, existing=existing)
    save_recommendations(reports_dir, recs)
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .collect import Run, Scenario

# ---------------------------------------------------------------------------
# Classification constants
# ---------------------------------------------------------------------------

#: Assert types that indicate a chart-fix is required (capability FAIL).
CHART_FIX_ASSERT_TYPES: frozenset[str] = frozenset(
    {
        "labels-present",
        "annotations-present",
        "rbac-objects",
        "scheme-enforced",
        "security-context",
        "network-policy",
        "resources-present",
        "imagepullsecrets-present",
        "serviceaccount-annotations",
        "scheduling-present",
        "priority-class-present",
    }
)

#: Keywords whose presence in ``fail_msg`` (case-insensitive) indicates an
#: infrastructure gap (CNI, proxy, network plugin).
INFRASTRUCTURE_KEYWORDS: frozenset[str] = frozenset(
    {
        "cni",
        "proxy",
        "istio-cni",
        "calico",
        "flannel",
    }
)

#: Substrings in ``scenario_id`` that identify a known gap-probe scenario.
GAP_PROBE_PATTERNS: tuple[str, ...] = (
    "contour-basic-httpproxy",
    "gatekeeper-required-labels",
)

#: Assert types / scenario keywords that indicate *high* severity.
HIGH_SEVERITY_ASSERT_TYPES: frozenset[str] = frozenset(
    {
        "rbac-objects",
        "scheme-enforced",
    }
)

#: Assert types / scenario keywords that indicate *medium* severity.
MEDIUM_SEVERITY_ASSERT_TYPES: frozenset[str] = frozenset(
    {
        "labels-present",
        "annotations-present",
    }
)

#: K8s object type names to look for in assertion notes.
K8S_OBJECT_TYPES: tuple[str, ...] = (
    "Deployment",
    "StatefulSet",
    "DaemonSet",
    "ReplicaSet",
    "Pod",
    "Service",
    "Ingress",
    "ConfigMap",
    "Secret",
    "ServiceAccount",
    "Role",
    "ClusterRole",
    "RoleBinding",
    "ClusterRoleBinding",
    "HorizontalPodAutoscaler",
    "PodDisruptionBudget",
    "NetworkPolicy",
    "PersistentVolumeClaim",
    "HTTPProxy",
    "IngressRoute",
)


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class Recommendation:
    """A single actionable recommendation derived from one or more FAIL scenarios.

    Attributes
    ----------
    id:
        Deterministic hash-based identifier, e.g. ``"rec-a1b2c3d4e5f6"``.
        Stable across engine restarts when input is identical.
    scenario_id:
        The scenario that failed, e.g. ``"labels-on"``.
    category:
        One of ``chart-fix``, ``infrastructure``, ``gap-probe``,
        ``schema-missing``.
    severity:
        One of ``high``, ``medium``, ``low``.
    title:
        Short human-readable description of the issue.
    detail:
        Full failure notes from assertion results.
    affected_objects:
        K8s object types referenced in the failure (e.g. ``["Service", "Deployment"]``).
    status:
        Lifecycle status — one of ``open``, ``in_progress``, ``fixed``, ``dismissed``.
    run_refs:
        Run IDs that exhibited this failure.  Populated by deduplication.
    fix_prompt:
        Auto-generated LLM prompt with full chart context, ready for
        ``chart-test-swarm generate author``.
    dismissed_reason:
        User-supplied reason when ``status == "dismissed"``; empty otherwise.
    created_at:
        ISO 8601 timestamp of first creation.
    updated_at:
        ISO 8601 timestamp of last update.
    """

    id: str
    scenario_id: str
    category: str
    severity: str
    title: str
    detail: str
    affected_objects: list[str]
    status: str
    run_refs: list[str]
    fix_prompt: str
    dismissed_reason: str = ""
    created_at: str = ""
    updated_at: str = ""


# ---------------------------------------------------------------------------
# Classification helpers
# ---------------------------------------------------------------------------


def _primary_fail_type(scenario: Scenario) -> str:
    """Return the primary failure type for a FAIL scenario.

    Checks all assertions for a FAIL status (first match wins).
    Falls back to ``fail_stage`` when no assertion has FAIL status.
    Falls back to ``"unknown"`` as a last resort.
    """
    for a in scenario.asserts:
        if a.status == "FAIL":
            return a.type
    if scenario.fail_stage:
        return scenario.fail_stage
    return "unknown"


def classify_failure(scenario: Scenario) -> str:
    """Classify a FAIL scenario into one of the four recommendation categories.

    Classification order (first match wins):
    1. ``gap-probe``  — scenario_id contains a known gap-probe pattern substring
    2. ``chart-fix``  — any failing assertion type is in CHART_FIX_ASSERT_TYPES
    3. ``infrastructure`` — ``fail_msg`` (case-insensitive) contains an
       INFRASTRUCTURE_KEYWORDS substring
    4. ``schema-missing`` — catch-all fallback

    Parameters
    ----------
    scenario:
        A ``Scenario`` with ``status == "FAIL"``.

    Returns
    -------
    str
        One of ``"chart-fix"``, ``"infrastructure"``, ``"gap-probe"``,
        ``"schema-missing"``.
    """
    # 1. Gap-probe check (evaluated before chart-fix to avoid false chart-fix
    #    classification for scenarios that happen to have a chart-fix assert type
    #    but are fundamentally honest integration gaps).
    for pattern in GAP_PROBE_PATTERNS:
        if pattern in scenario.id:
            return "gap-probe"

    # 2. Chart-fix check: look at ALL failing assertions.
    for a in scenario.asserts:
        if a.status == "FAIL" and a.type in CHART_FIX_ASSERT_TYPES:
            return "chart-fix"

    # 3. Infrastructure check: keywords in fail_msg.
    fail_msg_lower = scenario.fail_msg.lower()
    for keyword in INFRASTRUCTURE_KEYWORDS:
        if keyword in fail_msg_lower:
            return "infrastructure"

    # 4. Fallback.
    return "schema-missing"


def assign_severity(scenario: Scenario, category: str) -> str:
    """Assign a severity level based on the failure category and type.

    Rules:
    - ``gap-probe`` → always ``low``
    - Any failing assertion in HIGH_SEVERITY_ASSERT_TYPES → ``high``
    - Any failing assertion in MEDIUM_SEVERITY_ASSERT_TYPES → ``medium``
    - Scenario ID heuristics as fallback:
      - contains ``rbac`` / ``scheme`` / ``security`` → ``high``
      - contains ``label`` / ``annotation`` → ``medium``
    - Default: ``low``

    Parameters
    ----------
    scenario:
        The failing scenario.
    category:
        The pre-computed classification category.

    Returns
    -------
    str
        One of ``"high"``, ``"medium"``, ``"low"``.
    """
    if category == "gap-probe":
        return "low"

    # Check all failing assertions for severity signals.
    for a in scenario.asserts:
        if a.status == "FAIL" and a.type in HIGH_SEVERITY_ASSERT_TYPES:
            return "high"

    for a in scenario.asserts:
        if a.status == "FAIL" and a.type in MEDIUM_SEVERITY_ASSERT_TYPES:
            return "medium"

    # Fallback: scenario_id keyword heuristics.
    sid_lower = scenario.id.lower()
    if any(kw in sid_lower for kw in ("rbac", "scheme", "security")):
        return "high"
    if any(kw in sid_lower for kw in ("label", "annotation")):
        return "medium"

    return "low"


# ---------------------------------------------------------------------------
# Recommendation generation helpers
# ---------------------------------------------------------------------------


def _make_rec_id(scenario_id: str, failure_type: str) -> str:
    """Generate a deterministic, stable recommendation ID.

    The ID is a 12-character hex digest of
    ``"<scenario_id>:<failure_type>"``, prefixed with ``"rec-"``.
    This makes it stable across engine restarts as long as the input
    (scenario_id, failure_type) pair does not change.
    """
    key = f"{scenario_id}:{failure_type}"
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]
    return f"rec-{digest}"


def _extract_affected_objects(scenario: Scenario) -> list[str]:
    """Extract k8s object type names mentioned in failing assertion notes.

    Scans ``notes`` of all assertions with ``status == "FAIL"`` and
    returns each K8s type mentioned (in the order first encountered,
    de-duplicated).

    Returns
    -------
    list[str]
        Ordered, de-duplicated list of K8s object type names, e.g.
        ``["Deployment", "Service", "Ingress"]``.
    """
    seen: set[str] = set()
    objects: list[str] = []
    for a in scenario.asserts:
        if a.status == "FAIL" and a.notes:
            for obj_type in K8S_OBJECT_TYPES:
                if obj_type in a.notes and obj_type not in seen:
                    seen.add(obj_type)
                    objects.append(obj_type)
    return objects


def _generate_title(scenario: Scenario, category: str, fail_type: str) -> str:
    """Generate a short, human-readable recommendation title."""
    if category == "chart-fix":
        if fail_type == "labels-present":
            return f"Add missing labels to chart objects in scenario '{scenario.id}'"
        if fail_type == "annotations-present":
            return f"Add missing annotations to chart objects in scenario '{scenario.id}'"
        if fail_type == "rbac-objects":
            return (
                f"Add RBAC objects (ServiceAccount / Role / RoleBinding) "
                f"for scenario '{scenario.id}'"
            )
        if fail_type == "scheme-enforced":
            return f"Enforce HTTPS-only scheme in chart for scenario '{scenario.id}'"
        if fail_type == "security-context":
            return f"Add security context to chart pods for scenario '{scenario.id}'"
        if fail_type == "network-policy":
            return f"Add NetworkPolicy templates to chart for scenario '{scenario.id}'"
        if fail_type == "resources-present":
            return f"Add resource requests/limits to chart pods for scenario '{scenario.id}'"
        return f"Fix chart capability gap: {fail_type} in scenario '{scenario.id}'"
    if category == "infrastructure":
        return f"Infrastructure preinstall missing for scenario '{scenario.id}'"
    if category == "gap-probe":
        return f"Honest gap: chart does not natively support scenario '{scenario.id}'"
    # schema-missing
    return f"Schema or values configuration missing for scenario '{scenario.id}'"


def _generate_detail(scenario: Scenario) -> str:
    """Generate full failure detail text from the scenario.

    Includes ``fail_msg`` (when present) and per-assertion notes for all
    FAIL assertions.  Falls back to ``fail_stage`` when no other
    information is available.
    """
    parts: list[str] = []
    if scenario.fail_msg:
        parts.append(f"Failure message: {scenario.fail_msg.strip()}")
    for a in scenario.asserts:
        if a.status == "FAIL":
            note = a.notes.strip() if a.notes else "(no notes)"
            parts.append(f"Assert '{a.type}': {note}")
    if not parts:
        if scenario.fail_stage:
            parts.append(f"Failed at stage: {scenario.fail_stage}")
        else:
            parts.append("No failure details available.")
    return "\n".join(parts)


def _generate_fix_prompt(
    scenario: Scenario,
    category: str,
    fail_type: str,
    chart_path: str,
) -> str:
    """Generate an LLM-ready fix prompt with full chart context.

    The prompt is structured for consumption by ``chart-test-swarm generate
    author`` and includes the scenario name, failure type, affected objects,
    full failure detail, and category-specific actionable instructions.

    Parameters
    ----------
    scenario:
        The failing scenario.
    category:
        The pre-computed classification category.
    fail_type:
        The primary failure type (assert type or fail_stage).
    chart_path:
        Path to the chart root (relative to project), e.g.
        ``"examples/sample-product-chart/chart"``.

    Returns
    -------
    str
        A Markdown-formatted LLM prompt.
    """
    detail = _generate_detail(scenario)
    affected = _extract_affected_objects(scenario)
    affected_str = ", ".join(affected) if affected else "all chart objects"

    if category == "chart-fix":
        if fail_type == "labels-present":
            action = (
                f"Add support for global extra labels (e.g. `extraLabels`) "
                f"to all chart templates under `{chart_path}/templates/`. "
                f"Every Deployment, Service, Ingress, and other manifest objects "
                f"must propagate labels from `extraLabels` to `.metadata.labels`."
            )
        elif fail_type == "annotations-present":
            action = (
                f"Add support for global extra annotations (e.g. `extraAnnotations`) "
                f"to all chart templates under `{chart_path}/templates/`. "
                f"Every object must propagate annotations from `extraAnnotations` "
                f"to `.metadata.annotations`."
            )
        elif fail_type == "rbac-objects":
            action = (
                f"Add RBAC templates to `{chart_path}/templates/`: "
                f"`serviceaccount.yaml`, `role.yaml` (or `clusterrole.yaml`), "
                f"and `rolebinding.yaml` (or `clusterrolebinding.yaml`). "
                f"Gate them behind `rbac.create` and `serviceAccount.create` values "
                f"in `{chart_path}/values.yaml`."
            )
        elif fail_type == "scheme-enforced":
            action = (
                f"Add HTTPS-only enforcement to `{chart_path}/templates/`. "
                f"When `tls.enabled=true`, suppress HTTP port 80 from Service "
                f"and Deployment containerPorts. Add a redirect or block for plain HTTP."
            )
        elif fail_type == "security-context":
            action = (
                f"Add `securityContext` blocks to pod specs in "
                f"`{chart_path}/templates/`. "
                f"Set appropriate `runAsNonRoot`, `readOnlyRootFilesystem`, "
                f"and `allowPrivilegeEscalation` values."
            )
        elif fail_type == "network-policy":
            action = (
                f"Add a `NetworkPolicy` template to `{chart_path}/templates/` "
                f"that allows only required ingress/egress traffic. "
                f"Gate it behind a `networkPolicy.enabled` value."
            )
        elif fail_type == "resources-present":
            action = (
                f"Add `resources.requests` and `resources.limits` to all container "
                f"specs in `{chart_path}/templates/`. "
                f"Expose them via `resources:` in `{chart_path}/values.yaml`."
            )
        else:
            action = (
                f"Fix the '{fail_type}' capability gap in `{chart_path}/templates/`. "
                f"Review the assertion notes above and update chart templates "
                f"to satisfy the assertion requirements."
            )
    elif category == "infrastructure":
        action = (
            "The scenario requires an infrastructure preinstall (CNI, proxy, or "
            "network plugin). Add the required preinstall to the scenario YAML "
            "under `cluster.preinstall`, or ensure the cluster has the required "
            "networking plugin installed before running the scenario."
        )
    elif category == "gap-probe":
        action = (
            f"This is an **honest gap**: the chart does not natively emit the "
            f"CRD or object required by scenario `{scenario.id}`. "
            f"If you wish to close this gap, add chart template(s) to "
            f"`{chart_path}/templates/` that emit the required objects "
            f"(e.g. HTTPProxy, ConstraintTemplate, or similar)."
        )
    else:
        action = (
            f"Review the scenario values and chart schema for `{scenario.id}`. "
            f"Add missing values.yaml entries or chart template defaults in "
            f"`{chart_path}/`."
        )

    return (
        f"# Fix Recommendation: {scenario.id}\n\n"
        f"**Scenario:** `{scenario.id}`\n"
        f"**Category:** {category}\n"
        f"**Failure type:** {fail_type}\n"
        f"**Affected objects:** {affected_str}\n\n"
        f"## Failure Detail\n\n"
        f"{detail}\n\n"
        f"## Suggested Fix\n\n"
        f"{action}\n\n"
        f"**Chart path:** `{chart_path}`\n"
        f"**Only modify files under `{chart_path}/`.**\n"
    )


# ---------------------------------------------------------------------------
# Main engine
# ---------------------------------------------------------------------------


def generate_recommendations(
    runs: list[Run],
    existing: list[Recommendation] | None = None,
    chart_path: str = "examples/sample-product-chart/chart",
) -> list[Recommendation]:
    """Scan FAIL scenario results across *runs* and emit a deduplicated list
    of :class:`Recommendation` objects.

    Deduplication key: ``(scenario_id, failure_type)``.  The same failure
    appearing in multiple runs produces a single recommendation whose
    ``run_refs`` lists all contributing run IDs.

    Status preservation:
    - Existing recommendations whose ``(scenario_id, failure_type)`` is
      still failing in *runs* preserve their current ``status``, ``dismissed_reason``,
      and ``created_at``.
    - Existing recommendations with status ``"open"`` or ``"in_progress"``
      that are no longer failing have their ``status`` set to ``"fixed"``.
    - Existing recommendations with status ``"dismissed"`` are preserved
      as-is — the user explicitly dismissed them and they should not
      silently vanish.
    - Existing recommendations with status ``"fixed"`` stay ``"fixed"``.
    - New failures create new recommendations with ``status = "open"``.

    Parameters
    ----------
    runs:
        List of :class:`Run` objects to scan for FAIL scenarios.
    existing:
        Previously-persisted recommendations (from :func:`load_recommendations`).
        Pass ``None`` or ``[]`` on first run.
    chart_path:
        Relative path to the chart root used in fix-prompt generation.

    Returns
    -------
    list[Recommendation]
        Deduplicated, merged recommendation list.
    """
    now = datetime.now(UTC).isoformat()

    # Build a lookup from existing recommendations by ID.
    existing_by_id: dict[str, Recommendation] = {}
    if existing:
        for rec in existing:
            existing_by_id[rec.id] = rec

    # Accumulate new recommendations keyed by rec_id (for deduplication).
    # We process runs in order so run_refs are deterministically ordered.
    new_recs: dict[str, Recommendation] = {}

    for run in runs:
        for scenario in run.scenarios:
            if scenario.status != "FAIL":
                continue

            fail_type = _primary_fail_type(scenario)
            rec_id = _make_rec_id(scenario.id, fail_type)

            if rec_id in new_recs:
                # Deduplication: extend run_refs if this run isn't already listed.
                rec = new_recs[rec_id]
                if run.run_id not in rec.run_refs:
                    rec.run_refs.append(run.run_id)
                    rec.updated_at = now
            else:
                category = classify_failure(scenario)
                severity = assign_severity(scenario, category)
                title = _generate_title(scenario, category, fail_type)
                detail = _generate_detail(scenario)
                affected_objects = _extract_affected_objects(scenario)
                fix_prompt = _generate_fix_prompt(scenario, category, fail_type, chart_path)

                # Preserve status/reason/created_at from existing recommendation.
                existing_rec = existing_by_id.get(rec_id)
                status = existing_rec.status if existing_rec else "open"
                dismissed_reason = existing_rec.dismissed_reason if existing_rec else ""
                created_at = existing_rec.created_at if existing_rec else now

                new_recs[rec_id] = Recommendation(
                    id=rec_id,
                    scenario_id=scenario.id,
                    category=category,
                    severity=severity,
                    title=title,
                    detail=detail,
                    affected_objects=affected_objects,
                    status=status,
                    run_refs=[run.run_id],
                    fix_prompt=fix_prompt,
                    dismissed_reason=dismissed_reason,
                    created_at=created_at,
                    updated_at=now,
                )

    # Carry forward existing recommendations whose failures are no longer
    # present in the new runs.
    for rec_id, existing_rec in existing_by_id.items():
        if rec_id not in new_recs:
            d = asdict(existing_rec)
            d["updated_at"] = now
            if existing_rec.status in ("open", "in_progress"):
                # No longer failing — mark as "fixed".
                d["status"] = "fixed"
            # "dismissed" recommendations are preserved as-is — the user
            # explicitly dismissed them and they should not silently vanish.
            # "fixed" recommendations stay "fixed".
            new_recs[rec_id] = Recommendation(**d)

    return list(new_recs.values())


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------


def load_recommendations(reports_dir: Path) -> list[Recommendation]:
    """Load recommendations from ``<reports_dir>/recommendations.json``.

    Returns an empty list when the file does not exist or cannot be parsed.

    Parameters
    ----------
    reports_dir:
        Directory containing ``recommendations.json``.
    """
    rec_json = reports_dir / "recommendations.json"
    if not rec_json.is_file():
        return []
    try:
        data = json.loads(rec_json.read_text(encoding="utf-8"))
        recs: list[Recommendation] = []
        for r in data.get("recommendations", []):
            recs.append(
                Recommendation(
                    id=str(r.get("id", "")),
                    scenario_id=str(r.get("scenario_id", "")),
                    category=str(r.get("category", "")),
                    severity=str(r.get("severity", "")),
                    title=str(r.get("title", "")),
                    detail=str(r.get("detail", "")),
                    affected_objects=list(r.get("affected_objects", [])),
                    status=str(r.get("status", "open")),
                    run_refs=list(r.get("run_refs", [])),
                    fix_prompt=str(r.get("fix_prompt", "")),
                    dismissed_reason=str(r.get("dismissed_reason", "")),
                    created_at=str(r.get("created_at", "")),
                    updated_at=str(r.get("updated_at", "")),
                )
            )
        return recs
    except Exception:
        return []


def save_recommendations(reports_dir: Path, recs: list[Recommendation]) -> Path:
    """Persist *recs* to ``<reports_dir>/recommendations.json``.

    Overwrites any existing file.  Creates *reports_dir* if it does not
    exist.

    Parameters
    ----------
    reports_dir:
        Target directory.
    recs:
        Recommendations to persist.

    Returns
    -------
    Path
        Absolute path to the written file.
    """
    reports_dir.mkdir(parents=True, exist_ok=True)
    rec_json = reports_dir / "recommendations.json"
    data: dict[str, Any] = {
        "recommendations": [asdict(r) for r in recs],
    }
    rec_json.write_text(
        json.dumps(data, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return rec_json


def count_open_recommendations(reports_dir: Path) -> int:
    """Count recommendations with ``status == "open"`` in the persisted JSON.

    Returns 0 when the file does not exist or cannot be parsed.

    Parameters
    ----------
    reports_dir:
        Directory containing ``recommendations.json``.
    """
    recs = load_recommendations(reports_dir)
    return sum(1 for r in recs if r.status == "open")


def count_fixed_recommendations(reports_dir: Path) -> int:
    """Count recommendations with ``status == "fixed"`` in the persisted JSON.

    Returns 0 when the file does not exist or cannot be parsed.

    Parameters
    ----------
    reports_dir:
        Directory containing ``recommendations.json``.
    """
    recs = load_recommendations(reports_dir)
    return sum(1 for r in recs if r.status == "fixed")
