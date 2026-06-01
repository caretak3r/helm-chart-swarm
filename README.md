# chart-test-swarm

Swarm-test framework for product Helm charts. Validates a chart against
many customer-shaped cluster scenarios (preinstalled addons like
gatekeeper / cert-manager / istio, subchart combinations, cluster
flavors) on every PR / nightly / customer-filed regression.

Pattern lifted from the HIP-0025 swarm harness, generalized so any
product chart can plug in.

## How it works

```
consumer chart repo                 chart-test-swarm engine
└── chart-test/                     └── engine/
    ├── chart-test-swarm.yaml  ──▶      ├── scripts/    (cluster lifecycle, scenario runner, dispatch, dashboard, benchmark)
    ├── scenarios/*.yaml                ├── asserts/    (50+ assertion scripts)
    ├── fixtures/*.yaml                 ├── templates/  (scenario schema, agent-brief, CI)
    └── assertions/*.sh                 ├── skills/     (integration primers)
                                         └── testgrid/   (dashboard)
```

A **scenario** is one YAML file declaring: cluster shape + preinstalled
addons + product chart values + assertions + suite tags. Scenarios live
in the consumer chart repo, versioned with the chart they protect.

A **suite** is a tag filter (`pr-subset`, `nightly`, `customer-replica`)
mapping to a trigger (manual, GH Actions PR, GH Actions nightly).

## Engine

`engine/scripts/` provides the full swarm lifecycle:

| Script | Purpose |
|--------|---------|
| `cluster-up.sh` | Create a cluster (kind or minikube) with `chart-test-swarm-*` name prefix enforcement |
| `cluster-down.sh` | Idempotent teardown -- safe to re-run on already-removed clusters |
| `apply-scenario.sh` | Apply a single scenario to a live cluster |
| `run-scenario.sh` | Execute scenario + assertions, produce artifact bundle |
| `dispatch-swarm.sh` | Fan out scenarios in parallel |
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

`engine/asserts/` contains 50+ assertion scripts organized by
integration category:

| Category | Assertions |
|----------|-----------|
| Certificates | cert-manager, manual-tls, mounted-tls |
| Ingress controllers | traefik, nginx-ingress, contour |
| Gateway API | envoy-gateway, istio-gateway-api, contour-gateway-api |
| Service mesh | istio-service-mesh, istio-ingress-gateway, linkerd |
| Policy | opa-gatekeeper, kyverno |

All assertions use the `RAW_`+`grep -oE` pattern for `kubectl v1.36`
compatibility. TLS fixtures use `REPLACE_AT_RUNTIME` placeholders with
runtime certificate generation.

## Dashboard

`engine/testgrid/` -- Python (Jinja2 + Typer) static HTML dashboard:

- Variant grouping across scenario runs
- Status breakdown (pass / fail / skipped / interrupted)
- Artifact links per scenario
- Cloud-native AUTHORED ONLY badges
- XSS-safe rendering (auto-escaping)
- Deterministic rebuilds (content-hash keyed)
- Multi-run aggregation

## CLI

`chart-test-swarm` Typer-based CLI with subcommands:

| Command | Description |
|---------|-------------|
| `run` | Dispatch scenarios with `--scenario`, `--integration`, `--backend`, `--parallelism`, `--cluster-name`, `--reports-dir`, `--include-cloud-native` |
| `dashboard` | Build dashboard with `--reports-dir`, `--project-dir`, `--watch`, `--interval` |
| `list integrations` | Discover available integration primers |
| `list variants` | Discover available scenarios |
| `generate pick` | Non-interactive scenario selector (`--category`, `--integration`) |
| `generate author` | LLM-driven scenario authoring (requires `CTS_LLM_CMD`) |
| `generate explore` | Iterative LLM exploration loop |

## Sample chart

`examples/sample-product-chart/` is a 3-tier "stellarium" observatory
chart (skywatcher / scope / darkroom) with feature flags for ingress,
gateway route, mesh injection, and policy compliance labels. Used for
framework dogfood and CI.

`examples/sample-product-chart/chart-test/scenarios/` contains 50+
scenario YAMLs across 8 integration categories: certificates,
ingress-controllers, gateway-api, service-mesh, policy, and cloud-native
(authored-only GKE / EKS / AKS). All scenarios validate against
`engine/templates/scenario.schema.json`.

## Integration primers

`engine/skills/chart-test-swarm/references/integrations/` provides
reference documentation organized by category:

```
references/integrations/
├── certificates/
├── ingress-controllers/
├── gateway-api/
├── service-mesh/
├── policy/
└── cloud-native/
```

Each primer covers: What / When / How / Cluster preinstall / Variants /
Assertions / Known gotchas.

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

Test suite: 173+ bats tests, 458+ pytest tests, mypy --strict, ruff,
shellcheck, yamllint, helm lint.

## Layout

| Path | Role |
|------|------|
| `engine/scripts/` | swarm engine (cluster lifecycle, scenario runner, dispatch, dashboard, benchmark) |
| `engine/asserts/` | 50+ built-in assertion scripts by integration category |
| `engine/templates/` | scenario JSON Schema, agent-brief template, CI workflow templates |
| `engine/skills/` | integration primers and reference documentation |
| `engine/testgrid/` | dashboard (Python + Jinja2 + Typer) |
| `examples/sample-product-chart/` | working consumer chart used for framework dogfood + CI |
| `docs/` | scenario authoring, CI integration, customer-scenario playbook |
