# Chart-Test-Swarm Architecture

This document is the authoritative architectural design for the mission. Workers and validators MUST treat this as the canonical source of structural truth. If a worker discovers a real-world conflict with this document, they must return to the orchestrator rather than silently diverging.

---

## 1. Goals and Constraints

**Goal:** A pluggable testgrid that exercises any Helm chart against a matrix of Kubernetes ecosystem integrations (certificates, ingress, gateway-API, mesh, policy) on local backends (kind, minikube), with cloud-platform scenarios authored as ready-to-ship YAMLs. Reports are auditable artifact bundles. An LLM-driven generator discovers novel variants.

**Hard constraints:**
- Cluster names MUST be prefixed `chart-test-swarm-`. Anything without that prefix is off-limits.
- Cloud-native scenarios (Milestone 8) are AUTHORED ONLY — no `kubectl apply` against real GKE/AKS/EKS from this repo.
- Reports are immutable once written; multiple runs accumulate side-by-side under `reports/run-*`.
- Every scenario card on the dashboard MUST link to its applied artifacts (scenario YAML, overrides, fixtures, manifests).
- Worker scripts MUST exit cleanly with no background processes.

---

## 2. Top-Level Component Map

```
chart-test-swarm/
├── engine/                                 # Core execution engine
│   ├── scripts/                            # Bash entry points (kind/minikube/dispatch)
│   ├── asserts/                            # Assertion runners (4 types today: pod_ready, http, helm_test, smoke_script)
│   ├── templates/                          # JSON schema + scenario template
│   ├── testgrid/                           # Python package: collect + render dashboard
│   │   ├── pyproject.toml
│   │   └── src/testgrid/{cli.py,collect.py,render.py,templates/}
│   └── skills/chart-test-swarm/
│       ├── SKILL.md                        # 13-phase orchestrator skill
│       └── references/
│           ├── workflow.md
│           ├── scenario-schema.md
│           └── integrations/               # Primers, REORGED into category subdirs
│               ├── certificates/
│               ├── ingress-controllers/
│               ├── gateway-api/
│               ├── service-mesh/
│               ├── policy/
│               └── cloud-native/
├── examples/
│   └── sample-product-chart/
│       ├── chart/                          # The Helm chart under test
│       └── chart-test/
│           ├── fixtures/                   # NEW: shared TLS material, manifests
│           ├── assertions/                 # NEW: assertion configs referenced by scenarios
│           └── scenarios/*.yaml            # Scenario definitions per integration variant (per `scenarios_dir: chart-test/scenarios` in `chart-test-swarm.yaml`)
├── reports/
│   └── run-<timestamp>/
│       ├── result.yaml                     # Outcome summary
│       ├── artifacts/                      # NEW: scenario + overrides + fixtures + manifests + versions
│       │   ├── scenario.yaml
│       │   ├── applied-overrides.yaml
│       │   ├── fixtures/
│       │   ├── manifests/
│       │   └── versions.json
│       └── dist/index.html                 # Dashboard rendered by testgrid
└── docs/                                   # Phase-2 plan, design docs
```

---

## 3. Component Responsibilities and Boundaries

### 3.1 Engine Scripts (`engine/scripts/*.sh`)
**Responsibility:** Drive cluster lifecycle, apply scenarios, run assertions, capture results.

**Key scripts and contracts:**

| Script              | Contract                                                                                     |
| ------------------- | -------------------------------------------------------------------------------------------- |
| `cluster-up.sh`     | Accept `PROVIDER=kind|minikube|k3d`, `CLUSTER_NAME=chart-test-swarm-<id>`, spin up cluster.  |
| `cluster-down.sh`   | Accept the same `PROVIDER` + `CLUSTER_NAME`, tear down idempotently.                         |
| `apply-scenario.sh` | Read scenario YAML, apply `cluster.preinstall[]` (helm + raw_manifest), install product chart.|
| `run-asserts.sh`    | Execute assertions, return PASS/FAIL with detail per assertion.                              |
| `run-scenario.sh`   | One-shot: up → apply → assert → down, write `result.yaml` + `artifacts/`.                   |
| `dispatch-swarm.sh` | Multi-scenario orchestrator; bounded parallelism (default 2 with 16 GiB Docker).            |
| `build-dashboard.sh`| Invoke testgrid python to render `reports/run-*/dist/index.html`.                            |

**Invariants:**
- Every script accepts `--help` and exits non-zero on unknown flags.
- All scripts must `set -euo pipefail` and trap cleanup.
- `CLUSTER_NAME` is supplied via env var to engine scripts; scripts MUST reject any value that does not match the regex `^chart-test-swarm-[a-z0-9-]+$` before any destructive op. This prefix invariant is **script-enforced**, not schema-enforced — the scenario YAML schema does NOT carry a cluster-name field.

