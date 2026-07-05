# Plan 001 — `chart-test-swarm test` must actually run scenarios

- **Bead:** `chart-test-swarm-iab`
- **Category:** correctness (P0)
- **Written against commit:** `bfa3941`
- **Effort:** S (a few hours incl. tests)
- **Files in scope:** `engine/testgrid/src/chart_test_swarm/commands/test_cmd.py`, one new/edited pytest file under `engine/testgrid/tests/`
- **Files explicitly OUT of scope:** `engine/scripts/dispatch-swarm.sh` (do not modify), `engine/scripts/run-scenario.sh` (do not modify), `run_cmd.py` (its brief-only dispatch is intentional — leave it)

---

## Why this matters

`chart-test-swarm test` is the flagship "agentic full-matrix loop" command
(README lines ~217-236). Today it brings up a cluster, then for each scenario
calls `dispatch-swarm.sh` **without `--run`**. `dispatch-swarm.sh` only
executes scenarios when the `--run` flag is present; without it, the script
resolves scenarios, writes agent brief files, and exits 0. So `test`:

- never installs the chart, never runs a single assertion,
- counts **every** scenario as PASS (the caller treats `rc == 0` as PASS),
- never triggers the fix loop,
- prints an all-green summary while the dashboard shows everything UNTESTED
  (no `result.yaml` was ever written).

The pytest suite is green because `test_cli_test.py` replaces the engine with
**stub scripts** via the `CTS_ENGINE_SCRIPTS_DIR` env var — the stubs write a
`result.yaml` and return a status, so the tests never exercise the real
`dispatch-swarm.sh` no-op. The bug is invisible to the current tests by
construction.

## Current state (read these yourself before editing)

`test_cmd.py` — the per-scenario dispatch helper (lines 102-154):

```python
def _run_dispatch_scenario(
    scenario_path: Path,
    *,
    cluster_name: str,
    project_dir: Path,
    reports_dir: Path,
    parallelism: int,
) -> int:
    """Run a single scenario via dispatch-swarm.sh, returning exit code.

    Passes the scenario via ``CTS_SCENARIOS`` env var and uses
    ``single-scenario`` mode.
    """
    script = _resolve_engine_script("dispatch-swarm.sh")

    env = os.environ.copy()
    env["CTS_SCENARIOS"] = str(scenario_path)
    env["CLUSTER_NAME"] = cluster_name
    env["PROJECT_DIR"] = str(project_dir)
    env["REPORTS_DIR"] = str(reports_dir)
    env["PROVIDER"] = "kind"
    env["NUM_AGENTS"] = str(parallelism)

    run_id = _generate_run_id()
    env["RUN_ID"] = run_id
    ...
    cmd = [
        "bash",
        str(script),
        str(project_dir),
        "single-scenario",   # <-- becomes the SUITE positional; NOT --run
        str(parallelism),
        run_id,
    ]

    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    ...
    return result.returncode
```

`dispatch-swarm.sh` gates all execution on `--run` (lines 58-68, 462):

```bash
_EXECUTE_RUN=0
for _a in "$@"; do
  case "$_a" in
    --dry-run) _DRY_RUN=1 ;;
    --run)     _EXECUTE_RUN=1 ;;
    *)         _args+=("$_a") ;;
  esac
done
...
if [ "$_EXECUTE_RUN" -eq 1 ]; then     # line 462 — nothing runs without this
  echo "==> --run: executing $COUNT scenario(s) sequentially..."
  ...
```

`test_cmd.py` interprets the return code as PASS/FAIL (lines 328-348):

```python
rc = _run_dispatch_scenario(scenario, ...)
if rc == 0:
    passed += 1
    print("  ✓ PASS")
else:
    failed += 1
    ...
```

The caller already brought up **one shared cluster** at lines 307-317
(`_run_script("cluster-up.sh", ...)`) and tears it down in a `finally` block.
So `test` owns cluster lifecycle; the per-scenario call must **reuse** that
cluster, not create/destroy its own.

