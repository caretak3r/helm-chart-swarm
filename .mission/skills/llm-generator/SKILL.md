---
name: llm-generator
description: Build the `chart-test-swarm generate {pick, author, explore}` subcommands that drive the host droid/agent CLI (via CTS_LLM_CMD) to author and explore scenario variants, with schema validation, prefix enforcement, and bounded iteration.
---

# llm-generator

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the WORK PROCEDURE for llm-generator workers (Milestone 10).

## Required Skills and Tools

- `bd` (beads).
- `uv` — same Python toolchain as cli-builder.
- `typer`, `pytest`, `mypy --strict`, `ruff`.
- `jsonschema` — validate every LLM-emitted scenario against `engine/templates/scenario.schema.json` BEFORE doing anything destructive (cluster up, file write, etc).
- `kind`, `minikube`, `kubectl`, `helm` — for `generate explore` end-to-end runs.
- `CTS_LLM_CMD` environment variable — points at the host droid/agent CLI command. Workers MUST go through this env var; never hardcode an LLM endpoint or embed an LLM client library.
- Mission boundaries from `{missionDir}/AGENTS.md`.

## Work Procedure

1. **Claim and read.**
   - `BD_ID=$(bd list --label feature-id:<feature-id> --json | jq -r '.[0].id // .issues[0].id') && bd update "$BD_ID" --claim`.
   - Read the feature's `description`, `preconditions`, `expectedBehavior`, `fulfills` from `{missionDir}/features.json`.
   - Read every `fulfills` assertion in `{missionDir}/validation-contract.md`. Pay special attention to VAL-LLM-001 through VAL-LLM-022 — they prescribe schema validation, prefix enforcement, retry behavior, and budget/iteration bounds.
   - Read F9.x CLI scaffolding (`engine/testgrid/src/chart_test_swarm/`) — generator subcommands live under `generate/` and reuse the same typer app.

2. **Write failing pytest tests first (red).**
   - Place tests under `engine/testgrid/tests/test_generate_<sub>.py`.
   - Mock `CTS_LLM_CMD` by setting it to a bash stub: `CTS_LLM_CMD="bash tests/stubs/llm-stub.sh"`. The stub reads `$LLM_STUB_PLAN` env var to determine what to emit on each invocation.
   - Test cases MUST include: (a) valid LLM output produces a schema-valid scenario, (b) invalid LLM output triggers a retry (max N), (c) prefix violation in `cluster.name`-equivalent (or any cluster operation) is REJECTED before any cluster work begins, (d) explore mode honors max-iterations and max-budget flags.

3. **Implement the subcommand.**
   - File: `engine/testgrid/src/chart_test_swarm/generate/<subcommand>.py`.
   - `generate pick`: interactive menu (typer prompts) over integrations × variants; emit a scenario YAML to stdout or to `--output <path>`.
   - `generate author`: take `--description "<freeform>"`, invoke `CTS_LLM_CMD` with a prompt template that asks the LLM to emit a YAML scenario; validate against schema; retry up to 3 times if validation fails; emit final YAML.
   - `generate explore`: take `--chart <path> --integrations <list> --max-iterations N --max-budget M`. Loop: ask LLM for next variant proposal → validate schema → enforce `chart-test-swarm-` prefix on any cluster name in the proposal → run via `bash engine/scripts/run-scenario.sh` → feed result back to LLM → repeat. STOP at max-iterations OR max-budget OR LLM declares satisfaction.
   - CRITICAL: schema/prefix validation happens BEFORE any cluster spin-up in `generate explore`. If iteration N proposes an invalid scenario, log the rejection and SKIP cluster work for that iteration — DO NOT create a cluster only to find the scenario invalid mid-flight.
   - Use subprocess.run() with `check=False` and a hard timeout for every `CTS_LLM_CMD` call.

4. **Verify locally (manual).**
   - `uv run --directory engine/testgrid pytest tests/test_generate_*.py -v` — green.
   - mypy/ruff clean.
   - `CTS_LLM_CMD="bash engine/testgrid/tests/stubs/llm-stub.sh" uv run --directory engine/testgrid chart-test-swarm generate author --description "istio with strict-mtls" --output /tmp/scenario.yaml` — produces a schema-valid YAML.
   - `CTS_LLM_CMD="bash engine/testgrid/tests/stubs/llm-stub.sh" LLM_STUB_PLAN="iter1=pass,iter2=prefix-violation,iter3=pass" uv run --directory engine/testgrid chart-test-swarm generate explore --chart examples/sample-product-chart/chart --integrations cert-manager --max-iterations 3` — verifies iteration 2 is rejected with no `escaped-cluster` ever appearing in `kind get clusters`.

5. **End-to-end real explore test (with the host droid CLI if available).**
   - If `CTS_LLM_CMD` points to the actual host droid CLI: run `chart-test-swarm generate explore --chart examples/sample-product-chart/chart --integrations cert-manager --max-iterations 2 --max-budget $5` — bounded by budget, terminate cleanly.
   - Verify each iteration's authored scenario is recorded in `reports/explore-*/summary.json`.

6. **Worker-scoped gates.**
   - pytest on generator tests.
   - mypy strict on `src/chart_test_swarm/generate/`.
   - ruff check + format on touched files.

