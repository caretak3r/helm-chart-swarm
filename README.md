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
    └── assertions/*.sh                 ├── skills/     (integration primers)
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
| `sweep-scenarios.sh` | Run a parameter sweep over scenario variants |
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
| Ingress controllers | traefik, nginx-ingress, contour |
| Gateway API | envoy-gateway, istio-gateway-api, contour-gateway-api |
| Service mesh | istio-service-mesh, istio-ingress-gateway, linkerd |
| Policy | opa-gatekeeper, kyverno |
| Capability compliance | labels-present, annotations-present, scheme-enforced, rbac-objects, security-context, network-policy, resources-present, imagepullsecrets-present, serviceaccount-annotations, scheduling-present, priority-class-present |

All assertions use the `RAW_`+`grep -oE` pattern for `kubectl v1.36`
compatibility. TLS fixtures use `REPLACE_AT_RUNTIME` placeholders with
runtime certificate generation.

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

## Version Management

`engine/defaults/versions.yaml` + `engine/testgrid/src/testgrid/versions.py`:

- Engine-level defaults with project-level overrides
- 5 sections: kubernetes, cli_tools, preinstalls, product, cloud
- Deep merge (project values win over engine defaults)
- JSON schema validation
- Edit from dashboard writes to project file only
- Version history logging

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
| `dashboard` | Build and serve dashboard with `--reports-dir`, `--project-dir`, `--watch`, `--interval`, `--serve`, `--port`; pages: Home, Support Matrix, Run History, Run Detail, Recommendations, Versions |
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
scenario YAMLs across 8 category subdirectories: capability/,
certificates/, cloud-native/, gateway-api/, networking/, policy/,
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
uv run --directory engine/testgrid mypy src/testgrid

# Python linting
uv run --directory engine/testgrid ruff check src/testgrid

# Shell linting
shellcheck engine/scripts/*.sh engine/asserts/*.sh

# Chart linting
helm lint examples/sample-product-chart/chart
```

Test suite: ~342 bats tests, ~890+ pytest tests, mypy --strict, ruff,
shellcheck, yamllint, helm lint.

## Layout

| Path | Role |
|------|------|
| `engine/scripts/` | swarm engine (cluster lifecycle, scenario runner, dispatch, dashboard, benchmark) |
| `engine/asserts/` | 60+ built-in assertion scripts by integration category |
| `engine/templates/` | scenario JSON Schema, agent-brief template, CI workflow templates |
| `engine/skills/` | integration primers and reference documentation |
| `engine/testgrid/` | dashboard (Python + Jinja2 + Typer), catalog, support-matrix renderer |
| `examples/sample-product-chart/` | working consumer chart used for framework dogfood + CI |
| `docs/` | scenario authoring, CI integration, customer-scenario playbook |
