# Environment

Environment variables, external dependencies, and setup notes.

**What belongs here:** Required env vars, external dependencies, dependency quirks, platform-specific notes.
**What does NOT belong here:** Service ports/commands (use `services.yaml`).

---

## Required Tools (verified at mission start)

All verified executable on this machine; init.sh re-checks every session:

| Tool         | Version verified | Notes                                                                       |
| ------------ | ---------------- | --------------------------------------------------------------------------- |
| docker       | (Docker Desktop) | Memory >= 12 GiB required; mission assumes 16 GiB at run-time              |
| kubectl      | latest           | Used by every engine script                                                 |
| helm         | v3.x             | Used for chart install + lint; OCI registry support required                |
| kind         | latest           | Local cluster backend; cluster name prefix enforced by scripts              |
| minikube     | v1.38.1          | Local cluster backend (F1.1 adds this branch)                               |
| uv           | latest           | ALL Python invocations go through `uv run --directory engine/testgrid`     |
| ruff         | 0.15.14          | Lint + format on testgrid python                                            |
| mypy         | 2.1.0            | Strict mode on testgrid python                                              |
| pytest       | 9.0.3            | Test runner for testgrid; supports `-n N` parallel via pytest-xdist        |
| bats         | 1.13.0           | Shell test runner for engine scripts and asserts                            |
| shellcheck   | 0.11.0           | Lint for `.sh` files                                                        |
| yamllint     | 1.38.0           | Style + structure check for YAML                                            |
| jsonschema   | (Python pkg)     | Scenario schema validation; available in `engine/testgrid` venv via `uv`  |
| jq, yq       | latest           | JSON/YAML inspection                                                        |
| openssl      | macOS bundled    | For F3.x certificate fixture generation                                     |
| bd (beads)   | latest           | Issue tracker; opens per-feature issues up-front                            |

**Allowlist status:** All tools resolvable on PATH; no network restrictions encountered during readiness check.

## Critical Environment Variables

- **`CTS_LLM_CMD`** — REQUIRED for M10 (llm-generator). Path/command to the host droid/agent CLI used by `chart-test-swarm generate {pick,author,explore}`. Workers MUST NOT hardcode an LLM endpoint. For tests, point this at `engine/testgrid/tests/stubs/llm-stub.sh`.
- **`PROVIDER`** — used by `cluster-up.sh` / `cluster-down.sh`. Values: `kind` (default), `minikube`, `k3d`. Other values (`eks`, `gke`, `aks`, `vcluster`) are present in the schema enum but MUST NOT be invoked from this machine.
- **`CLUSTER_NAME`** — used by every cluster-touching engine script. MUST match `^chart-test-swarm-[a-z0-9-]+$`. The bare prefix `chart-test-swarm` (no suffix) is INVALID.
- **`KEEP_CLUSTER`** — default behavior keeps cluster around after `run-scenario.sh` for debugging. `KEEP_CLUSTER=0` tears it down. F1.1 covers both branches.
- **`LLM_STUB_PLAN`** — only used in pytest tests. Comma-separated `iter<N>=<plan>` entries that drive the test stub at `engine/testgrid/tests/stubs/llm-stub.sh`.

## Bash Portability Note

macOS default `/bin/bash` is **3.2**. Engine scripts that use bash-4-only features (`mapfile`, associative arrays) MUST either:
1. Be rewritten using bash-3.2-compatible idioms (`while read` loops, indirect parameter expansion), OR
2. Add an explicit version check in the script prologue that exits non-zero with a stderr message naming the required version and how to upgrade (`brew install bash`).

The current codebase has `mapfile` in `dispatch-swarm.sh` (~line 42) and `aggregate.sh` (~line 37); associative arrays in `aggregate.sh` (~line 121). F1.5 either rewrites or guards these.

## Docker Desktop Memory

- Mission assumes **16 GiB** allocated to Docker Desktop at run-time.
- Concurrency of **2 validators** on the cluster surface assumes 16 GiB.
- If Docker memory < 12 GiB, init.sh warns; if < 8 GiB, workers should return to orchestrator.

## Scenario Path Convention

Scenarios live at `examples/sample-product-chart/chart-test/scenarios/*.yaml`.

The configuration in `examples/sample-product-chart/chart-test-swarm.yaml` sets `scenarios_dir: chart-test/scenarios`. The bare `examples/sample-product-chart/scenarios/` path is OBSOLETE — never use it.

## Integration Primer Path Convention

Post-F1.3, integration primers live at `engine/skills/chart-test-swarm/references/integrations/<category>/<integration>.md` where `<category>` is one of: `certificates`, `ingress-controllers`, `gateway-api`, `service-mesh`, `policy`, `cloud-native`.

Pre-F1.3 (before mission run): the 6 existing primers live at the top level of `references/integrations/`. F1.3 is a pure-rename feature; workers running M3+ depend on F1.3 having merged.

## Scenario Schema Field Reference

Authoritative: `engine/templates/scenario.schema.json`.

- `cluster.provider`: enum (F1.1 adds `minikube`). Cluster names live in `CLUSTER_NAME` env var, NOT in scenario YAML.
- `cluster.preinstall[]`: array of items. F1.2 adds a `kind` discriminator with values `helm` and `raw_manifest`. Pre-F1.2 scenarios (helm-only, no `kind:` discriminator) MUST continue to validate.
- `product.set` vs `product.values`: inline `product.set: {…}` is preferred for the 5 pre-mission scenarios; workers MUST NOT migrate them to `values:` file references unless their feature explicitly does so.
- `asserts[].type`: one of `pods-ready`, `service-reachable`, `helm-status-deployed`, `smoke-script`.
