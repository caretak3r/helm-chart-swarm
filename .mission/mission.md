# Chart-Test-Swarm: Multi-Integration Helm Testgrid with LLM-Driven Variant Discovery

# Mission Proposal — Chart-Test-Swarm

## Plan Overview

Extend the existing `chart-test-swarm` engine into a sophisticated Kubernetes-integration testgrid that exercises any Helm chart against the full ecosystem matrix: ingress controllers, gateway-API implementations, certificate flows (cert-manager + manual + mounted), service meshes, policy engines, and cloud-native primers. Local execution runs against pluggable kind/minikube backends; cloud platform scenarios (GKE/AKS/EKS) are authored as fully-formed YAMLs + primers so consumers can ship them to their own clusters without running them in this repo. Every scenario card on the dashboard links to its applied override YAML, fixtures, and resulting manifests so reviewers can see exactly what was deployed. The capstone is an LLM-driven generator (`pick | author | explore`) that uses the host droid/agent CLI to discover novel variants beyond what is hand-written.

## Mission Architecture (Headline)

```
┌─────────────────────────────────────────────────────────────────┐
│  CLI: chart-test-swarm  (run | dashboard | list | generate ...) │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                ┌────────────────┼────────────────┐
                │                │                │
        ┌───────▼──────┐ ┌───────▼──────┐ ┌──────▼────────┐
        │ Engine (sh)  │ │ Testgrid (py)│ │ LLM Generator │
        │ kind|minikube│ │ Dashboard +  │ │ pick|author|  │
        │ schema + apply│ │ collect      │ │ explore       │
        └───────┬──────┘ └───────┬──────┘ └──────┬────────┘
                │                │               │
        ┌───────▼────────────────▼───────────────▼──────┐
        │ Integrations (organized by category subdir)   │
        │  certificates/  ingress-controllers/          │
        │  gateway-api/   service-mesh/  policy/        │
        │  cloud-native/  (GKE/AKS/EKS authored-only)   │
        └───────────────────────┬───────────────────────┘
                                │
                ┌───────────────▼───────────────┐
                │ Reports/run-*/                │
                │  artifacts/ (scenario + over- │
                │  rides + fixtures + manifests │
                │  + version stamps)            │
                │  index.html (linked artifacts │
                │  per scenario card)           │
                └───────────────────────────────┘
```

## Expected Functionality — 10 Milestones

### Milestone 1: engine-foundations
The chassis everything else rides on. Schema, dispatchers, reports, repo tooling.

- **F1.1** Minikube backend — extend `cluster-up.sh` with `minikube` branch; schema enum becomes `kind | minikube | k3d | eks | gke | aks | vcluster`; enforce `chart-test-swarm-*` cluster name prefix in all spin-up scripts.
- **F1.2** Raw-manifest preinstall support — `apply-scenario.sh` learns `kind: raw_manifest` (with `path` field); schema relaxes `additionalProperties: false` on `preinstall_item` to allow this kind alongside helm. Update `envoy-gateway` primer + scenario template to OCI registry (`oci://docker.io/envoyproxy/gateway-helm`).
- **F1.3** Integration category reorg — move existing 6 primers into category subdirs (certificates/, ingress-controllers/, service-mesh/, policy/) with NO behavior change. Update collect.py + scenario discovery to walk subdirs.
- **F1.4** Reports artifact contract — every `reports/run-*/` directory bundles `artifacts/scenario.yaml`, `artifacts/applied-overrides.yaml`, `artifacts/fixtures/*`, `artifacts/manifests/*`, and `versions.json` (helm, kubectl, kind, minikube, k8s server versions).
- **F1.5** Repo test scaffolding — bats dirs under `engine/scripts/tests/` and `engine/asserts/tests/`; `pytest` + `ruff` + `mypy` config under `engine/testgrid/`; root-level `shellcheck` + `yamllint` configs; sample tests proving each gate works; non-watch test commands.

### Milestone 2: dashboard-uplift
The dashboard becomes a true matrix view with linked artifact files per card.