### 3.2 Schema (`engine/templates/scenario.schema.json`)
**Responsibility:** Single source of truth for valid scenario shape.

**Key fields (current schema):**
- `id`: string matching `^[a-z0-9][a-z0-9-]*$` (required).
- `cluster.provider`: enum `kind | k3d | eks | gke | aks | vcluster` (required). F1.1 ADDS `minikube` to this enum.
- `cluster.k8s_version`, `cluster.config`: optional provider settings.
- `cluster.preinstall[]`: optional array of preinstall items. Current shape has no `kind` discriminator (all items are implicitly helm). F1.2 ADDS a `kind` discriminator with values `helm` (default for backward compat) and `raw_manifest`.
- `product.chart` + `product.release` + `product.namespace`: required chart location, release name, and namespace.
- `product.set` / `product.values`: inline overrides (preferred shape on the 5 pre-mission scenarios) and/or path-to-values-file overrides.
- `asserts[]`: list of assertion configs (required, minItems 1). Supported `type` values: `pods-ready`, `service-reachable`, `helm-status-deployed`, `smoke-script`.

**Cluster naming:** Cluster names do NOT live in the scenario YAML. They are supplied via the `CLUSTER_NAME` environment variable to engine scripts. The `^chart-test-swarm-[a-z0-9-]+$` prefix rule is enforced by the engine scripts themselves (script-level guard), NOT by the JSON schema.

**Validation:** Every scenario YAML must pass `jsonschema` validation in CI and at runtime.

### 3.3 Assertion Runners (`engine/asserts/*.sh`)
**Responsibility:** Pluggable assertion types.

**Current types:**
- `pod_ready` — wait for pod readiness
- `http` — HTTP request with expected status/body
- `helm_test` — invoke `helm test`
- `smoke_script` — escape hatch running arbitrary user script

**Invariants:** Each assertion runner returns `{status: PASS|FAIL, detail: ...}` to the orchestrator.

### 3.4 Testgrid Python (`engine/testgrid/`)
**Responsibility:** Collect `reports/run-*/result.yaml` outputs, render HTML dashboard with matrix view.

**Modules:**
- `cli.py` — entry point: `python -m testgrid build --reports reports/ --out reports/run-X/dist/`
- `collect.py` — walks `reports/`, parses result YAMLs, aggregates into in-memory matrix.
- `render.py` — jinja2 templates → `index.html` + assets.
- `templates/` — index template, css, css-grid layout.

**Invariants:**
- `MECHANISM_CATEGORIES` includes all integration categories (certificates, ingress-controllers, gateway-api, service-mesh, policy, cloud-native).
- Custom statuses render gracefully (unknown status → grey "unknown" cell).
- Each scenario card MUST include anchor links to its artifact files.

### 3.5 Integration Primers (`engine/skills/chart-test-swarm/references/integrations/<category>/`)
**Responsibility:** Hand-authored markdown primers documenting each integration variant.

**Structure:**
- One subdir per category.
- Within each category subdir, one `.md` primer per integration (`cert-manager.md`, `nginx-ingress.md`, etc.).
- Each primer documents: what it does, when to use it, required preinstall steps, sample value overrides, gotchas.

**Invariant:** Primer paths are discoverable by walking subdirs — no central registry needed.

### 3.6 Sample Product Chart + Scenarios (`examples/sample-product-chart/`)
**Responsibility:** Reference implementation showing how a consumer wires up their chart with chart-test-swarm.