7. **Cluster + process hygiene at handoff.**
   - `kind get clusters` empty of `chart-test-swarm-*`.
   - `minikube profile list` empty.
   - No straggling LLM subprocesses (verify via `ps aux | grep -E 'droid|cts_llm' | grep -v grep`).

8. **Commit and close.**
   - Commit on worker branch.
   - `bd close "$BD_ID"`.

## Example Handoff

```json
{
  "salientSummary": "Implemented F10.3 `chart-test-swarm generate explore` with bounded iteration, schema + prefix pre-validation, and reports/explore-*/summary.json output. Verified iteration-2 prefix-violation rejection via the LLM stub (no escaped-cluster ever entered kind get clusters); ran a real 2-iteration explore against the host droid CLI to completion with cluster teardown clean. 17 pytest cases green, mypy strict clean, ruff clean.",
  "whatWasImplemented": "Added engine/testgrid/src/chart_test_swarm/generate/explore.py implementing the explore loop. Defined a Proposal dataclass {iteration:int, scenario_yaml:str, status:str, error:str|None}. The loop is: (1) call CTS_LLM_CMD with the prompt + previous-iteration context; (2) parse the LLM's emitted YAML; (3) jsonschema-validate it; (4) regex-check any cluster-name-equivalent for ^chart-test-swarm-[a-z0-9-]+$; (5) if validation fails OR prefix violates, record the rejection in summary.json and SKIP cluster work for that iteration (continue to next); (6) otherwise dispatch via bash engine/scripts/run-scenario.sh and capture the result. Honors --max-iterations and --max-budget (USD tracked via the LLM stub's reported cost field). Added engine/testgrid/tests/stubs/llm-stub.sh with LLM_STUB_PLAN-driven multi-iteration scripting.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {"command": "uv run --directory engine/testgrid pytest tests/test_generate_explore.py -v", "exitCode": 0, "observation": "17 tests passing in 6.2s, including the prefix-violation skip test and the max-iterations exit test."},
      {"command": "uv run --directory engine/testgrid mypy src/chart_test_swarm/generate", "exitCode": 0, "observation": "Success: no issues found in 3 source files (strict mode)."},
      {"command": "uv run --directory engine/testgrid ruff check src/chart_test_swarm/generate tests/test_generate_explore.py", "exitCode": 0, "observation": "All checks passed."},
      {"command": "CTS_LLM_CMD=\"bash engine/testgrid/tests/stubs/llm-stub.sh\" LLM_STUB_PLAN=\"iter1=valid-cert-manager,iter2=prefix-violation-escaped-cluster,iter3=valid-ingress\" uv run --directory engine/testgrid chart-test-swarm generate explore --chart examples/sample-product-chart/chart --integrations cert-manager,ingress --max-iterations 3 --output reports/explore-test1/", "exitCode": 0, "observation": "Iteration 1 ran to PASS (cluster created and torn down), iteration 2 rejected pre-cluster (summary.json shows error='cluster.name pattern violation'), iteration 3 ran to PASS. kind get clusters | grep escaped-cluster returned empty throughout."},
      {"command": "yq '.iterations[] | {iteration, status}' reports/explore-test1/summary.json", "exitCode": 0, "observation": "iter1 PASS, iter2 REJECTED (with reason), iter3 PASS — matches expected output."},
      {"command": "kind get clusters | grep chart-test-swarm- || echo CLEAN", "exitCode": 0, "observation": "CLEAN."}
    ],
    "interactiveChecks": [
      {"action": "Manually invoke `chart-test-swarm generate explore --help` and verify --max-iterations, --max-budget, --output flags are documented; confirm the help text mentions the CTS_LLM_CMD env var requirement.", "observed": "All flags documented; help text includes 'Requires CTS_LLM_CMD env var pointing to the host droid CLI.'"}
    ]
  },
  "tests": {
    "added": [
      {
        "file": "engine/testgrid/tests/test_generate_explore.py",
        "cases": [
          {"name": "test_explore_iteration_proposes_valid_scenario_then_runs", "description": "LLM stub emits a valid cert-manager scenario on iteration 1; explore validates schema, dispatches to run-scenario.sh, captures PASS result."},
          {"name": "test_explore_rejects_prefix_violation_before_cluster_creation", "description": "LLM stub emits cluster.name=escaped-cluster on iteration 2; explore rejects pre-cluster, summary.json records the rejection, kind get clusters never contains escaped-cluster."},
          {"name": "test_explore_honors_max_iterations", "description": "With --max-iterations 2 and an LLM stub that would emit 5 valid proposals, explore exits after iteration 2 with status SUCCESS."},
          {"name": "test_explore_honors_max_budget", "description": "With --max-budget 2.00 and an LLM stub reporting $1.50 per iteration, explore exits after iteration 1 (next would exceed budget)."},
          {"name": "test_explore_writes_summary_json_in_correct_shape", "description": "reports/explore-*/summary.json has top-level keys: iterations[], total_cost, terminated_reason."}
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

In addition to the standard cases:
- `CTS_LLM_CMD` is not set and you cannot invoke the host droid CLI.
- The LLM consistently emits invalid YAML and exceeds the retry budget.
- The host droid CLI surface changes mid-mission (flag rename, output schema change).
- You need to add a new flag to `engine/templates/scenario.schema.json` to support LLM-emitted scenarios (this requires F1.x re-opening).
