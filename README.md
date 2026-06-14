# chart-test-swarm

Swarm-test framework for product Helm charts. Validates a chart against
many customer-shaped cluster scenarios (preinstalled addons like
gatekeeper / cert-manager / istio, subchart combinations, cluster
flavors) on every PR / nightly / customer-regression.

Pattern lifted from the HIP-0025 swarm harness, generalized so any
product chart can plug in.

## How it works

```
consumer chart repo                 chart-test-swarm engine
└── chart-test/                     └── engine/
    ├── chart-test-swarm.yaml  ──▶      ├── scripts/    (cluster lifecycle, scenario runner, dispatch, dashboard, benchmark)
    ├── scenarios/*.yaml                ├── asserts/    (60+ assertion scripts)
    ├── fixtures/*.yaml                 ├── templates/  (scenario schema, agent-brief, CI)
    └── assertions/*.sh                 ├── skills/     (integration primers + /helm-swarm-test)
                                         └── testgrid/   (dashboard, catalog, support matrix)
```

A **scenario** is one YAML file declaring: cluster shape + preinstalled
addons + product chart values + assertions + suite tags. Scenarios live
in the consumer chart repo, versioned with the chart they protect.

A **suite** is a tag filter (`pr-subset`, `nightly`, `customer-replica`,
`curated-live`) mapping to a trigger (manual, GH Actions PR, GH Actions
nightly). The **curated-live suite** defines the agreed set of live
integration + capability + gap-probe scenarios for end-to-end validation.

## Engine

`engine/scripts/` provides the full swarm lifecycle:

| Script | Purpose |
|--------|---------|
| `cluster-up.sh` | Create a cluster (kind or minikube) with `chart-test-swarm-*` name prefix enforcement |
| `cluster-down.sh` | Idempotent teardown -- safe to re-run on already-removed clusters |
| `apply-scenario.sh` | Apply a single scenario to a live cluster |
| `run-scenario.sh` | Execute scenario + assertions, produce artifact bundle |
| `dispatch-swarm.sh` | Fan out scenarios in parallel; `--run` for sequential execution, `--dry-run` for preview, `--include-cloud-native` / `CTS_INCLUDE_CLOUD_NATIVE` for opt-in cloud scenario dispatch |
| `build-dashboard.sh` | Generate the static HTML dashboard |
| `aggregate.sh` | Merge results across multiple runs |
| `benchmark-scenarios.sh` | Per-feature regression tracking |
| `sweep-scenarios.sh` | Run a parameter sweep over scenario variants; also enforces JSON-schema validation **and** assertion-depth consistency (every referenced assert type must have a declared depth in the registry and a matching `# DEPTH: Lx` script header) |
| `orphan-audit.sh` | Detect leaked clusters and artifacts |

Artifact bundles include `scenario.yaml`, `applied-overrides.yaml`,
`fixtures/`, `manifests/`, and `versions.json`. Scenarios that receive
SIGINT record `INTERRUPTED` status rather than leaving a stale `RUNNING`
entry. Both raw manifest and Helm-based preinstall are supported.

## Assertions

`engine/asserts/` contains 60+ assertion scripts organized by
integration category:

| Category | Assertions |
|----------|-----------|
| Certificates | cert-manager, manual-tls, mounted-tls |
| CNI | cilium-ebpf, cilium-ingress, cilium-network-policy |
| Ingress controllers | traefik, nginx-ingress, contour |
| Gateway API | envoy-gateway, istio-gateway-api, contour-gateway-api |
| Service mesh | istio-service-mesh, istio-ingress-gateway, linkerd |
| Policy | opa-gatekeeper, kyverno |
| Capability compliance | labels-present, annotations-present, scheme-enforced, rbac-objects, security-context, network-policy, resources-present, imagepullsecrets-present, serviceaccount-annotations, scheduling-present, priority-class-present, probes-present, volume-mounts-present, pdb-present, hpa-present, init-containers, host-network, lifecycle-hooks, dns-config |
| Behavioral (L3) | network-policy-enforced, mesh-mtls-enforced, tls-cert-valid, ingress-routes-traffic, gateway-routes-traffic, policy-denies-violation, rbac-effective, scheduled-on-target |

