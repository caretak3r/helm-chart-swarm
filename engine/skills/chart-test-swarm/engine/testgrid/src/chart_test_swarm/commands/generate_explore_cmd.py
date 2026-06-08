"""``chart-test-swarm generate explore`` subcommand — iterative LLM-driven exploration.

Shells out to ``CTS_LLM_CMD`` to propose scenario combos, validates each
against the schema and cluster-name prefix, runs validated combos via
``chart-test-swarm run``, feeds results back to the LLM, and emits an
incremental summary report. Bounded by ``--max-iterations`` and ``--budget``.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from shutil import which
from typing import NoReturn

import yaml

# ── constants ───────────────────────────────────────────────────────────────

_CLUSTER_NAME_PATTERN: str = r"^chart-test-swarm-[a-z0-9-]+$"
_CLUSTER_NAME_RE = re.compile(_CLUSTER_NAME_PATTERN)

# Fields in the scenario YAML that might reference a cluster name.
# We scan these for prefix violations.
_CLUSTER_NAME_FIELDS: tuple[str, ...] = (
    "cluster_name",
    "clusterName",
    "cluster.name",
    "cluster_config_name",
    "name",  # only inside cluster.config context
)

# LLM cost regex: matches "LLM_STUB_COST: N.NN" on a line
_COST_RE = re.compile(r"LLM_STUB_COST:\s*([\d.]+)")

# ── error helpers ──────────────────────────────────────────────────────────


def _die(msg: str, code: int = 1) -> NoReturn:
    """Print *msg* to stderr and exit with *code*."""
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def _debug(msg: str) -> None:
    """Print a debug trace line to stderr when ``CTS_DEBUG`` is set."""
    if os.environ.get("CTS_DEBUG", "").strip() in ("1", "true", "yes"):
        print(f"[cts debug] {msg}", file=sys.stderr)


# ── path resolution ───────────────────────────────────────────────────────


def _resolve_repo_root() -> Path:
    """Return the absolute path to the repository root."""
    this_file = Path(__file__).resolve()
    # this_file: .../src/chart_test_swarm/commands/generate_explore_cmd.py
    #   → commands → chart_test_swarm → src → testgrid → engine → repo root
    engine_dir = this_file.parents[3]
    return engine_dir.parents[1]  # engine → root


def _resolve_schema_path() -> Path:
    """Return the absolute path to the scenario schema JSON file."""
    env_override = os.environ.get("CTS_SCHEMA_PATH")
    if env_override:
        return Path(env_override).resolve()
    return _resolve_repo_root() / "engine" / "templates" / "scenario.schema.json"


# ── LLM command resolution ────────────────────────────────────────────────


def _resolve_llm_cmd() -> list[str]:
    """Resolve the LLM command to invoke.

    1. ``CTS_LLM_CMD`` env var (split on whitespace).
    2. Auto-discover ``droid`` on PATH via ``shutil.which``.

    Returns a list suitable for ``subprocess.run``.

    Raises ``SystemExit`` if no LLM binary is reachable.
    """
    cts_llm_cmd = os.environ.get("CTS_LLM_CMD", "").strip()
    if cts_llm_cmd:
        _debug(f"CTS_LLM_CMD resolved from env: {cts_llm_cmd}")
        return cts_llm_cmd.split()

    droid_path = which("droid")
    if droid_path:
        _debug(f"Auto-discovered droid at: {droid_path}")
        return [droid_path, "generate", "scenario"]

    path_dirs = os.environ.get("PATH", "").split(os.pathsep)
    _die(
        "ERROR: No LLM binary found.\n\n"
        "  • CTS_LLM_CMD environment variable is not set.\n"
        "  • Searched PATH for: droid\n"
        f"  • PATH directories checked: {', '.join(path_dirs)}\n\n"
        "To fix this, set CTS_LLM_CMD to point at your droid/agent CLI:\n\n"
        '    export CTS_LLM_CMD="droid generate scenario"\n\n'
        "Or install the droid CLI from https://docs.factory.ai/cli",
        code=10,
    )


# ── run command resolution ────────────────────────────────────────────────


def _resolve_run_cmd() -> list[str]:
    """Resolve the run command for dispatching scenarios.

    1. ``CTS_RUN_CMD`` env var (split on whitespace).
    2. Default: ``chart-test-swarm run``.
    """
    cts_run_cmd = os.environ.get("CTS_RUN_CMD", "").strip()
    if cts_run_cmd:
        return cts_run_cmd.split()
    return ["chart-test-swarm", "run"]


# ── LLM invocation ────────────────────────────────────────────────────────


def _call_llm(
    llm_cmd: list[str],
    prompt: str,
    timeout: int = 120,
) -> subprocess.CompletedProcess[str]:
    """Invoke *llm_cmd* with *prompt* on stdin; return ``CompletedProcess``.

    Does NOT die on failure — the caller handles exit code + stderr.
    """
    _debug(f"Calling LLM: {' '.join(llm_cmd)}")
    try:
        result = subprocess.run(
            llm_cmd,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        _debug(f"LLM exit code: {result.returncode}")
        if result.stderr:
            _debug(f"LLM stderr (first 500): {result.stderr[:500]}")
    except subprocess.TimeoutExpired:
        # Return a synthetic result indicating timeout
        return subprocess.CompletedProcess(
            llm_cmd, returncode=-1, stdout="", stderr="LLM command timed out"
        )
    except FileNotFoundError as exc:
        return subprocess.CompletedProcess(
            llm_cmd, returncode=-2, stdout="", stderr=f"LLM command not found: {exc}"
        )
    return result


def _extract_cost(llm_stderr: str) -> float:
    """Extract cost from LLM stderr (e.g., 'LLM_STUB_COST: 0.50')."""
    match = _COST_RE.search(llm_stderr)
    if match:
        return float(match.group(1))
    return 0.0


# ── YAML parsing ──────────────────────────────────────────────────────────


def _try_parse_yaml(raw: str) -> tuple[dict[str, object] | None, str | None]:
    """Try to parse *raw* as YAML.

    Returns ``(data, None)`` on success or ``(None, error_message)`` on failure.
    """
    try:
        data = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        return None, f"LLM output is invalid YAML: {exc}"
    if not isinstance(data, dict):
        return None, f"LLM output is not a YAML mapping (got {type(data).__name__})."
    return data, None


# ── generated_by provenance ──────────────────────────────────────────────


def _add_generated_by(
    data: dict[str, object],
    llm_cmd_str: str,
    by_mode: str = "explore",
) -> dict[str, object]:
    """Add ``generated_by`` provenance to the scenario data.

    Returns a new dict (does not mutate *data* in place).
    """
    result = dict(data)
    result["generated_by"] = {
        "by": by_mode,
        "skill_version": llm_cmd_str,
        "at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    return result


# ── schema validation ────────────────────────────────────────────────────


def _validate_against_schema(yaml_text: str) -> tuple[bool, str]:
    """Validate *yaml_text* against the scenario schema.

    Uses ``check-jsonschema`` CLI (YAML-aware).

    Returns ``(is_valid, error_message)``.
    """
    schema = _resolve_schema_path()
    if not schema.exists():
        return True, ""

    with tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".yaml",
        prefix="explore-validate-",
        delete=False,
    ) as f:
        f.write(yaml_text)
        tmp_path = f.name

    try:
        result = subprocess.run(
            [
                "check-jsonschema",
                "--schemafile",
                str(schema),
                tmp_path,
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0:
            return True, ""
        error_msg = result.stderr.strip() if result.stderr else result.stdout.strip()
        return False, error_msg
    except FileNotFoundError:
        _debug("check-jsonschema not found; skipping schema validation")
        return True, ""
    finally:
        Path(tmp_path).unlink(missing_ok=True)


# ── prefix validation ─────────────────────────────────────────────────────


def _check_prefix_violation(data: dict[str, object]) -> tuple[bool, str | None]:
    """Check if the scenario data contains a cluster-name-like field
    that violates the ``chart-test-swarm-`` prefix requirement.

    Returns ``(is_safe, violation_field)`` — ``True`` means no violation,
    ``False`` means a violation was found with the offending value.
    """
    # Check cluster.config.cluster_name and similar paths
    cluster = data.get("cluster")
    if isinstance(cluster, dict):
        config = cluster.get("config")
        if isinstance(config, dict):
            for field in ("cluster_name", "clusterName", "name"):
                val = config.get(field)
                if isinstance(val, str) and val.strip() and not _CLUSTER_NAME_RE.match(val):
                    return False, f"cluster.config.{field}: '{val}'"

    # Check top-level cluster_name
    for field in ("cluster_name", "clusterName"):
        val = data.get(field)
        if isinstance(val, str) and val.strip() and not _CLUSTER_NAME_RE.match(val):
            return False, f"{field}: '{val}'"

    return True, None


# ── scenario YAML dump ────────────────────────────────────────────────────


def _dump_yaml(data: dict[str, object]) -> str:
    """Serialize *data* as a YAML string."""
    return yaml.dump(
        data,
        default_flow_style=False,
        sort_keys=False,
        allow_unicode=True,
    )


# ── run dispatch ─────────────────────────────────────────────────────────


def _dispatch_run(
    run_cmd: list[str],
    scenario_path: str,
    timeout: int = 600,
) -> subprocess.CompletedProcess[str]:
    """Run a scenario via *run_cmd* (e.g., ``chart-test-swarm run --scenario <path>``).

    Returns the ``CompletedProcess``.
    """
    cmd = run_cmd + ["--scenario", scenario_path]
    _debug(f"Dispatching run: {' '.join(cmd)}")
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        _debug(f"Run exit code: {result.returncode}")
        return result
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(
            cmd, returncode=-1, stdout="", stderr="Run command timed out"
        )
    except FileNotFoundError as exc:
        return subprocess.CompletedProcess(
            cmd, returncode=-2, stdout="", stderr=f"Run command not found: {exc}"
        )


# ── result.yaml parsing ──────────────────────────────────────────────────


def _parse_run_result(run_stdout: str) -> dict[str, object]:
    """Parse the result.yaml from the run output.

    The last line of stdout should be the RUN_ID, and the corresponding
    ``reports/<run_id>/result.yaml`` should exist.

    Falls back to parsing the stdout itself if no reports dir is found.
    """
    # Try to extract the RUN_ID from stdout (last non-empty line)
    lines = [line.strip() for line in run_stdout.split("\n") if line.strip()]
    run_id = lines[-1] if lines else None

    if run_id and run_id.startswith("run-"):
        result_path = Path("reports") / run_id / "result.yaml"
        if result_path.exists():
            try:
                return yaml.safe_load(result_path.read_text()) or {}
            except yaml.YAMLError:
                pass

    return {}


def _format_result_summary(result: dict[str, object]) -> str:
    """Format the result.yaml as a brief summary string for the LLM prompt."""
    if not result:
        return "(no result available)"

    status = result.get("status", "UNKNOWN")
    scenarios = result.get("scenarios", [])
    if not isinstance(scenarios, list):
        scenarios = []

    summary_lines = [f"Run status: {status}"]
    for scn in scenarios:
        if isinstance(scn, dict):
            sid = scn.get("id", "unknown")
            sstatus = scn.get("status", "UNKNOWN")
            npass = scn.get("assertions_pass", 0)
            nfail = scn.get("assertions_fail", 0)
            summary_lines.append(f"  Scenario {sid}: {sstatus} ({npass} PASS / {nfail} FAIL)")
    return "\n".join(summary_lines)


# ── summary I/O ──────────────────────────────────────────────────────────


def _write_summary(summary_records: list[dict[str, object]], output: Path) -> None:
    """Write the summary records as JSON to *output*."""
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary_records, indent=2, default=str) + "\n")


# ── output emission ──────────────────────────────────────────────────────


def _check_output_overwrite(output: str | None, force: bool) -> None:
    """Check that *output* can be written to.

    Raises ``SystemExit`` if the file exists, is non-empty, and *force* is ``False``.
    """
    if not output:
        return
    out_path = Path(output).resolve()
    if out_path.exists() and out_path.stat().st_size > 0 and not force:
        _die(
            f"ERROR: {out_path} already exists.\n  Use --force to overwrite.",
            code=16,
        )


# ── main entry point ─────────────────────────────────────────────────────


def generate_explore(  # noqa: PLR0913, PLR0912, PLR0915
    *,
    chart: str,
    integrations: str,  # comma-separated
    max_iterations: int = 3,
    budget: float | None = None,
    output: str | None = None,
    force: bool = False,  # noqa: FBT001, FBT002
    timeout: int = 120,
    run_timeout: int = 600,
) -> None:
    """Iteratively explore scenario combinations via LLM + run.

    Core flow:
      1. Resolve ``CTS_LLM_CMD`` and the run command.
      2. Validate *output* file does not exist (unless --force).
      3. For each iteration up to *max_iterations*:
         a. Build prompt (with prior results on N>1).
         b. Invoke LLM to propose a scenario YAML.
         c. Parse + validate schema + check prefix.
         d. If invalid: record rejection, decrement budget, continue.
         e. If valid: write temp scenario, dispatch run, capture result.
         f. Feed result summary to next LLM prompt.
         g. Check budget: halt if exhausted.
         h. Write summary incrementally.
      4. Exit with 0 on success, non-zero on error.
    """
    # ── 1. Resolve commands ──────────────────────────────────────────────
    llm_cmd = _resolve_llm_cmd()
    llm_cmd_str = " ".join(llm_cmd)
    run_cmd = _resolve_run_cmd()

    # Resolve chart path
    chart_path = Path(chart).resolve()
    if not chart_path.exists():
        _die(f"ERROR: chart path does not exist: {chart_path}", code=20)

    # Parse integrations
    integration_list = [x.strip() for x in integrations.split(",") if x.strip()]
    if not integration_list:
        _die("ERROR: at least one integration must be specified.", code=21)

    # ── 2. Validate output overwrite ─────────────────────────────────────
    _check_output_overwrite(output, force)
    output_path = Path(output).resolve() if output else None

    _debug(f"Chart: {chart_path}")
    _debug(f"Integrations: {integration_list}")
    _debug(f"Max iterations: {max_iterations}")
    _debug(f"Budget: {budget}")

    # ── 3. Exploration loop ──────────────────────────────────────────────
    summary_records: list[dict[str, object]] = []
    total_cost: float = 0.0
    prior_result_summary: str = ""
    terminated_reason: str = "max_iterations_reached"

    for iteration in range(1, max_iterations + 1):
        _debug(f"Iteration {iteration}/{max_iterations}")

        # ── 3a. Build prompt ─────────────────────────────────────────────
        prompt = _build_prompt(
            chart=str(chart_path),
            integrations=integration_list,
            iteration=iteration,
            prior_result=prior_result_summary,
        )

        # ── 3b. Invoke LLM ───────────────────────────────────────────────
        llm_result = _call_llm(llm_cmd, prompt, timeout=timeout)

        # Extract cost from LLM stderr
        iteration_cost = _extract_cost(llm_result.stderr)
        total_cost += iteration_cost

        # Check for LLM crash / non-zero exit
        if llm_result.returncode == 137:
            # LLM crashed — write partial summary and exit
            _debug(f"LLM crashed with exit 137 on iteration {iteration}")
            if output_path:
                _write_summary(summary_records, output_path)
            _die(
                f"ERROR: LLM crashed (exit 137) on iteration {iteration}.",
                code=22,
            )
        if llm_result.returncode not in (0,):
            # LLM failed for another reason
            error_msg = llm_result.stderr.strip() or f"exit code {llm_result.returncode}"
            record: dict[str, object] = {
                "iteration": iteration,
                "status": "LLM_ERROR",
                "error": error_msg,
                "integrations": integration_list,
            }
            summary_records.append(record)
            if output_path:
                _write_summary(summary_records, output_path)
            _debug(f"LLM failed on iteration {iteration}: {error_msg}")
            print(
                f"LLM error on iteration {iteration}: {error_msg}",
                file=sys.stderr,
            )
            continue

        raw_output = llm_result.stdout

        # ── 3c. Parse + validate + prefix check ──────────────────────────
        data, yaml_error = _try_parse_yaml(raw_output)
        if data is None:
            # Unparseable YAML — reject iteration
            assert yaml_error is not None
            record = {
                "iteration": iteration,
                "status": "REJECTED",
                "error": f"YAML parse error: {yaml_error}",
                "integrations": integration_list,
            }
            summary_records.append(record)
            if output_path:
                _write_summary(summary_records, output_path)
            print(
                f"Iteration {iteration}: REJECTED — {yaml_error[:120]}",
                file=sys.stderr,
            )
            continue

        # Add provenance
        data = _add_generated_by(data, llm_cmd_str, by_mode="explore")
        scenario_yaml = _dump_yaml(data)

        # Check prefix violation BEFORE schema validation
        is_prefix_safe, prefix_violation = _check_prefix_violation(data)
        if not is_prefix_safe:
            record = {
                "iteration": iteration,
                "scenario_yaml": scenario_yaml,
                "status": "REJECTED",
                "error": f"cluster name prefix violation: {prefix_violation}",
                "integrations": integration_list,
            }
            summary_records.append(record)
            if output_path:
                _write_summary(summary_records, output_path)
            print(
                f"Iteration {iteration}: REJECTED — {prefix_violation}",
                file=sys.stderr,
            )
            continue

        # Check schema validation
        is_schema_valid, schema_error = _validate_against_schema(scenario_yaml)
        if not is_schema_valid:
            record = {
                "iteration": iteration,
                "scenario_yaml": scenario_yaml,
                "status": "REJECTED",
                "error": f"schema validation: {schema_error[:300]}",
                "integrations": integration_list,
            }
            summary_records.append(record)
            if output_path:
                _write_summary(summary_records, output_path)
            print(
                f"Iteration {iteration}: REJECTED — schema validation failed",
                file=sys.stderr,
            )
            continue

        _debug(f"Iteration {iteration}: scenario validated OK")

        # ── 3d. Write temp scenario file ─────────────────────────────────
        with tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".yaml",
            prefix=f"explore-iter{iteration}-",
            delete=False,
        ) as f:
            f.write(scenario_yaml)
            tmp_scenario = f.name

        # ── 3e. Dispatch run ─────────────────────────────────────────────
        try:
            run_result = _dispatch_run(run_cmd, tmp_scenario, timeout=run_timeout)
            run_id: str | None = None
            run_status: str = "ERROR"

            if run_result.returncode == 0:
                # Extract run_id from stdout
                stdout_lines = [
                    line.strip() for line in run_result.stdout.split("\n") if line.strip()
                ]
                run_id = stdout_lines[-1] if stdout_lines else None
                if run_id and run_id.startswith("run-"):
                    run_status = "RUN_DISPATCHED"  # will be updated from result
                    # Try to read the actual result
                    result_data = _parse_run_result(run_result.stdout)
                    if result_data:
                        s_status = result_data.get("status")
                        if isinstance(s_status, str):
                            run_status = s_status
                        prior_result_summary = _format_result_summary(result_data)
                    else:
                        prior_result_summary = (
                            f"Run dispatched as {run_id} but result.yaml not found"
                        )
                else:
                    run_status = "PASS"  # stub mode
                    prior_result_summary = f"Run completed: {run_result.stdout[:200]}"
            else:
                run_status = "RUN_FAILED"
                prior_result_summary = (
                    f"Run failed (exit {run_result.returncode}): {run_result.stderr[:200]}"
                )

            scenario_id = str(data.get("id", f"explore-iter{iteration}"))

            record = {
                "iteration": iteration,
                "scenario_id": scenario_id,
                "scenario_yaml": scenario_yaml,
                "run_id": run_id or "",
                "status": run_status,
                "integrations": integration_list,
            }
            summary_records.append(record)
            if output_path:
                _write_summary(summary_records, output_path)

            status_icon = "✓" if run_status in ("PASS", "RUN_DISPATCHED") else "✗"
            print(
                f"Iteration {iteration}: {status_icon} {run_status} (run_id={run_id or 'N/A'})",
                file=sys.stderr,
            )

        finally:
            # Clean up temp scenario file
            Path(tmp_scenario).unlink(missing_ok=True)

        # ── 3g. Check budget ─────────────────────────────────────────────
        if budget is not None and total_cost >= budget:
            terminated_reason = "budget_exhausted"
            print(
                f"Budget exhausted: ${total_cost:.2f} >= ${budget:.2f}",
                file=sys.stderr,
            )
            break

    # ── 4. Final summary ─────────────────────────────────────────────────
    if output_path:
        _write_summary(summary_records, output_path)
        count = len(summary_records)
        print(
            f"Exploration complete: {count} iteration(s) recorded to {output_path} "
            f"(terminated: {terminated_reason}, total_cost: ${total_cost:.2f})",
        )
    else:
        # Emit JSON summary to stdout
        print(json.dumps(summary_records, indent=2, default=str))


# ── prompt builder ────────────────────────────────────────────────────────


def _build_prompt(
    chart: str,
    integrations: list[str],
    iteration: int,
    prior_result: str = "",
) -> str:
    """Build the prompt for the LLM invocation.

    On iteration 1, no prior result is included.
    On iteration N>1, includes the prior result summary.
    """
    lines = [
        "You are a chart-test-swarm scenario generator in EXPLORE mode.",
        "",
        f"Chart path: {chart}",
        f"Available integrations: {', '.join(integrations)}",
        f"Current iteration: {iteration}",
        "",
        "Propose a novel scenario YAML that combines one or more of the available",
        "integrations with the given chart. The scenario MUST:",
        "",
        "- Validate against the chart-test-swarm scenario schema",
        "  (engine/templates/scenario.schema.json).",
        "- Use cluster.provider: kind or minikube.",
        "- Have a valid id matching ^[a-z0-9][a-z0-9-]*$.",
        "- ANY cluster name reference MUST start with 'chart-test-swarm-'",
        "  followed by lowercase alphanumeric characters and hyphens.",
        "- Include at least one assert.",
        "- Output ONLY valid YAML between --- markers.",
        "- Do NOT include markdown fences or explanatory text.",
        "",
        "Required top-level keys: id, name, description, cluster, product, asserts.",
    ]

    if prior_result:
        lines.extend(
            [
                "",
                "─── Prior iteration result ───",
                prior_result,
                "",
                "Use this result to refine your next proposal. "
                "If the prior run PASSED, try a different integration combination. "
                "If it FAILED, propose a fix or a different approach.",
            ]
        )

    return "\n".join(lines)