- **F2.1** Per-scenario linked artifacts — each card renders anchor links to `artifacts/scenario.yaml`, `artifacts/applied-overrides.yaml`, fixture files, and applied manifests.
- **F2.2** Variant grouping — collapse 3-4 lean variants per integration under a single header row; show variant count + pass/fail breakdown.
- **F2.3** Cloud-platform column rendering — surface `cloud` mechanism category (GKE/AKS/EKS) visually distinct from local runs (icon + tooltip "authored, not run locally").
- **F2.4** Multi-run aggregation safeguards — stale run pruning, schema-drift handling between old/new report shapes, deterministic ordering.

### Milestone 3: certificates
Self-signed + manual + cert-manager paths against the sample chart.

- **F3.1** `certificates/cert-manager` primer rewrite + 3-4 scenarios (self-signed CA issuer, Let's Encrypt staging, wildcard, JKS/PKCS12 secret).
- **F3.2** `certificates/manual-tls-secret` primer + 3-4 scenarios (manual TLS Secret YAML wired to ingress, multiple SANs, ECDSA key).
- **F3.3** `certificates/mounted-tls-certs` primer + 3-4 scenarios (PVC mount, projected volume, CSI secret-store).
- **F3.4** Fixture set under `examples/sample-product-chart/chart-test/fixtures/certificates/` covering shared TLS material.

### Milestone 4: ingress-controllers
Three controllers, 3-4 lean variants each.

- **F4.1** `ingress-controllers/traefik` refresh into subdir + 3-4 variants (basic, TLS-passthrough, middleware-chain, IngressRoute CRD).
- **F4.2** `ingress-controllers/nginx-ingress` primer + 3-4 variants (basic, snippet annotations, default-backend, canary).
- **F4.3** `ingress-controllers/contour` primer + 3-4 variants (basic HTTPProxy, TLS delegation, rate-limit, JWT auth).

### Milestone 5: gateway-api-variants
Gateway API across three implementations.

- **F5.1** `gateway-api/envoy-gateway` primer + 3-4 variants (HTTPRoute, GRPCRoute, security-policy attach).
- **F5.2** `gateway-api/istio-gateway-api` primer + 3-4 variants (basic Gateway, multi-listener, BackendTLSPolicy).
- **F5.3** `gateway-api/contour-gateway-api` primer + 3-4 variants (basic, response-header-modifier, route-precedence).

### Milestone 6: service-mesh
Mesh-mode and mesh-ingress flavors.

- **F6.1** `service-mesh/istio-service-mesh` refresh into subdir + 3-4 variants (sidecar-injection, strict-mtls, peer-authentication, telemetry-v2).
- **F6.2** `service-mesh/istio-ingress-gateway` refresh + 3-4 variants (basic, multi-host, JWT, request-authentication).
- **F6.3** `service-mesh/linkerd` primer + 3-4 variants (basic mesh, multi-cluster preview, ServiceProfile, mTLS rotation).

### Milestone 7: policy-engines
OPA + Kyverno coverage.

- **F7.1** `policy/opa-gatekeeper` refresh + 3-4 variants (required-labels, image-allowlist, resource-limits, sync-config).
- **F7.2** `policy/kyverno` primer + 3-4 variants (validate, mutate, generate, image-verify).

### Milestone 8: cloud-native-primers (authored, not run)
Full YAMLs per cloud — consumer ships to their own clusters.

- **F8.1** `cloud-native/gke` primer + per-cloud YAMLs (Workload Identity, IAP, GKE Gateway Controller, regional cluster networking).
- **F8.2** `cloud-native/eks` primer + per-cloud YAMLs (IRSA, ALB Ingress Controller, ACK, Fargate).
- **F8.3** `cloud-native/aks` primer + per-cloud YAMLs (Workload Identity, AGIC, App Routing addon, Azure Policy).

### Milestone 9: cli-tool
Single entrypoint binary wraps engine + testgrid.

- **F9.1** CLI scaffolding (`chart-test-swarm` via typer) — argparse layout, root-help, packaging into engine/testgrid as additional console script.
- **F9.2** `run` subcommand wrapping `engine/scripts/dispatch-swarm.sh` (scenario file, integration filter, backend selector, parallelism).
- **F9.3** `dashboard` subcommand wrapping `engine/scripts/build-dashboard.sh`.
- **F9.4** `list integrations` + `list variants` introspection commands walking the category subdirs.

### Milestone 10: llm-generator
LLM-driven exploration on top of the CLI.

- **F10.1** `generate pick` — interactive menu over integrations × variants; user selects, scenario YAML is emitted.
- **F10.2** `generate author` — user describes a target ("istio with strict-mtls + cert-manager + JWT"); LLM (via host droid/agent CLI) authors a valid scenario YAML matching the schema.
- **F10.3** `generate explore` — given a chart + integration set, LLM iterates: pick a variant combo, generate scenario, run via CLI, read result, propose next combo (bounded by max iterations + budget).

## Environment Setup

- **OS:** macOS 25.4.0, Docker Desktop with **16 GiB** memory (user is bumping from current 7 GiB; mission assumes 16 GiB at run time).
- **Tools (verified installed):** docker, kubectl, helm, kind, minikube, uv, ruff, mypy, pytest, bats-core, shellcheck, yamllint, GNU make 3.81, jq, yq, curl.
- **Python:** `engine/testgrid` uses `uv` lockfile + pyproject. Adds dev deps: `ruff`, `mypy`, `pytest`, `types-PyYAML`, `jinja2-stubs`.
- **bd:** beads issue tracking active; one bd issue opened up-front per feature ID before mission run begins.
- **init.sh:** ensures all 12 brew tools resolvable, runs `uv sync --directory engine/testgrid`, creates `chart-test-swarm-*` namespace baseline, verifies docker memory >= 12 GiB free.

## Infrastructure

**Local services (worker-managed, ephemeral):**
- `kind` clusters — names prefixed `chart-test-swarm-*` only
- `minikube` profiles — names prefixed `chart-test-swarm-*` only
- No long-running shared services. Each scenario boots + tears down its own cluster.

**Ports:** No port range allocation — each kind/minikube cluster picks its own ports. Engine never opens host listeners.

**Boundaries (NEVER VIOLATE):**
- Cluster names must start with `chart-test-swarm-`. Workers MUST NOT touch any cluster without this prefix.
- No deletion of user files outside `examples/`, `engine/`, `reports/run-*/` (untracked work in `reports/` predates this mission and stays read-only).
- No commits to `main` from workers; each feature commits to a worker branch (handled by worker-base).
- Cloud-native scenarios (Milestone 8) are AUTHORED ONLY — workers must not run `kubectl apply` against any real GKE/AKS/EKS cluster from this machine.
- Off-limits: ports `5000` (AirPlay), ports outside Docker Desktop's range.

## Testing Strategy

**Programmatic Validation Plan (services.yaml commands):**

| Command       | Scope                                                                                          |
| ------------- | ---------------------------------------------------------------------------------------------- |
| `commands.test`      | `bats engine/scripts/tests engine/asserts/tests && uv run --directory engine/testgrid pytest` |
| `commands.typecheck` | `uv run --directory engine/testgrid mypy src/testgrid`                                   |
| `commands.lint`      | `uv run --directory engine/testgrid ruff check src/testgrid && shellcheck engine/scripts/*.sh engine/asserts/*.sh && yamllint engine/skills/chart-test-swarm/references/integrations/**/*.yaml examples/**/scenarios/*.yaml && helm lint examples/*/chart` |
| `commands.build`     | `uv sync --directory engine/testgrid`                                                    |
| `commands.install`   | `bash init.sh`                                                                            |

**Worker-level scoping:** workers run only the slice relevant to their feature before handoff (e.g., bats for a script change; pytest+mypy+ruff for a python change; yamllint+helm-lint for a scenario change). Milestone scrutiny runs the full split set above.

**Test types:**
- **Unit:** bats for shell scripts, pytest for testgrid python.
- **Integration:** scenario-level — `run-scenario.sh` invoked against kind/minikube, asserts execute, result.yaml shape verified.
- **E2e:** full pipeline — `dispatch-swarm.sh` against multi-scenario file, dashboard rendered, artifact bundle complete.

## User Testing Strategy

**Surfaces:**
1. **CLI** — `chart-test-swarm run|dashboard|list|generate ...`. Tested via direct invocation + output capture.
2. **Engine scripts** — `bash engine/scripts/run-scenario.sh ...` and `dispatch-swarm.sh ...`. Tested via direct invocation.
3. **Dashboard (HTML)** — rendered into `reports/run-*/dist/index.html`. Tested via `agent-browser` opening file:// URL to verify scenario cards render, artifact links resolve, matrix layout correct.
4. **Reports artifact bundle** — file-tree assertions on `reports/run-*/artifacts/`. Tested via `ls` + `yq`/`yamllint` reads.
5. **Cluster state** — `kubectl get` against `chart-test-swarm-*` clusters during scenario execution. Tested via `kubectl` from validator scripts.

**Tools required:** `agent-browser` (HTML dashboard), `curl`/`kubectl`/`helm` (cluster-state + chart), `yq`/`jq` (artifact JSON/YAML), `bash`/`pytest` (CLI + script invocation).

**Concurrency:** **2 concurrent validators on the cluster surface**, assuming Docker Desktop is at 16 GiB. Each kind/minikube cluster consumes ~3-4 GiB at idle + ~1 GiB headroom for the validator process. (Will be re-tightened to 1 if the Docker bump is deferred — encoded in `library/user-testing.md` so validators check at runtime.)

## Mission Readiness — VERIFIED ✅

Both dependency-readiness and validation-readiness subagent passes completed with READY verdict:

- **Dependencies:** 12/12 tools verified executable (minikube v1.38.1, ruff 0.15.14, mypy 2.1.0, pytest 9.0.3, bats 1.13.0, shellcheck 0.11.0, yamllint 1.38.0, plus docker/kubectl/helm/kind/uv).
- **End-to-end validation path:** kind cluster spun up in 27s, minimal scenario PASS 2/2 in 3s via `run-scenario.sh`, dashboard built (1593 bytes HTML), minikube up+delete clean in <50s.
- **Resource measurement:** ~1.5 GiB peak RAM delta during kind smoke; baseline supports 2 concurrent clusters at 16 GiB Docker.
- **Known non-blockers:** 7 shellcheck style warnings + 57 yamllint style errors on existing files (will be addressed in respective milestones); 0 .bats files yet (harness installed, populated during M1); envoy-gateway primer references defunct repo (fixed in F1.2).

## Non-Functional Requirements

- **Cluster name prefix discipline:** All workers MUST start cluster names with `chart-test-swarm-`. Validators check this at teardown.
- **No mid-mission watch modes:** Every test command exits cleanly; no background processes left after worker handoff.
- **Artifact reproducibility:** `reports/run-*/artifacts/` must be self-contained — a reviewer should be able to re-apply the scenario from artifacts alone without needing the source tree.
- **LLM cost control (M10):** explore mode capped at max iterations + max budget per session, configurable via CLI flag.
- **Cloud-native fidelity (M8):** authored YAMLs must pass `kubectl --dry-run=client` and `kubeval` validation even though they're not applied.
- **bd issue hygiene:** one bd issue per feature, opened up-front; workers update status (`bd update --claim`, `bd close`) as they own + complete; final `bd dolt push` + `git push` on mission close.

## Worker Types (Preview)

Six worker types planned (skills authored in `{missionDir}/skills/` after acceptance):
- `engine-bash` — shell scripts, schema, bats tests
- `testgrid-python` — python modules, jinja templates, pytest
- `primer-author` — integration markdown primers
- `scenario-author` — scenario YAMLs + fixtures + helm-lint passes
- `cli-builder` — typer CLI wiring + tests
- `llm-generator` — generator subcommands integrating host droid/agent CLI

## Approval

Approve to:
1. Create `missionDir` with `architecture.md`, `validation-contract.md`, `validation-state.json`, `features.json` (38 features across 10 milestones), `AGENTS.md`, `services.yaml`, `init.sh`, `library/`, and 6 worker skills.
2. Open 38 bd issues up-front (one per feature ID).
3. Start mission run executing features sequentially milestone-by-milestone, with scrutiny + user-testing validation at each milestone gate.