All assertions use the `RAW_`+`grep -oE` pattern for `kubectl v1.36`
compatibility. TLS fixtures use `REPLACE_AT_RUNTIME` placeholders with
runtime certificate generation.

### Assertion depth taxonomy (L0–L3)

Every engine assert is classified by depth in `engine/asserts/registry.yaml`,
which maps each assert `type` to a level:

| Depth | Meaning |
|-------|---------|
| L0 | Render-only / static analysis of `helm template` output, or engine-delegates-to-consumer (e.g. `smoke-script`); no live cluster needed |
| L1 | Presence / static-live: queries the live Kubernetes API for object presence, without checking behavioral semantics |
| L2 | Readiness / exec: validates objects are in their intended operational state (readiness, connectivity, process execution) |
| L3 | Behavioral / traffic / enforcement: exercises real traffic and proves actual behavior beyond mere presence |

Each assert script carries a `# DEPTH: Lx` header that **must** match its
registry entry. `engine/scripts/sweep-scenarios.sh` enforces this
header/registry consistency (and blocks scenarios that reference an
assert type with no declared depth) alongside JSON-schema validation.

### Behavioral (L3) assertions

L3 asserts *prove* behavior rather than just presence. They are
env-var parameterized (no hardcoded consumer names) and **SKIP** (a
non-failing status) when the required platform capability is genuinely
absent:

- `network-policy-enforced` — denied traffic is actually blocked while the allowed path still works
- `mesh-mtls-enforced` — STRICT mTLS is negotiated and plaintext is rejected (verified via Envoy / ztunnel / pilot-agent evidence)
- `tls-cert-valid` — a real certificate is served, valid, with SAN matching the host
- `ingress-routes-traffic` — a request through the Ingress returns the expected response (fails on 503/404)
- `gateway-routes-traffic` — a Gateway API route serves traffic through the data plane
- `policy-denies-violation` — the admission policy actually denies a violating object and admits a compliant one
- `rbac-effective` — `kubectl auth can-i` confirms permissions are granted **and** bounded (an out-of-scope action returns "no")
- `scheduled-on-target` — pods actually land on the targeted node

### New capability (config) assertions

These follow the capability-assert shape (`namespace` + `expect_present`
+ `source` + type-specific knobs) with positive **and** negative
coverage:

- `probes-present` (L1 + L2 live Ready)
- `volume-mounts-present` (L1 + L2 exec/stat the mountPath; enforces mounts have matching backing volumes)
- `pdb-present` (L1; Kubernetes selector semantics)
- `hpa-present` (L1, optional L2; verifies `scaleTargetRef` points at a release workload with exact match + min/max replicas)
- `init-containers`, `host-network` (hostNetwork / hostPort), `lifecycle-hooks` (preStop/postStart), `dns-config` (dnsPolicy/dnsConfig)

Capability detection for standard Ingress, NetworkPolicy, and
ValidatingAdmissionPolicy uses `kubectl api-resources` / API-group
lookups (these are built-in API resources, **not** CRDs), avoiding false
SKIPs from a `kubectl get crd` check.

### Structured assertion output contract

Asserts may print `ASSERTION_RESULT: PASS|FAIL|SKIP` and an optional
`ASSERTION_DETAIL: <single-line JSON>` on their own lines.
`run-scenario.sh` uses the **last** `ASSERTION_RESULT:` line
(line-prefix match, whitespace-tolerant); when absent it falls back to
exit-code semantics (0 = PASS, non-zero = FAIL). `result.yaml` now
additively records `depth_level` per assert plus an optional detail
block — all changes are backward-compatible.

**SKIP is a first-class, non-failing status.** It flows end-to-end:
`run-scenario.sh` (a SKIP does not fail the scenario; a FAIL still
dominates a PASS/SKIP/FAIL mix), `dispatch-swarm.sh` (tallies SKIP
distinctly from INTERRUPTED), and the Python collector
`engine/testgrid/src/testgrid/collect.py` (SKIP is a known status,
never normalized to UNKNOWN, and preserved in `status_counts`).