## Why not "just add `--run`"

`dispatch-swarm.sh --run` (lines 462-560) runs each scenario in its **own
fresh** cluster named `chart-test-swarm-run-<index>` and force-tears-it-down
(`KEEP_CLUSTER=0`). That conflicts with `test`'s single-shared-cluster model
and also entangles this fix with the unscoped-cleanup bug tracked separately
(`chart-test-swarm-7t1`). **Do not add `--run` here.** Instead, invoke
`run-scenario.sh` directly against the shared cluster — which is exactly what
the `--run` phase itself does per scenario (it calls
`bash run-scenario.sh "$f"` at lines 540-546), minus the per-scenario cluster
churn.

`run-scenario.sh` reuses an existing cluster: it calls the idempotent
`cluster-up.sh` with the given `CLUSTER_NAME` (line 821), and with
`KEEP_CLUSTER=1` it will not tear the cluster down (lines 947-950). So passing
the shared cluster name + `KEEP_CLUSTER=1` reuses `test`'s cluster and leaves
teardown to `test`'s `finally`.

## The fix

Rewrite `_run_dispatch_scenario` to invoke `run-scenario.sh` directly, reusing
the shared cluster, and derive PASS/FAIL/SKIP from the written `result.yaml`
(so SKIP — a non-failing status — is not silently counted as PASS by exit
code alone).

### Step 1 — replace the dispatch call with a direct `run-scenario.sh` call

In `_run_dispatch_scenario`, resolve `run-scenario.sh` instead of
`dispatch-swarm.sh`, set the reuse env, and run one scenario:

```python
def _run_dispatch_scenario(
    scenario_path: Path,
    *,
    cluster_name: str,
    project_dir: Path,
    reports_dir: Path,
    parallelism: int,  # retained for signature stability; unused for a single scenario
) -> int:
    """Execute a single scenario via run-scenario.sh against the shared
    cluster, returning 0 for PASS/SKIP and non-zero for FAIL.
    """
    script = _resolve_engine_script("run-scenario.sh")

    env = os.environ.copy()
    env["CLUSTER_NAME"] = cluster_name
    env["PROJECT_DIR"] = str(project_dir)
    env["REPORTS_DIR"] = str(reports_dir)
    env["PROVIDER"] = "kind"
    # Reuse the cluster `test` brought up; leave teardown to the caller's finally.
    env["KEEP_CLUSTER"] = "1"
    env["KEEP_ON_FAILURE"] = "1"

    cmd = ["bash", str(script), str(scenario_path)]

    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if result.stdout:
        sys.stdout.write(result.stdout)
        sys.stdout.flush()
    if result.stderr:
        sys.stderr.write(result.stderr)
        sys.stderr.flush()

    return result.returncode
```

Keep the existing stdout/stderr echoing behavior (already present in the
original). Remove the now-unused `CTS_SCENARIOS`, `NUM_AGENTS`, `RUN_ID`, and
`_generate_run_id()` call **from this function only** — but first check
whether `_generate_run_id` is used elsewhere (`grep -n _generate_run_id
engine/testgrid/src/chart_test_swarm/commands/test_cmd.py`); if it is, leave
the function defined and only drop its use here.

### Step 2 — treat SKIP correctly (optional-but-recommended, small)

`rc == 0` from `run-scenario.sh` covers both PASS and an all-SKIP/PASS mix
(SKIP is non-failing). That is acceptable for the PASS counter. Do **not**
try to distinguish SKIP by exit code. If you want SKIP surfaced in the
summary, that is a follow-up — keep this plan's scope to "FAIL is FAIL,
PASS/SKIP is not FAIL." No change needed beyond Step 1 for correctness.

### Step 3 — verify the escape hatch assumption

Confirm `run-scenario.sh` reuses (does not recreate/fail on) an existing
cluster:

```bash
grep -n "cluster-up" engine/scripts/run-scenario.sh
sed -n '815,825p' engine/scripts/run-scenario.sh
```

Expected: it calls `bash "$SCRIPT_DIR/cluster-up.sh"` unconditionally, and
`cluster-up.sh` is idempotent (creating a cluster that already exists is a
no-op / reuse). If instead you find `run-scenario.sh` errors when the cluster
already exists, **STOP and report** — the shared-cluster reuse assumption is
wrong and the fix needs rethinking (e.g. have `test` not pre-create the
cluster and let the first scenario create it).

## Test plan — this is the load-bearing part

The fix is one-line-ish; the anti-regression test is the real deliverable.
The test MUST fail if execution is ever skipped again.

Add to `engine/testgrid/tests/test_cli_test.py` (follow its existing
`CTS_ENGINE_SCRIPTS_DIR` stub pattern — read `_build_env` at ~line 226 and
`_write_stub`/`_setup_llm_mock` usage). Write a stub `run-scenario.sh` that:

1. writes a `result.yaml` with `status: FAIL` into the reports layout the
   collector expects, and
2. exits non-zero.

Then run the `test` loop (report-only, `--no-fix`) over a single scenario and
assert:

- the summary reports **1 failed / 0 passed** (proves the scenario "ran" and
  a FAIL propagated), and
- the stub `run-scenario.sh` was actually invoked (e.g. it appends a marker
  file the test checks).

This would have caught the original bug: the old code called
`dispatch-swarm.sh` (brief-only, exit 0) and reported PASS, so a test that
asserts the stubbed FAIL surfaces as `failed == 1` fails against the buggy
code and passes against the fix.

Add a second, **opt-in live** test marked so it is skipped in normal runs
(guard with `@pytest.mark.skipif(os.environ.get("CTS_LIVE_TESTS") != "1", ...)`
following any existing marker convention — grep `engine/testgrid/tests` for
`skipif`/`mark` first). It runs one real minimal scenario end-to-end on a kind
cluster and asserts a `result.yaml` with a real (`PASS`/`FAIL`/`SKIP`) status
is written. Do NOT wire this into the default CI lane.

## Done criteria (machine-checkable)

```bash
# 1. Unit + integration tests pass, including the new anti-regression test
uv run --directory engine/testgrid pytest -n 2
# expected: all pass, and the new test that asserts a stubbed FAIL surfaces
# as `failed == 1` is present and green

# 2. Types + lint clean
uv run --directory engine/testgrid mypy src/testgrid src/chart_test_swarm
uv run --directory engine/testgrid ruff check src/testgrid src/chart_test_swarm
# expected: no errors

# 3. The dispatch-brief-only call is gone from the test loop
grep -n "single-scenario" engine/testgrid/src/chart_test_swarm/commands/test_cmd.py
# expected: no output (the string is removed from _run_dispatch_scenario)

grep -n "run-scenario.sh" engine/testgrid/src/chart_test_swarm/commands/test_cmd.py
# expected: _run_dispatch_scenario now resolves run-scenario.sh
```

If you have a kind cluster available, also do a real smoke run and confirm a
`result.yaml` is written and the summary reflects real status:

```bash
uv run --directory engine/testgrid chart-test-swarm test \
  --project-dir examples/sample-product-chart --no-fix --suite pr-subset
# expected: at least one scenario produces a real PASS/FAIL, a result.yaml
# exists under the reports dir, and the summary is NOT trivially all-PASS
```

## Maintenance note

Anything that changes how `test` manages the cluster lifecycle (e.g. moving to
per-scenario clusters, or adopting `dispatch-swarm.sh --run`) interacts with
this fix — the `KEEP_CLUSTER=1` reuse contract is the hinge. Reviewers should
watch for a future change that reintroduces a dispatch call without `--run`,
or that removes the anti-regression test. The `run_cmd.py` path deliberately
dispatches briefs without executing (agent-driven mode); do not "fix" it to
match `test`.