**Layout:**
- `chart/` — the Helm chart itself.
- `chart-test/fixtures/<category>/` — shared TLS, manifests, JWT keys per integration category.
- `chart-test/assertions/` — assertion config YAMLs reused across scenarios.
- `chart-test/scenarios/<category>-<integration>-<variant>.yaml` — individual scenario files (this path is fixed by the project's `chart-test-swarm.yaml` `scenarios_dir: chart-test/scenarios` setting).

### 3.7 Reports (`reports/run-<timestamp>/`)
**Responsibility:** Immutable record of one mission run.

**Required files per run:**
- `result.yaml` — outcome summary (scenarios attempted, PASS/FAIL/SKIP counts, per-scenario detail).
- `artifacts/scenario.yaml` — copy of scenario as run.
- `artifacts/applied-overrides.yaml` — final helm values dict (after merges).
- `artifacts/fixtures/` — copied fixture files used.
- `artifacts/manifests/` — output of `kubectl get -o yaml` for resources created.
- `artifacts/versions.json` — `{helm, kubectl, kind, minikube, k8s_server}` versions.

**Invariant:** A reviewer can re-apply the scenario from artifacts alone without the source tree.

### 3.8 CLI Tool (`chart-test-swarm` console script)
**Responsibility:** Single user-facing entry point that wraps engine scripts + testgrid.

**Subcommands:**
- `run <scenario|--all>` — wraps `dispatch-swarm.sh`.
- `dashboard` — wraps `build-dashboard.sh`.
- `list integrations | variants` — walks integration subdirs.
- `generate pick | author | explore` — LLM-driven generator (Milestone 10).

**Implementation:** Python (typer-based), packaged as additional console script in `engine/testgrid/pyproject.toml`.

### 3.9 LLM Generator (`chart-test-swarm generate ...`)
**Responsibility:** Author and discover novel scenario variants.

**Modes:**
- `pick` — interactive menu over (category, integration, variant) tuples; outputs scenario YAML.
- `author <description>` — LLM emits a scenario matching schema for the given description.
- `explore <chart> --integrations <list>` — LLM iteratively probes combinations, runs them via CLI `run`, reads results, proposes next combo until budget exhausted.

**LLM interface:** Subprocess shell-out to the host droid/agent CLI (configurable via `CTS_LLM_CMD` env var; default discovers `droid` binary). No direct API keys handled by chart-test-swarm.

---

## 4. Data Flow

### 4.1 Local Run Flow (kind/minikube)
```
user                 cli              engine.sh           cluster              testgrid
 │                    │                  │                  │                    │
 │─run my.yaml──────▶│                  │                  │                    │
 │                    │─dispatch.sh────▶│                  │                    │
 │                    │                  │─cluster-up──────▶│ (kind boot)        │
 │                    │                  │─apply-scenario─▶│ (helm + raw_mfst) │
 │                    │                  │─run-asserts────▶│                    │
 │                    │                  │◀──results───────│                    │
 │                    │                  │─cluster-down───▶│ (teardown)         │
 │                    │                  │─write result+artifacts──────────────▶│
 │                    │─build-dashboard─────────────────────────────────────────▶│
 │◀──dashboard URL────│                                                          │ (renders HTML)
```

### 4.2 Cloud-Native Flow (Milestone 8 — authored only)
```
user                 cli              engine.sh
 │                    │                  │
 │─list cloud-native─▶│                  │
 │◀──gke/eks/aks──────│                  │
 │                    │                  │
 │─generate author────▶│ (LLM writes)    │
 │◀──scenario.yaml────│                  │
 │                    │                  │
 │ (user ships YAML to their own GKE cluster — out of repo scope)
```

### 4.3 Explore Flow (Milestone 10)
```
user                 cli              engine.sh            LLM (droid CLI)
 │                    │                  │                     │
 │─generate explore──▶│                  │                     │
 │                    │─propose combo───────────────────────▶│
 │                    │◀──scenario YAML─────────────────────│
 │                    │─run.sh──────────▶│                     │
 │                    │◀──result.yaml───│                     │
 │                    │─feed result─────────────────────────▶│
 │                    │◀──next combo or DONE────────────────│
 │ (loop until budget exhausted)
 │◀──summary report──│                  │                     │
```

---

## 5. Key Invariants

These invariants hold across the entire system. Worker violations of these are mission-blocking:

1. **Cluster prefix:** Any cluster operation MUST verify the cluster name starts with `chart-test-swarm-` before proceeding.
2. **Schema validity:** Every scenario file MUST validate against `engine/templates/scenario.schema.json` before being run.
3. **Artifact completeness:** Every successful run MUST produce `artifacts/scenario.yaml`, `artifacts/applied-overrides.yaml`, `artifacts/versions.json` at minimum.
4. **Dashboard determinism:** Re-rendering the dashboard against the same `reports/` directory MUST produce byte-identical output (except for absolute timestamps embedded in render).
5. **No orphan processes:** After any script exits (success or fail), `docker ps` MUST NOT show stranded chart-test-swarm-* containers and `kind get clusters` / `minikube profile list` MUST NOT contain chart-test-swarm-* entries.
6. **Cloud-native discipline:** No `kubectl --context` pointing at a non-local cluster from any script in this repo.
7. **Versions captured:** Every run records exact tool versions in `artifacts/versions.json` for reproducibility.

---

## 6. Component Interaction Boundaries

| From             | To                  | Mechanism                              |
| ---------------- | ------------------- | -------------------------------------- |
| CLI              | engine scripts      | Subprocess + env vars                  |
| CLI              | testgrid python    | In-process function call               |
| Engine scripts   | kind/minikube       | `kind ...` / `minikube ...` CLI        |
| Engine scripts   | k8s cluster         | `kubectl` + `helm`                     |
| Engine scripts   | reports/            | Direct file writes                     |
| Testgrid python  | reports/            | Read-only filesystem walk              |
| Testgrid python  | dashboard HTML      | jinja2 render → file write             |
| LLM generator    | host droid CLI      | Subprocess shell-out                   |
| LLM generator    | CLI run subcommand  | In-process function call               |

---

## 7. Milestone-to-Component Mapping

| Milestone               | Primary components touched                                       |
| ----------------------- | ---------------------------------------------------------------- |
| 1 engine-foundations    | engine/scripts, engine/templates, engine/skills/.../integrations (reorg), reports artifact contract, test harness |
| 2 dashboard-uplift      | engine/testgrid, dashboard templates                             |
| 3 certificates          | integrations/certificates/, examples/sample-product-chart/chart-test/fixtures/certificates/, scenarios |
| 4 ingress-controllers   | integrations/ingress-controllers/, scenarios                     |
| 5 gateway-api-variants  | integrations/gateway-api/, scenarios                             |
| 6 service-mesh          | integrations/service-mesh/, scenarios                            |
| 7 policy-engines        | integrations/policy/, scenarios                                  |
| 8 cloud-native-primers  | integrations/cloud-native/, AUTHORED-ONLY scenarios              |
| 9 cli-tool              | engine/testgrid (new CLI module + console script entry)          |
| 10 llm-generator        | engine/testgrid generate subcommand, host droid CLI integration  |

---

## 8. Risk Hot-Spots (Where Workers Need Extra Care)

These are coupling points from the earlier engine-investigation subagent report. Workers in affected milestones must read this section.

1. **Hardcoded kind backends** — `cluster-up.sh` and `cluster-down.sh` have 2 hardcoded `kind`/`k3d` branches. F1.1 must extend these idempotently.
2. **Helm-only apply** — `apply-scenario.sh` only handles `kind: helm` preinstall items. F1.2 adds `raw_manifest` support.
3. **Schema `additionalProperties: false`** — currently blocks any non-helm preinstall item. F1.2 must relax this carefully (one approach: per-kind sub-schemas via `oneOf`).
4. **Dispatch swarm snapshot** — `dispatch-swarm.sh` drops `product` + `asserts` from the snapshot it writes; reports artifact contract (F1.4) must restore this.
5. **Build-dashboard.sh** exits 1 on single-scenario `scenario-*` outputs. Testgrid only enumerates `run-*` dirs. Documented caveat; not a regression but workers must not rely on `scenario-*` shape.
6. **Envoy-gateway primer** — references defunct classic repo. F1.2 must update to `oci://docker.io/envoyproxy/gateway-helm`.
7. **mypy missing stubs** — needs `types-PyYAML` + jinja2 stubs. F1.5 must add these as dev deps.
8. **Yamllint/shellcheck style errors** — 57 + 7 existing errors on tracked files. Workers must fix these in milestones touching those files (clean as you go).
9. **Reports schema drift** — Run-1 (minimal) vs Run-2 (rich) snapshots have different shapes. F1.4 + F2.4 must accept both for backward compatibility; new runs use the rich shape.
10. **Examples/fixtures/assertions empty** — `examples/sample-product-chart/chart-test/fixtures/` and `chart-test/assertions/` are empty dirs. F3.4 populates them.
11. **5 scenarios use inline `product.set`** — workers extending these must preserve inline style unless the new fixture system supersedes it.

---

## 9. Open Architectural Decisions (To Be Pinned During Implementation)

The following decisions are deferred to the workers in the relevant milestones but must be documented in the related primer / commit message when made:

- **D1** (F1.2): Schema shape for `raw_manifest` preinstall — flat `kind+path` or nested under `manifest:` key. Recommendation: flat for consistency with helm.
- **D2** (F2.1): Artifact link target — anchor to file:// URL vs embedded base64. Recommendation: file:// (smaller HTML, easier to grep).
- **D3** (F9.1): CLI library choice — `typer` vs `click`. Recommendation: `typer` (already in modern Python ecosystem; integrates with pydantic).
- **D4** (F10.2): LLM provider abstraction — `subprocess + droid` vs `subprocess + agent` vs both. Recommendation: env-var `CTS_LLM_CMD` resolves to user's preferred CLI; default discovers `droid`.

Workers MUST NOT introduce new architectural decisions of similar scope without orchestrator approval.