### Consumer pluggability

Engine asserts and the depth registry are extensible per consumer
project, with the consumer winning on conflict:

- **Assert resolver** — a project's `chart-test/asserts/<type>.sh` (if present and executable) overrides the engine assert; consumer-only NEW types resolve and run; engine asserts are the fallback
- **Registry layering** — a project `chart-test/asserts/registry.yaml` layers over the engine registry, and sweep depth enforcement consults the merged registry
- **Lint gate** — `engine/scripts/check-custom-assertions.sh` (wired into the `verify.sh` lint gate, fail-closed) validates consumer asserts: executable bit, valid `# DEPTH:` header, type declared in a registry, and header depth matching the registry
- **Primer/template layering** — consumer-provided primers layer over engine defaults in the CLI (`new_cmd.py`), with the consumer winning

## Dashboard

`engine/testgrid/` -- Python (Jinja2 + Typer) static HTML dashboard
served via `chart-test-swarm dashboard`. Consistent top nav bar on all
pages (Home, Matrix, Runs, Recommendations, Versions).

**Home page** — navigation cards for Support Matrix, Run History,
Recommendations, and Versions, each showing summary metrics (total
runs, pass/fail counts, open recommendations, version counts).

**Support Matrix page** — capability-keyed coverage grid across cluster
types. AUTHORIZED badges for cloud-authored entries
(EKS/AKS/GKE tier=authored-only scenarios appear as AUTHORED, excluded
from pass/fail totals; never applied to real cloud from this repo).

**Run History page** — lists all test runs with links to detail pages.

**Run Detail pages** — per-run view with scenario results and version
info.

**Recommendations page** — tabbed view (All / Open / In Progress /
Fixed / Dismissed) with cards showing status badges, category and
severity tags, FIX and Dismiss buttons, and category/severity filters.

**Versions page** — merged view of engine defaults + project overrides
across 5 sections: kubernetes, cli_tools, preinstalls, product, cloud.
Edits from the dashboard write to the project file only; version history
is logged.

General dashboard features:

- Variant grouping across scenario runs
- Status breakdown (pass / fail / skipped / interrupted)
- Artifact links per scenario
- XSS-safe rendering (auto-escaping)
- Deterministic rebuilds (content-hash keyed)
- Multi-run aggregation
- Live `--watch` mode with automatic rebuilds
- `--serve` flag for HTTP serving
- Curated-live suite support

## Recommendations Engine

`engine/testgrid/src/testgrid/recommendations.py` scans FAIL results
from test runs and:

- Auto-classifies failures into categories: chart-fix, infrastructure,
  gap-probe, schema-missing
- Assigns severity (high / medium / low)
- Deduplicates across runs
- Generates fix prompts for LLM-driven chart fixes
- Persists to `reports/recommendations.json`

## Fix Workflow

`chart-test-swarm fix <rec-id>` drives LLM-powered chart fixes:

1. Reads `.fix-prompt.json` for the recommendation
2. Invokes `CTS_LLM_CMD` with the fix prompt
3. Applies LLM-suggested changes to the chart (with path traversal
   protection)
4. Re-runs the scenario on a kind cluster
5. Updates recommendation status (fixed / open)
6. Appends history to `history.json`
7. Rebuilds the dashboard

## Agentic Test Loop

`chart-test-swarm test` runs the entire lifecycle against **any** chart
as a single command, reusing the engine scripts, recommendations
engine, fix workflow, and dashboard builder:

1. `verify` preflight — aborts (non-zero, no cluster) if it fails
2. `cluster-up` once with a validated `chart-test-swarm-*` cluster name
3. Discover scenarios (filtered by `--suite`, or all)
4. Run each scenario in catalog order; a FAIL never aborts the matrix
5. For each FAIL (unless `--no-fix`): a bounded fix sub-loop
   (`--max-fix-attempts`) drives `CTS_LLM_CMD` to apply a
   chart-directory-only edit, then re-runs that scenario
6. Progressive dashboard rebuilds every `--rebuild-interval` scenarios,
   plus a final rebuild
