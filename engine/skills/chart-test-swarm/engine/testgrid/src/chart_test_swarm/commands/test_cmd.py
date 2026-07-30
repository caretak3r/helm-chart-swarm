"""``chart-test-swarm test`` subcommand — agentic full-matrix test loop.

Orchestrates the complete test lifecycle end-to-end, reusing existing
components: scenario discovery from ``run_cmd``, fix workflow from
``fix_cmd``, recommendation generation from ``testgrid.recommendations``,
and dashboard rebuild from ``engine/scripts/build-dashboard.sh``.

Loop (observable behavior):
  1. Run verify.sh; if non-zero, abort with non-zero exit (no cluster-up).
  2. Run cluster-up.sh with validated CLUSTER_NAME.
  3. Discover scenarios for --suite or all.
  4. Per scenario in catalog order:
     a. Run via run-scenario.sh against the shared cluster.
     b. PASS → record, continue.
     c. FAIL (unless --no-fix) → bounded fix sub-loop using recommendations
        + fix_cmd via CTS_LLM_CMD, up to --max-fix-attempts.
     d. A failing scenario NEVER aborts the matrix.
  5. Rebuild dashboard every --rebuild-interval scenarios + once at the end.
  6. Print summary.
  7. Cluster-down.sh in a finally block unless --keep-cluster.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Any, NoReturn

# ── Reused helpers (do not reimplement) ─────────────────────────────────────
from chart_test_swarm.commands.fix_cmd import (
    append_history_entry,
    apply_llm_suggestion,
    call_llm,
    update_recommendation_status,
    write_fix_prompt_file,
)
from chart_test_swarm.commands.run_cmd import (
    _find_all_scenarios,
    _resolve_engine_script,
    _resolve_project_dir,
    _validate_cluster_name,
)

# ── Error helpers ───────────────────────────────────────────────────────────


def _die(msg: str, code: int = 1) -> NoReturn:
    """Print *msg* to stderr and exit with *code*."""
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def _debug(msg: str) -> None:
    """Print a debug trace line to stderr when ``CTS_DEBUG`` is set."""
    if os.environ.get("CTS_DEBUG", "").strip() in ("1", "true", "yes"):
        print(f"[cts debug] {msg}", file=sys.stderr)


# ── Script invocation helpers ────────────────────────────────────────────────


def _run_script(
    script_name: str,
    *,
    env: dict[str, str] | None = None,
    exit_on_fail: bool = True,
) -> int:
    """Run an engine script, returning its exit code.

    If *exit_on_fail* is True, raises SystemExit on non-zero exit.
    """
    script = _resolve_engine_script(script_name)
    _debug(f"Running: {script}")

    resolved_env = os.environ.copy()
    if env:
        resolved_env.update(env)

    result = subprocess.run(
        ["bash", str(script)],
        env=resolved_env,
        capture_output=True,
        text=True,
    )

    if result.stdout:
        sys.stdout.write(result.stdout)
        sys.stdout.flush()
    if result.stderr:
        sys.stderr.write(result.stderr)
        sys.stderr.flush()

    if exit_on_fail and result.returncode != 0:
        _die(f"{script_name} exited with code {result.returncode}", code=result.returncode)

    return result.returncode


def _run_dispatch_scenario(
    scenario_path: Path,
    *,
    cluster_name: str,
    project_dir: Path,
    reports_dir: Path,
    parallelism: int = 1,
) -> int:
    """Execute one scenario via run-scenario.sh on the shared cluster.

    Returns 0 for non-failing outcomes (PASS/SKIP) and non-zero for FAIL.
    The ``parallelism`` parameter is retained for signature stability.
    """
    script = _resolve_engine_script("run-scenario.sh")

    env = os.environ.copy()
    env["CLUSTER_NAME"] = cluster_name
    env["PROJECT_DIR"] = str(project_dir)
    env["REPORTS_DIR"] = str(reports_dir)
    env["PROVIDER"] = "kind"
    env["KEEP_CLUSTER"] = "1"
    env["KEEP_ON_FAILURE"] = "1"

    _debug(f"Running scenario: {scenario_path}")
    _debug(f"parallelism={parallelism} ignored for single scenario execution")

    cmd = [
        "bash",
        str(script),
        str(scenario_path),
    ]

    result = subprocess.run(
        cmd,
        env=env,
        capture_output=True,
        text=True,
    )

    if result.stdout:
        sys.stdout.write(result.stdout)
        sys.stdout.flush()
    if result.stderr:
        sys.stderr.write(result.stderr)
        sys.stderr.flush()

    return result.returncode


def _rebuild_dashboard(reports_dir: Path, project_dir: Path) -> None:
    """Rebuild the dashboard via build-dashboard.sh."""
    script = _resolve_engine_script("build-dashboard.sh")
    _debug(f"Rebuilding dashboard: {script}")

    env = os.environ.copy()
    env["REPORTS_DIR"] = str(reports_dir)
    env["PROJECT_DIR"] = str(project_dir)
    env["DASHBOARD_OUT"] = str(reports_dir / "dist")

    try:
        result = subprocess.run(
            ["bash", str(script)],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.stdout:
            sys.stdout.write(result.stdout)
            sys.stdout.flush()
        if result.returncode != 0:
            _debug(f"Dashboard rebuild exited with code {result.returncode}; continuing")
    except Exception as exc:
        _debug(f"Dashboard rebuild failed: {exc}; continuing")


# ── Helper utilities ─────────────────────────────────────────────────────────


def _resolve_reports_dir(explicit: str | None) -> Path:
    """Resolve the reports directory.

    Precedence: *explicit* > ``REPORTS_DIR`` env > ``<repo_root>/reports``.
    """
    if explicit:
        return Path(explicit).resolve()

    env_reports = os.environ.get("REPORTS_DIR")
    if env_reports:
        return Path(env_reports).resolve()

    # Default: repo root / reports
    this_file = Path(__file__).resolve()
    # commands → chart_test_swarm → src → testgrid → engine → root
    testgrid_dir = this_file.parents[3]
    root_dir = testgrid_dir.parents[1]
    return root_dir / "reports"


# ── Recommendation generation (reuses testgrid.recommendations) ──────────────


def _generate_fix_prompt_text(scenario_id: str) -> str:
    """Generate a fix prompt text for a scenario failure."""
    return (
        f"# Fix Recommendation: {scenario_id}\n\n"
        f"**Scenario:** `{scenario_id}`\n"
        f"**Category:** chart-fix\n\n"
        f"## Suggested Fix\n\n"
        f"Modify the chart templates to resolve the failure in scenario `{scenario_id}`.\n"
        f"Only modify files under the chart directory.\n"
    )


# ── Test loop entry point ────────────────────────────────────────────────────


def run_test_loop(  # noqa: PLR0913, PLR0915
    *,
    suite: str | None = None,
    max_fix_attempts: int = 2,
    no_fix: bool = False,
    rebuild_interval: int = 5,
    parallelism: int = 1,
    cluster_name: str = "chart-test-swarm-default",
    backend: str = "kind",
    keep_cluster: bool = False,
    project_dir: str | None = None,
    reports_dir: str | None = None,
) -> None:
    """Run the full agentic test matrix loop.

    Orchestrates verify → cluster up → discover → per-scenario run
    (with bounded fix loop) → progressive dashboard rebuild → summary
    → cluster teardown.
    """
    # ── 1. Resolve dirs ──────────────────────────────────────────────────
    resolved_project = _resolve_project_dir(project_dir)
    resolved_reports = _resolve_reports_dir(reports_dir)
    resolved_reports.mkdir(parents=True, exist_ok=True)

    # ── 2. Validate cluster name (before any subprocess) ─────────────────
    _validate_cluster_name(cluster_name)

    _debug(f"Project dir: {resolved_project}")
    _debug(f"Reports dir: {resolved_reports}")
    _debug(f"Cluster name: {cluster_name}")
    _debug(f"Backend: {backend}")
    _debug(f"Max fix attempts: {max_fix_attempts}")
    _debug(f"No-fix mode: {no_fix}")
    _debug(f"Rebuild interval: {rebuild_interval}")

    # ── 3. Verify preflight (abort on failure, no cluster) ───────────────
    print("━━━ Verifying prerequisites...")
    verify_rc = _run_script(
        "verify.sh",
        env={"REPORTS_DIR": str(resolved_reports), "PROJECT_DIR": str(resolved_project)},
        exit_on_fail=False,
    )
    if verify_rc != 0:
        _die(
            f"verify.sh exited with code {verify_rc}.\nFix the issues above and re-run.",
            code=verify_rc,
        )

    # ── 4. Discover scenarios ────────────────────────────────────────────
    print("━━━ Discovering scenarios...")
    if suite is not None:
        # Suite mode: find scenarios by suite tag. First, find all, then
        # filter by tag via _find_all_scenarios (dispatch-swarm.sh handles
        # tag filtering). We pass --suite flag via env.
        scenarios = _find_all_scenarios(resolved_project)
        # Filter by suite tag if scenarios have tags defined
        scenarios = _filter_by_suite_tag(scenarios, resolved_project, suite)
    else:
        scenarios = _find_all_scenarios(resolved_project)

    if not scenarios:
        _die("No scenarios discovered. Check --suite filter and project directory.", code=1)

    print(f"Discovered {len(scenarios)} scenario(s):")
    for s in scenarios:
        print(f"  • {s.relative_to(resolved_project)}")

    # ── Stats tracking ───────────────────────────────────────────────────
    total = len(scenarios)
    passed = 0
    failed = 0
    fixed = 0
    open_count = 0
    scenario_index = 0

    # ── 5. Cluster up ────────────────────────────────────────────────────
    print("\n━━━ Bringing up cluster...")
    _run_script(
        "cluster-up.sh",
        env={
            "CLUSTER_NAME": cluster_name,
            "PROVIDER": backend,
            "PROJECT_DIR": str(resolved_project),
            "REPORTS_DIR": str(resolved_reports),
        },
    )

    # ── 6. Per-scenario loop (in try/finally for teardown) ───────────────
    cluster_up = True  # cluster-up.sh succeeded
    try:
        for scenario in scenarios:
            scenario_index += 1
            scenario_name = scenario.stem
            print(f"\n━━━ [{scenario_index}/{total}] Running: {scenario_name}")

            # Run the scenario
            rc = _run_dispatch_scenario(
                scenario,
                cluster_name=cluster_name,
                project_dir=resolved_project,
                reports_dir=resolved_reports,
                parallelism=parallelism,
            )

            if rc == 0:
                # PASS
                passed += 1
                print("  ✓ PASS")
            else:
                # FAIL
                failed += 1
                scenario_fixed = False

                if no_fix:
                    print("  ✗ FAIL (--no-fix: skipping fix attempts)")
                else:
                    print(f"  ✗ FAIL — entering fix sub-loop (max {max_fix_attempts} attempts)")

                    # Prepare fix prompt
                    rec_id = f"rec-{scenario_name}"
                    write_fix_prompt_file(
                        reports_dir=resolved_reports,
                        rec_id=rec_id,
                        rec_data={"fix_prompt": _generate_fix_prompt_text(scenario_name)},
                        scenario_path=scenario_name,
                        chart_path="chart",
                    )

                    chart_dir = resolved_project / "chart"

                    for attempt in range(1, max_fix_attempts + 1):
                        print(f"    Fix attempt {attempt}/{max_fix_attempts}...")

                        # Generate fix prompt and invoke LLM
                        fix_prompt = _generate_fix_prompt_text(scenario_name)

                        try:
                            llm_output = call_llm(fix_prompt, timeout=120)
                        except SystemExit:
                            # LLM call failed — skip remaining attempts
                            print(
                                f"    LLM invocation failed; "
                                f"aborting fix attempts for {scenario_name}"
                            )
                            break

                        # Apply suggestion
                        try:
                            diff = apply_llm_suggestion(chart_dir, llm_output)
                        except ValueError as exc:
                            print(f"    ⚠ Chart edit rejected: {exc}")
                            diff = ""

                        # Re-run scenario
                        print(f"    Re-running {scenario_name}...")
                        rerun_rc = _run_dispatch_scenario(
                            scenario,
                            cluster_name=cluster_name,
                            project_dir=resolved_project,
                            reports_dir=resolved_reports,
                            parallelism=parallelism,
                        )

                        rerun_status = "PASS" if rerun_rc == 0 else "FAIL"
                        result_str = "fixed" if rerun_status == "PASS" else "open"

                        # Record history
                        try:
                            append_history_entry(
                                reports_dir=resolved_reports,
                                rec_id=rec_id,
                                prompt_used=fix_prompt,
                                diff=diff,
                                re_run_status=rerun_status,
                                result=result_str,
                            )
                        except Exception as exc:
                            _debug(f"Failed to append history entry: {exc}")

                        if rerun_rc == 0:
                            print("    ✓ Re-run PASS — recommendation fixed!")
                            scenario_fixed = True
                            fixed += 1
                            failed -= 1  # WAS a failure, now fixed
                            # Update recommendation status
                            update_recommendation_status(resolved_reports, rec_id, "PASS")
                            break
                        else:
                            print("    ✗ Re-run still FAIL")
                            update_recommendation_status(resolved_reports, rec_id, "FAIL")

                    if not scenario_fixed and not no_fix:
                        open_count += 1
                        print(f"    Recommendation remains OPEN after {max_fix_attempts} attempts")

            # ── Progressive dashboard rebuild ────────────────────────────
            if rebuild_interval > 0 and scenario_index % rebuild_interval == 0:
                print(f"\n━━━ Rebuilding dashboard (scenario {scenario_index}/{total})...")
                _rebuild_dashboard(resolved_reports, resolved_project)

    finally:
        # ── 7. Cluster teardown (finally unless --keep-cluster) ──────────
        if cluster_up and not keep_cluster:
            print("\n━━━ Tearing down cluster...")
            try:
                _run_script(
                    "cluster-down.sh",
                    env={
                        "CLUSTER_NAME": cluster_name,
                        "PROVIDER": backend,
                        "PROJECT_DIR": str(resolved_project),
                        "REPORTS_DIR": str(resolved_reports),
                    },
                    exit_on_fail=False,
                )
            except Exception as exc:
                _debug(f"Cluster down failed (continuing): {exc}")
        elif keep_cluster:
            print(f"\n  (--keep-cluster: cluster {cluster_name} left running)")

    # ── 8. Final dashboard rebuild ───────────────────────────────────────
    print("\n━━━ Final dashboard rebuild...")
    _rebuild_dashboard(resolved_reports, resolved_project)

    # ── 9. Print summary ─────────────────────────────────────────────────
    dashboard_path = resolved_reports / "dist" / "home.html"
    print("\n" + "=" * 60)
    print("  TEST MATRIX COMPLETE")
    print("=" * 60)
    print(f"  Total scenarios:    {total}")
    print(f"  PASS:               {passed}")
    print(f"  FAIL:               {failed}")
    print(f"  Fixed:              {fixed}")
    print(f"  Open:               {open_count}")
    print(f"  Dashboard:          {dashboard_path}")
    print("=" * 60)


def _filter_by_suite_tag(
    scenarios: list[Path],
    project_dir: Path,
    suite: str,
) -> list[Path]:
    """Filter scenarios by the suite's ``tag_filter``, as declared in
    ``chart-test-swarm.yaml``. Mirrors ``dispatch-swarm.sh``'s tag-based
    filtering (engine/scripts/dispatch-swarm.sh:166-194): a scenario matches
    if any of its tags intersect the suite's ``tag_filter`` array — the suite
    name itself is a lookup key into that config, never a tag.

    A scenario that fails to parse is excluded (with a warning), not
    included — a broken scenario file must never silently join a run.
    """
    if not suite:
        return scenarios

    import yaml as _yaml_lib

    config_path = project_dir / "chart-test-swarm.yaml"
    cfg: dict[str, Any] = {}
    if config_path.exists():
        with open(config_path, encoding="utf-8") as fh:
            cfg = _yaml_lib.safe_load(fh) or {}
    suites = cfg.get("suites") or {}
    suite_cfg = suites.get(suite) or {}
    tag_filter = suite_cfg.get("tag_filter") or []

    if not tag_filter:
        _die(
            f"ERROR: suite '{suite}' not defined or has empty tag_filter in {config_path}",
            code=1,
        )

    filtered: list[Path] = []
    for scn_path in scenarios:
        try:
            with open(scn_path, encoding="utf-8") as f:
                doc = _yaml_lib.safe_load(f)
        except Exception as exc:
            print(f"  ⚠ Skipping unparsable scenario {scn_path}: {exc}", file=sys.stderr)
            continue
        if not isinstance(doc, dict):
            print(f"  ⚠ Skipping unparsable scenario {scn_path}: not a mapping", file=sys.stderr)
            continue
        tags = doc.get("tags", [])
        if isinstance(tags, list) and set(tags) & set(tag_filter):
            filtered.append(scn_path)
    return filtered
