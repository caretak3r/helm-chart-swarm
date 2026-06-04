## Area: CLI Tool

### VAL-CLI-001: Console script registered in pyproject.toml
`engine/testgrid/pyproject.toml` `[project.scripts]` declares a `chart-test-swarm` entry pointing at a `main`/`app` callable inside the `testgrid` package (alongside the existing `testgrid` entry).
Tool: yq
Evidence: terminal-output of `yq -p toml '.project.scripts."chart-test-swarm"' engine/testgrid/pyproject.toml` returns a non-null string ending in `:main` or `:app`; file(engine/testgrid/pyproject.toml).

### VAL-CLI-002: Console script installs on PATH after uv sync
Running `uv sync --directory engine/testgrid` makes the `chart-test-swarm` binary discoverable inside the project virtualenv, and `engine/testgrid/.venv/bin/chart-test-swarm` is an executable file.
Tool: bash
Evidence: exit-code 0 from `test -x engine/testgrid/.venv/bin/chart-test-swarm`; terminal-output of `engine/testgrid/.venv/bin/chart-test-swarm --version` (or `--help`) is non-empty on stdout.

### VAL-CLI-003: Root --help exits 0 and lists all subcommands
`chart-test-swarm --help` exits 0 and the output contains the substrings `run`, `dashboard`, `list`, and `generate` (case-sensitive).
Tool: bash
Evidence: exit-code 0; terminal-output of `chart-test-swarm --help | grep -E '^\s*(run|dashboard|list|generate)\b'` shows all four subcommand lines.

### VAL-CLI-004: No-args invocation exits non-zero with help message
`chart-test-swarm` with no subcommand exits non-zero and prints a usage/help message to stderr (or stdout) that includes the program name and the subcommand list.
Tool: bash
Evidence: exit-code != 0 from `chart-test-swarm`; combined stdout+stderr contains the literal `Usage` and at least one of `run|dashboard|list|generate`.

### VAL-CLI-005: Unknown subcommand exits non-zero with clear error
`chart-test-swarm not-a-real-subcommand` exits non-zero and the error message names the offending token.
Tool: bash
Evidence: exit-code != 0; stderr contains `not-a-real-subcommand` (typer/click style "No such command" or equivalent).

### VAL-CLI-006: `run --help` exposes required flags
`chart-test-swarm run --help` exits 0 and the output advertises all four flags: `--scenario`, `--integration`, `--backend`, `--parallelism`.
Tool: bash
Evidence: exit-code 0; terminal-output passes `grep -q -- --scenario && grep -q -- --integration && grep -q -- --backend && grep -q -- --parallelism`.

### VAL-CLI-007: `run --scenario <path>` dispatches via dispatch-swarm.sh and writes run-* directory
Invoking `chart-test-swarm run --scenario examples/sample-product-chart/chart-test/scenarios/<a>.yaml` triggers `engine/scripts/dispatch-swarm.sh` (verifiable via a `--dry-run` flag that prints the resolved command, or via a stub on PATH) and, on a real run, creates exactly one new directory matching `reports/run-*` containing `result.yaml`.
Tool: pytest
Evidence: pytest test using `subprocess.run` with `PATH` shimmed so `dispatch-swarm.sh` is a captured stub asserts the stub was invoked with the scenario path; on a live run, `Path('reports').glob('run-*')` count increases by 1 and `result.yaml` exists in the new dir.

### VAL-CLI-008: `run --integration <name>` filters scenarios to that integration only
`chart-test-swarm run --integration cert-manager --dry-run` (or with the dispatch stub) shows that only scenarios whose path contains `cert-manager` (or whose `integration:` field equals `cert-manager`) are passed downstream.
Tool: pytest
Evidence: pytest test inspects the recorded scenario list from the stub and asserts every path matches `*cert-manager*`; for non-matching integration name, the list is empty and the CLI exits non-zero with a "no scenarios matched" message.

### VAL-CLI-009: `run --backend minikube` forwards backend to engine scripts
`chart-test-swarm run --backend minikube --dry-run` (or via stub) results in the downstream invocation receiving `--backend minikube` (or equivalent env var) verbatim; passing `--backend invalid-backend` exits non-zero with a schema-enum error before any cluster work begins.
Tool: pytest
Evidence: stub captures argv containing `--backend minikube`; for the invalid case, exit-code != 0 and stderr contains `kind|minikube|k3d|eks|gke|aks|vcluster` or `invalid choice`.

### VAL-CLI-010: `run --parallelism N` caps concurrent scenarios at N
`chart-test-swarm run --parallelism 2` causes dispatch-swarm.sh to be invoked with `NUM_AGENTS=2` (or the third positional arg `2`), and `--parallelism 0` / negative values are rejected with exit-code != 0.
Tool: pytest
Evidence: stub asserts `NUM_AGENTS=2` in the environment or `2` as positional arg; pytest parametrized test covers `--parallelism 0`, `--parallelism -1`, `--parallelism foo` all returning non-zero with a clear validation error.