7. Prints a summary (total / pass / fail / fixed / open / dashboard path)
8. Tears the cluster down in a `finally` block (unless `--keep-cluster`),
   so it cleans up on success, error, or interruption

`--no-fix` guarantees zero `CTS_LLM_CMD` invocations (report-only).

### `/helm-swarm-test` skill

`engine/skills/helm-swarm-test/` is a portable, LLM-agnostic skill
(`SKILL.md` + `command.md`) that wraps `chart-test-swarm test` for any
agentic harness (Droid, Claude Code, opencode, gemini). It is
chart-agnostic — the target chart is resolved via `chart-test-swarm.yaml`
/ `--project-dir` / `PROJECT_DIR` — and documents two modes:

- **Interactive (agent-as-LLM):** run `chart-test-swarm test --no-fix
  --keep-cluster`, then the agent reads each open chart-fix
  recommendation, applies a chart-directory-only edit with its own file
  tools, re-runs the scenario, and rebuilds the dashboard.
- **Headless / CI:** set `CTS_LLM_CMD` to a non-interactive agent
  invocation and run `chart-test-swarm test` so the CLI auto-fixes with
  no human in the loop.

`command.md` is self-contained and copyable into any tool's commands
directory with no machine-specific paths.

## Version Management

`engine/defaults/versions.yaml` + `engine/testgrid/src/testgrid/versions.py`:

- Engine-level defaults with project-level overrides
- 5 sections: kubernetes, cli_tools, preinstalls, product, cloud
- Deep merge (project values win over engine defaults)
- JSON schema validation
- Edit from dashboard writes to project file only
- Version history logging

The project override
`examples/sample-product-chart/chart-test/versions.yaml` pins
`kubernetes.kind: v1.36.1`, with workload images bumped to
`nginx:1.29-alpine` and `quay.io/curl/curl:8.20.0`. Engine defaults in
`engine/defaults/versions.yaml` remain read-only.

## Catalog + Support Matrix

`engine/testgrid/` includes `catalog.py` (`generate_catalog`,
`catalog_to_yaml`) for deterministic YAML catalog generation and renders
`support-matrix.html` with a capability-keyed table showing integration
coverage across cluster types. The catalog provides a single source of
truth for which scenarios exist and which integrations they exercise.

## CLI

`chart-test-swarm` Typer-based CLI with subcommands:

| Command | Description |
|---------|-------------|
| `run` | Dispatch scenarios with `--scenario`, `--integration`, `--backend`, `--parallelism`, `--cluster-name`, `--reports-dir`, `--include-cloud-native` |
| `test` | Agentic full-matrix loop: verify → cluster-up → discover → run every scenario → auto-fix FAILs in-flight (bounded) → progressive dashboard rebuilds → summary → teardown. Flags: `--suite`, `--max-fix-attempts` (default 2), `--no-fix`, `--rebuild-interval` (default 5), `--parallelism` (default 1), `--cluster-name` (default `chart-test-swarm-default`), `--backend` (default `kind`), `--keep-cluster`, `--project-dir`, `--reports-dir` |
| `dashboard` | Build and serve dashboard with `--reports-dir`, `--project-dir`, `--watch`, `--interval`, `--serve`, `--port`; pages: Home, Getting Started, Support Matrix, Run History, Run Detail, Recommendations, Versions |
| `new <category>/<integration>` | Scaffold fixture + scenario + smoke script from templates |
| `list integrations` | Discover available integration primers |
| `list variants` | Discover available scenarios |
| `generate pick` | Non-interactive scenario selector (`--category`, `--integration`) |
| `generate author` | LLM-driven scenario authoring (requires `CTS_LLM_CMD`) |
| `generate explore` | Iterative LLM exploration loop |
| `fix <rec-id>` | Apply LLM-driven fix to a recommendation (read prompt → invoke LLM → apply change → re-run scenario → update status → rebuild dashboard) |

## Sample chart

`examples/sample-product-chart/` is a 3-tier "stellarium" observatory
chart (skywatcher / scope / darkroom) with feature flags for ingress,
gateway route, mesh injection, and policy compliance labels. Used for
framework dogfood and CI.

