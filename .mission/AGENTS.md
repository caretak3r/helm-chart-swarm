# Mission Agents Guide

Operational guidance for ALL workers and validators on the chart-test-swarm mission. Read this before starting any feature.

---

## Mission Boundaries (NEVER VIOLATE)

**Cluster name prefix:**
- Every kind/minikube/k3d cluster you create or touch MUST have a name matching `^chart-test-swarm-[a-z0-9-]+$`.
- The bare prefix `chart-test-swarm` (no suffix) is INVALID; the suffix must be non-empty.
- Never `kind delete cluster`, `minikube delete`, or `kubectl --context` any cluster lacking this prefix — it belongs to the user or another mission.
- If a feature requires a different cluster naming scheme, STOP and return to orchestrator.

**Cloud-native (Milestone 8) is AUTHORED ONLY:**
- Workers MUST NOT run `kubectl apply`, `helm install`, or any state-changing command against GKE/AKS/EKS clusters from this machine.
- Cloud-native scenarios are validated via `kubectl --dry-run=client`, `kubeval`, and primer documentation review ONLY.
- If you find yourself authenticating to a real cloud cluster mid-mission, STOP and return.

**File system off-limits:**
- Do not delete, move, or modify files outside `examples/`, `engine/`, `reports/run-*/`, and `.beads/`.
- Workers MUST NOT touch `~/.kube/config` other than by adding/removing `chart-test-swarm-*` contexts via `kind` / `minikube`.
- `reports/run-*/` directories that pre-date this mission are read-only.

**Process hygiene:**
- Never leave background processes running after handoff. No `--watch`, `--serve`, dev servers, or live test runners.
- If a tool starts a child process, terminate it by PID (`kill <pid>`) before returning, NOT by name.
- Verify with `ps aux | grep -E 'kind|minikube|kubectl|helm'` (excluding grep itself) before handoff — output should be empty.

**Port range:** No port range claimed. Each kind/minikube cluster picks its own ports automatically. Workers MUST NOT bind host listeners.

**Docker Desktop memory:** Mission assumes 16 GiB. Concurrency of 2 validators is calibrated to that. If Docker shows <12 GiB available, return to orchestrator.

---

## Mission Directives

