# User Testing

Validator-facing knowledge for testing mission output through real user surfaces.

---

## Validation Surface

The mission produces output across five testable surfaces:

1. **CLI** — `chart-test-swarm run|dashboard|list|generate ...`. Validators invoke directly and capture stdout/stderr/exit-code.
2. **Engine scripts** — `bash engine/scripts/run-scenario.sh ...` and `dispatch-swarm.sh ...`. Validators invoke directly.
3. **Dashboard (HTML)** — rendered into `reports/run-*/dist/index.html`. Validators open `file://` URLs in `agent-browser`.
4. **Reports artifact bundle** — file-tree under `reports/run-*/artifacts/`. Validators use `ls`, `yq`, `jq`, and `find`.
5. **Cluster state** — `kubectl get` against active `chart-test-swarm-*` clusters mid-scenario. Validators use `kubectl` directly.

## Required Tools (for validators)

- `agent-browser` — REQUIRED for dashboard surface and for any HTML rendering validation. Validators MUST use this for VAL-DASH-*, VAL-CROSS-* assertions involving the dashboard.
- `bash` + `pytest` — for CLI and engine script invocation.
- `kubectl`, `helm`, `kind`, `minikube` — for cluster state validation.
- `yq` (>=4), `jq` — for YAML/JSON artifact inspection.
- `jsonschema` (Python pkg, available via `uv run --directory engine/testgrid`) — for cross-area schema sweep (VAL-CROSS-012, VAL-CROSS-030).
- `yamllint`, `shellcheck`, `helm lint` — already configured in `services.yaml` lint command.
- `openssl` — for VAL-CERT-* assertions that verify TLS material chains/SANs.

## Validation Prerequisites

- All 16 init.sh tools must be present (verified by readiness check; init.sh re-runs every session).
- Docker Desktop running with >= 12 GiB memory.
- No residual `chart-test-swarm-*` clusters before the validator session begins (init.sh warns if found; validators should also re-verify with `kind get clusters` and `minikube profile list`).
- For VAL-LLM-* assertions: `CTS_LLM_CMD` env var. For automated validators, point at `engine/testgrid/tests/stubs/llm-stub.sh` with an appropriate `LLM_STUB_PLAN`. For real-LLM exercises (orchestrator-driven), the user provides their host droid CLI command at run-time.
- For VAL-CLOUD-* assertions: NO real cloud cluster access. Use a local `chart-test-swarm-cloudv` kind cluster pinned to the matching k8s version + `kubeval` for schema validation.

## Validation Concurrency

Calibrated to 16 GiB Docker Desktop allocation. **70% of available headroom** rule applied.

| Surface             | Max concurrent | Rationale                                                                                                            |
| ------------------- | -------------- | -------------------------------------------------------------------------------------------------------------------- |
| Cluster (kind/minikube) | **2**       | Each kind cluster idle ~3-4 GiB; with chart + ingress + cert-manager controllers loaded ~5 GiB peak. 2 × 5 = 10 GiB; fits within 12 GiB headroom (16 GiB × 0.7 ~= 11.2). |
| Dashboard (HTML + agent-browser) | **1** | agent-browser is lightweight (~300 MB) but the dashboard is single-output; concurrent rendering risks read/write conflict on `reports/run-*/dist/`. Serialize. |
| LLM (CTS_LLM_CMD)   | **1**          | The host droid CLI is single-tenant from this repo's perspective; concurrent calls would interleave logs and confuse the budget tracking.  |
| Static (lint, schema sweep, file-tree audit) | **5** | Pure CPU/IO, no state collision. Cap at 5 (skill default).                                                            |

If Docker memory falls below 12 GiB at validator startup, fall back to **1 concurrent on cluster surface**. The validator MUST re-measure at startup, not assume.

## Cross-Surface Validation Notes

- **VAL-CROSS-012 (schema sweep):** Walks every `examples/sample-product-chart/chart-test/scenarios/*.yaml` and runs `jsonschema -i <file> engine/templates/scenario.schema.json`. Must exit 0 for all files. This is the canonical post-mission backward-compat gate.
- **VAL-CROSS-013/014/015 (artifact bundle audit):** Walks every `reports/run-*/result.yaml` with status=PASS and verifies the artifact bundle is complete (scenario.yaml, applied-overrides.yaml, fixtures/, manifests/, versions.json with 5 keys). Use `find` + `jq` + `yq`.
- **VAL-CROSS-016/017 (orphan cleanup):** Run a deliberately-failing scenario, then verify NO `chart-test-swarm-*` cluster or container persists after the engine's cleanup trap fires.
- **VAL-CROSS-019 (full local matrix run):** Use `chart-test-swarm run --suite full --backend kind --parallelism 2` and verify the dashboard renders all milestone categories.

## Pre-Existing Issues (non-mission blockers)

(Updated by validators as the mission progresses)

- None at mission start. Validators MUST log any newly-discovered pre-existing issues to AGENTS.md "Known Pre-Existing Issues" section per orchestrator triage rules.