`examples/sample-product-chart/chart-test/scenarios/` contains 90+
scenario YAMLs across 9 category subdirectories: capability/,
certificates/, cni/, cloud-native/, gateway-api/, networking/, policy/,
service-mesh/, storage/. Cloud-native scenarios use tier=authored-only
for EKS/AKS/GKE and appear as AUTHORED on the matrix (excluded from
pass/fail totals; never applied to real cloud from this repo). All
scenarios validate against `engine/templates/scenario.schema.json`.

## Integration primers

`engine/skills/chart-test-swarm/references/integrations/` provides
reference documentation organized by category:

```
references/integrations/
├── capability/
├── certificates/
├── cni/
│   └── cilium/
├── cloud-native/
├── gateway-api/
├── ingress-controllers/
├── networking/
│   └── ingress-lb/       (AWS LB, Azure LB, GCP LB cloud-authored primers)
├── policy/
├── service-mesh/
└── storage/
    └── csi/              (AWS EBS CSI, Azure Disk/File CSI, GCP PD CSI cloud-authored primers)
```

Each primer covers: What / When / How / Credential prerequisites /
Cluster prerequisites / Variants / Assertions / Known gotchas.

## Authoring kit

`chart-test-swarm new <category>/<integration>` scaffolds a new scenario
directory with fixture YAML, scenario YAML, and smoke assertion script
from templates, so adding coverage for a new integration is a single
command.

## Quickstart

```bash
make verify                                  # preflight: kind/k3d, kubectl, helm, yq
make scenario SCENARIO=examples/sample-product-chart/chart-test/scenarios/minimal.yaml
make swarm SUITE=pr-subset PROJECT=examples/sample-product-chart
```

## CLI usage

```bash
# Run a single scenario
chart-test-swarm run --scenario <path>

# Run all scenarios for an integration
chart-test-swarm run --integration <name>

# Run all local scenarios on kind
chart-test-swarm run --all --backend kind

# Agentic full-matrix loop against any chart (verify → up → run → fix → dashboard → teardown)
chart-test-swarm test --project-dir examples/sample-product-chart --suite pr-subset

# Report-only matrix run, keep the cluster up for inspection
chart-test-swarm test --no-fix --keep-cluster

# Build and watch dashboard (rebuilds every 30s)
chart-test-swarm dashboard --watch --interval 30

# Serve dashboard on port 8080
chart-test-swarm dashboard --serve --port 8080

# Apply LLM-driven fix to a recommendation
chart-test-swarm fix <rec-id>

# Scaffold a new scenario
chart-test-swarm new policy/kyverno

# List available integration primers
chart-test-swarm list integrations

# Non-interactive scenario selection
chart-test-swarm generate pick --category certificates --integration cert-manager
```

## Build and test

```bash
# Install Python dependencies
uv sync --directory engine/testgrid

# Shell tests (bats)
bats engine/scripts/tests engine/asserts/tests

# Python tests (pytest)
uv run --directory engine/testgrid pytest -n 2

# Type checking
uv run --directory engine/testgrid mypy src/testgrid src/chart_test_swarm

# Python linting
uv run --directory engine/testgrid ruff check src/testgrid src/chart_test_swarm

# Shell linting
shellcheck engine/scripts/*.sh engine/asserts/*.sh

# Chart linting
helm lint examples/sample-product-chart/chart
```

Test suite: ~390 bats tests, ~985 pytest tests, mypy --strict, ruff,
shellcheck, yamllint, helm lint.

## Layout

| Path | Role |
|------|------|
| `engine/scripts/` | swarm engine (cluster lifecycle, scenario runner, dispatch, dashboard, benchmark) |
| `engine/asserts/` | 60+ built-in assertion scripts by integration category |
| `engine/templates/` | scenario JSON Schema, agent-brief template, CI workflow templates |
| `engine/skills/` | integration primers, reference docs, and the portable `/helm-swarm-test` skill |
| `engine/testgrid/` | dashboard (Python + Jinja2 + Typer), catalog, support-matrix renderer |
| `examples/sample-product-chart/` | working consumer chart used for framework dogfood + CI |
| `docs/` | scenario authoring, CI integration, customer-scenario playbook |