**Tools (required across the mission):**
- `bd` (beads) — one issue per feature ID; workers claim with `bd update <id> --claim` and close with `bd close <id>`. Read `bd ready` at session start; do NOT use TodoWrite for mission tracking.
- `bats` — shell test runner for engine/scripts/* and engine/asserts/*.
- `uv` — Python environment manager for `engine/testgrid/`.
- `pytest`, `mypy`, `ruff` — Python testing/typecheck/lint, invoked via `uv run --directory engine/testgrid`.
- `shellcheck`, `yamllint`, `helm lint` — repo-wide static checks.
- `jsonschema` — schema validation for scenarios.
- `kind`, `minikube`, `kubectl`, `helm`, `docker` — cluster + chart operations.
- `yq`, `jq` — YAML/JSON inspection.

**Skills (required):**
- All workers MUST invoke `mission-worker-base` at startup (handled automatically).
- All workers MUST invoke their type-specific skill (`engine-bash`, `testgrid-python`, `primer-author`, `scenario-author`, `cli-builder`, `llm-generator`).
- Scenario authors MUST consult `engine/skills/chart-test-swarm/references/integrations/<category>/<integration>.md` (the primer) before writing a scenario.
- LLM generator features (M10) MUST invoke the host droid/agent CLI via the `CTS_LLM_CMD` environment variable, not embedded LLM clients.

**Dependencies / packages:**
- Python (`engine/testgrid/pyproject.toml`): `jinja2`, `pyyaml`, `typer`, `jsonschema`, plus dev deps `ruff`, `mypy`, `pytest`, `types-PyYAML`, `jinja2-stubs`.
- No new Helm chart dependencies without explicit orchestrator approval.

**Other rules:**
- Workers MUST commit their work to a worker branch (handled by mission-worker-base); never push directly to `main`.
- Schema changes MUST be additive when possible (preserve backward compat for the 5 pre-mission scenarios listed in `examples/sample-product-chart/chart-test/scenarios/`).
- Inline `product.set: { ... }` style on those 5 pre-mission scenarios MUST be preserved; do not migrate to `values:` file references unless your feature explicitly mandates it.
- Cluster names supplied via `CLUSTER_NAME` env var. The scenario YAML schema does NOT carry a cluster-name field.
- Scenarios live under `examples/sample-product-chart/chart-test/scenarios/` (the `scenarios_dir: chart-test/scenarios` config in `examples/sample-product-chart/chart-test-swarm.yaml`). The bare `examples/sample-product-chart/scenarios/` path is OBSOLETE — never use it.
- Integration primers live under `engine/skills/chart-test-swarm/references/integrations/<category>/<integration>.md` (post-F1.3 reorg).
- Bash 3.2 is the macOS default. Engine scripts that use bash-4-only features (`mapfile`, associative arrays) MUST either be rewritten with portable idioms OR perform an explicit version check at preflight.

---

## Coding Conventions

**Bash scripts (`engine/scripts/*.sh`, `engine/asserts/*.sh`):**
- Always `set -euo pipefail` at the top.
- Trap cleanup with `trap 'cleanup' EXIT INT TERM` when the script spins up clusters or background processes.
- Accept `--help` flag and exit non-zero on unknown flags.
- Use `printf` not `echo -e`; quote all variable expansions.
- Pass `shellcheck` clean (no warnings of severity >= warning).

**Python (`engine/testgrid/src/testgrid/`):**
- Type-hint all module-level functions; pass `mypy --strict` on the testgrid src tree.
- `ruff check` clean.
- pytest tests live under `engine/testgrid/tests/`; use the `tests/` adjacent to `src/`.
- Use `pathlib.Path`, not raw string path concatenation.

**YAML scenarios (`examples/sample-product-chart/chart-test/scenarios/*.yaml`):**
- Must pass `jsonschema -i <file> engine/templates/scenario.schema.json` exit 0.
- Must pass `yamllint -c .yamllint` repo-wide config.
- File name should match `^[a-z0-9][a-z0-9-]*\.yaml$` and contain the integration category in the filename (e.g. `cert-manager-self-signed.yaml`).
- Use 2-space indentation; document-start `---` is required.
- Reference fixtures by relative path from the scenario file (`fixtures/certificates/<file>`).

**Markdown primers (`engine/skills/chart-test-swarm/references/integrations/<category>/<name>.md`):**
- Required H2 sections: `Overview`, `Variants`, `How to apply`, `Assertions`, `Known gotchas`, plus `Target Kubernetes version` for cloud-native primers.
- Each variant section describes a real scenario YAML (link to it relatively).
- No trailing whitespace; pass `markdownlint` if invoked.

---

## Testing & Validation Guidance

**Worker-level scoping (run only what is relevant to your change):**
- Bash script change → `bats engine/scripts/tests/<your-script>.bats` + `shellcheck` on edited scripts + `helm lint` if a chart was touched.
- Python change → `uv run --directory engine/testgrid pytest tests/<related>.py` + `uv run --directory engine/testgrid mypy src/testgrid` + `uv run --directory engine/testgrid ruff check src/testgrid`.
- Scenario YAML change → `yamllint <file>` + `jsonschema -i <file> engine/templates/scenario.schema.json` + `bash engine/scripts/run-scenario.sh <file>` end-to-end + `helm lint examples/sample-product-chart/chart`.
- Primer change → re-read against the H2 schema above; if cloud-native, also `kubectl --dry-run=client -f <yaml>` for any referenced examples.

**Milestone gate (run by scrutiny validator — do NOT pre-run unless you broke something):**
- `commands.test`, `commands.typecheck`, `commands.lint`, `commands.build` defined in `services.yaml`. These run on every milestone close.

**Cluster discipline at handoff:**
- Run `kind get clusters` AND `minikube profile list -o json` before declaring done. The list MUST be empty of `chart-test-swarm-*` entries unless you intentionally left a cluster for the user (in which case document it in the handoff `whatWasLeftUndone` field).
- Run `docker ps --filter "name=chart-test-swarm-" --format '{{.Names}}'` — also must be empty.

**User-testing validator concurrency:** 2 concurrent validators on the cluster surface (assumes Docker Desktop = 16 GiB). 1 concurrent on the dashboard/HTML surface (lightweight). 1 concurrent on the LLM surface (LLM invocations serialize through the host droid CLI).

**Pre-existing known issues (do NOT fix in this mission):**
- `yamllint` reports ~57 style errors (braces spacing, line-length) on all pre-existing scenarios under `examples/sample-product-chart/chart-test/scenarios/`. New scenarios MAY match the existing style; do NOT widen scope to cleaning these up. Reported by f1-2 (raw_manifest preinstall).
- `engine/scripts/tests/cluster-lifecycle.bats` includes a real-cluster minikube test (`cluster-up accepts PROVIDER=minikube with valid prefixed name`) that can leave a `chart-test-swarm-bats-mk` profile if the bats run is interrupted. Workers running this suite MUST run `minikube delete -p chart-test-swarm-bats-mk 2>/dev/null || true` in their teardown. Tracked for proper teardown() block fix in `misc-fixes-1` milestone (f-misc-1).
- Repository `/Users/rohit/Documents/chart-test-swarm` has no git remote configured. Workers MUST commit locally as instructed by their skill, but `git push` will fail with "no upstream"/"no remote". The mission-close protocol from the repo's CLAUDE.md mandates `git push` — the orchestrator will escalate to the user at mission close so a remote can be added. Workers should NOT attempt to `git push` themselves; the mission-close protocol is the orchestrator's concern.
- `jinja2-stubs` is not published to PyPI. f1-5 must either skip jinja2 stub installation or add `[[tool.mypy.overrides]] module="jinja2.*" ignore_missing_imports=true` to keep strict mode otherwise intact.

---

## Beads (bd) Hygiene

- One bd issue is opened up-front per feature ID (e.g. `f1-1-minikube-backend`, `f2-3-cloud-platform-column`). Each is titled `[mission/<milestone>] <feature-id>` and labeled `feature-id:<feature-id>`.
- At session start, workers MUST resolve their bd issue ID by running:
  `BD_ID=$(bd list --label feature-id:<feature-id> --json | jq -r '.[0].id // .issues[0].id')`
  then claim with `bd update "$BD_ID" --claim`.
- At session end (before handoff), workers MUST close with `bd close "$BD_ID"`.
- DO NOT use `bd remember` for transient session notes; use the worker handoff fields instead.
- At mission close, the orchestrator runs `bd dolt push` + `git push` (per the project's session-completion protocol in `CLAUDE.md` / `AGENTS.md` at the repo root).

---

## When to Return to Orchestrator

In addition to the general worker rules, return immediately if:
- A scenario you must author requires a `cluster.preinstall` kind beyond `helm` or `raw_manifest` (no other kinds are in scope).
- Your feature depends on a primer or scenario that hasn't been authored yet AND isn't in your preconditions.
- You hit a tool/version mismatch (e.g. `bats --version` < 1.10, `uv --version` missing, `minikube` missing).
- Docker Desktop reports < 12 GiB available memory.
- You discover the `examples/sample-product-chart/chart-test/` subdir is missing (it should exist by mission start; if it doesn't, F1 ordering broke).
- You believe a validation contract assertion is wrong or untestable — DO NOT silently rewrite it; flag it in the handoff.