### VAL-CLI-011: `dashboard` invokes build-dashboard.sh and produces index.html
`chart-test-swarm dashboard` shells out to `engine/scripts/build-dashboard.sh` and, on a non-empty `reports/` tree, writes `reports/<run-id>/dist/index.html` (or `reports/dist/index.html` per the script's default).
Tool: bash
Evidence: exit-code 0; file(reports/dist/index.html) or file(reports/<run-id>/dist/index.html) exists and contains `<html`; stub mode captures `build-dashboard.sh` invocation in argv log.

### VAL-CLI-012: `list integrations` enumerates every (category, integration) tuple
`chart-test-swarm list integrations` walks `engine/skills/chart-test-swarm/references/integrations/<category>/<integration>.md` and prints one line per primer in a stable, sorted order, with category and integration both visible.
Tool: pytest
Evidence: pytest test asserts that for a fixture integrations tree (`certificates/cert-manager.md`, `ingress-controllers/nginx-ingress.md`), the stdout contains both `certificates\tcert-manager` and `ingress-controllers\tnginx-ingress` (or equivalent two-column format) and lines are sorted.

### VAL-CLI-013: `list variants --integration <name>` enumerates matching scenario YAMLs
`chart-test-swarm list variants --integration cert-manager` prints every scenario YAML path under `examples/*/scenarios/` whose filename or `integration:` field matches `cert-manager`; omitting `--integration` lists all variants across all integrations.
Tool: pytest
Evidence: pytest fixture creates scenarios `certificates-cert-manager-self-signed.yaml` and `certificates-cert-manager-letsencrypt.yaml`; CLI stdout contains both paths and excludes `ingress-controllers-nginx-basic.yaml`.

### VAL-CLI-014: Cluster name prefix is enforced before any cluster-creating subcommand
Any subcommand that would create or touch a cluster (run, generate explore) refuses to proceed if the resolved cluster name does not start with `chart-test-swarm-`; the check happens before subprocess dispatch.
Tool: pytest
Evidence: pytest test invokes `chart-test-swarm run` with `CLUSTER_NAME=not-prefixed-cluster` (or equivalent override); exit-code != 0 and stderr contains `chart-test-swarm-` and the offending name; no `kind create cluster` / `minikube start` invocation is recorded by the PATH stub.

### VAL-CLI-015: CLI argument parsing is covered by pytest for every subcommand
`engine/testgrid/tests/test_cli.py` exists and contains `pytest` test cases that exercise `--help`, valid invocation, and at least one invalid-flag case for each of `run`, `dashboard`, `list integrations`, `list variants`, `generate pick`, `generate author`, `generate explore`.
Tool: pytest
Evidence: terminal-output of `uv run --directory engine/testgrid pytest tests/test_cli.py -v` shows ≥ 1 passing test per subcommand (matched via test-name grep); exit-code 0.

### VAL-CLI-016: No orphan processes or stranded clusters after CLI exits
After `chart-test-swarm run --scenario <path>` completes (PASS or FAIL), `docker ps --format '{{.Names}}' | grep chart-test-swarm-` is empty AND `kind get clusters | grep chart-test-swarm-` is empty AND `minikube profile list -o json | jq '.valid[]?.Name' | grep chart-test-swarm-` is empty.
Tool: bash
Evidence: exit-code 1 (i.e., grep finds nothing) from each of the three commands; no child processes of the CLI remain in `pgrep -P $$` after CLI exits.

### VAL-CLI-017: Repo lint + typecheck gates pass for CLI module
`uv run --directory engine/testgrid ruff check src/testgrid` and `uv run --directory engine/testgrid mypy src/testgrid` both exit 0 against the CLI module (including any new `cli.py` / `commands/` files added for `chart-test-swarm`).
Tool: bash
Evidence: exit-code 0 from both commands; terminal-output contains `All checks passed!` (ruff) and `Success: no issues found` (mypy).

### VAL-CLI-018: `run` emits machine-readable run id to stdout for chaining
After dispatching, `chart-test-swarm run --scenario <path>` prints the resolved `RUN_ID` (matching `^run-[0-9]{8}-[0-9]{6}$`) as the last line of stdout so callers (including `generate explore`) can capture it programmatically.
Tool: bash
Evidence: terminal-output `chart-test-swarm run --scenario <path> | tail -n1` matches `^run-[0-9]{8}-[0-9]{6}$`; the printed directory `reports/<run-id>` exists on disk after exit.

### VAL-CLI-019: CLI exits with a clear error for a missing scenario file (no Python traceback)
Invoking `chart-test-swarm run --scenario /tmp/does-not-exist.yaml` exits non-zero within 5 seconds. Stderr contains the literal path `/tmp/does-not-exist.yaml` AND a phrase like "not found" / "no such file" / "does not exist". Stderr DOES NOT contain `Traceback (most recent call last)` or `FileNotFoundError`. Pass requires non-zero exit + actionable message + no raw Python traceback.
Tool: bash
Evidence: exit-code, terminal-output(stderr)

### VAL-CLI-020: CLI `--version` prints a semver-ish version string and exits 0
Running `chart-test-swarm --version` exits 0 within 2 seconds and stdout contains a version token matching `^\d+\.\d+\.\d+` (semver) OR `^v\d+\.\d+\.\d+`. The version is the version recorded in `engine/testgrid/pyproject.toml`'s `[project].version` field. Pass requires both exit 0, semver-shaped output, AND match against pyproject.
Tool: bash
Evidence: exit-code, terminal-output(stdout), command-output(`yq -p toml '.project.version' engine/testgrid/pyproject.toml`)

### VAL-CLI-021: CLI `run` and `bash engine/scripts/run-scenario.sh` produce equivalent reports/run-* outputs for the same scenario
For the same scenario YAML, invoking once via `chart-test-swarm run --scenario <path>` and once via `bash engine/scripts/run-scenario.sh <path>` both produce a `reports/run-*` directory. Comparing the two: `result.yaml.scenarios[].status` is identical, `artifacts/scenario.yaml` is byte-identical (or differs only in absolute-path normalization), `artifacts/versions.json` keys are identical (values may differ if tool versions changed), and `artifacts/applied-overrides.yaml` is byte-identical. Pass requires status equivalence + artifact-shape equivalence.
Tool: bash
Evidence: terminal-output(`diff <(yq '.scenarios[] | {id,status}' reports/run-A/result.yaml) <(yq '.scenarios[] | {id,status}' reports/run-B/result.yaml)` empty), terminal-output(`diff reports/run-A/scenario-*/artifacts/scenario.yaml reports/run-B/scenario-*/artifacts/scenario.yaml` empty)

### VAL-CLI-022: Every CLI flag has a documented engine-script env-var mapping
The CLI's `--backend`, `--cluster-name`, `--parallelism`, `--run-id`, `--reports-dir`, `--project-dir`, `--scenario`, `--suite` flags each map to exactly one engine-script env var. The mapping table lives in `engine/cli/src/chart_test_swarm/forward.py` (or equivalent) as a literal dict, AND `chart-test-swarm run --scenario ... -x` (or via `CTS_DEBUG=1 bash -x`) produces output showing the env var was set with the CLI-supplied value. Concretely: `--backend minikube` ⇒ `PROVIDER=minikube`, `--parallelism N` ⇒ `NUM_AGENTS=N`, `--cluster-name foo` ⇒ `CLUSTER_NAME=foo`, `--run-id X` ⇒ `RUN_ID=X`, `--reports-dir D` ⇒ `REPORTS_DIR=D`, `--project-dir P` ⇒ `PROJECT_DIR=P`, `--suite S` ⇒ `SUITE=S`. Pass requires the mapping table is asserted + observed.
Tool: bash
Evidence: terminal-output (`CTS_DEBUG=1 chart-test-swarm run --backend minikube --parallelism 2 --cluster-name ct-x ...` shows `PROVIDER=minikube`, `NUM_AGENTS=2`, `CLUSTER_NAME=ct-x` in the trace), grep-match (`rg -n 'FLAG_TO_ENV' engine/cli/src/`)

### VAL-CLI-023: `service-reachable.sh` invokes `kubectl run` with valid flags only
Running an `service-reachable` assertion exits with a sensible status (not a kubectl usage error). Concretely: `service-reachable.sh` does NOT pass `--timeout=<duration>` to `kubectl run` (the correct flag for in-pod runtime cap is `--pod-running-timeout`; `--timeout` is not a `kubectl run` flag). Pass requires: the `kubectl ... run` line in `service-reachable.sh` uses ONLY documented `kubectl run` flags, verifiable by running `kubectl run --help | grep -E '^      --'` and confirming each flag used by the script appears in the help output.
Tool: bash
Evidence: terminal-output (`grep -E 'kubectl .* run' engine/asserts/service-reachable.sh` extracts the args; cross-check against `kubectl run --help`), bash-test (`bash engine/asserts/service-reachable.sh <synthetic-scenario> 0` exits 0 when the service is reachable, NOT 1 due to `error: unknown flag: --timeout`)

### VAL-CLI-024: `list integrations` enumerates all six expected category subdirectories
Running `chart-test-swarm list integrations` against a populated production integrations tree (post-F1.3 reorg) emits at least one line per the six expected categories: `certificates`, `ingress-controllers`, `gateway-api`, `service-mesh`, `policy`, `cloud-native`. The output is sorted deterministically, and no spurious top-level categories (e.g. legacy unmoved primers) appear. Pass requires: all six categories present in the output AND no top-level categories outside the expected set.
Tool: bash
Evidence: terminal-output (`chart-test-swarm list integrations | awk '{print $1}' | sort -u` produces the exact set `{certificates, ingress-controllers, gateway-api, service-mesh, policy, cloud-native}`)
