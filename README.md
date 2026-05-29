# chart-test-swarm

Generic swarm-test framework for product Helm charts. Validates a chart
against many customer-shaped cluster scenarios (preinstalled addons like
gatekeeper / cert-manager / istio, subchart combinations, cluster
flavors) on every PR / nightly / customer-filed regression.

Pattern lifted from the HIP-0025 swarm harness, generalized so any
product chart can plug in.

## Status

**MVP (Phase 1)** — kind/k3d only, functional pass/fail only. Cloud
providers (EKS/GKE/AKS), timing metrics, and compatibility assertions
are explicit Phase-2 work.

## How it works

```
consumer chart repo                 chart-test-swarm engine
└── chart-test/                     └── engine/
    ├── chart-test-swarm.yaml  ──▶      ├── scripts/    (run-scenario, dispatch, aggregate)
    ├── scenarios/*.yaml                ├── asserts/    (pods-ready, service-reachable, ...)
    ├── fixtures/*.yaml                 ├── templates/  (agent-brief, scenario schema, CI)
    └── assertions/*.sh                 └── testgrid/   (dashboard)
```

A **scenario** is one YAML file declaring: cluster shape + preinstalled
addons + product chart values + assertions + suite tags. Scenarios live
in the consumer chart repo, versioned with the chart they protect.

A **suite** is a tag filter (`pr-subset`, `nightly`, `customer-replica`)
mapping to a trigger (manual, GH Actions PR, GH Actions nightly).

## Quickstart

```bash
make verify                                  # preflight: kind/k3d, kubectl, helm, yq
make scenario SCENARIO=examples/sample-product-chart/chart-test/scenarios/minimal.yaml
make swarm SUITE=pr-subset PROJECT=examples/sample-product-chart
```

## Layout

| Path | Role |
|------|------|
| `engine/scripts/` | swarm engine (cluster lifecycle, scenario runner, dispatch, aggregate) |
| `engine/asserts/` | built-in assertion types invoked by `run-scenario.sh` |
| `engine/templates/` | scenario JSON Schema, agent-brief template, CI workflow templates |
| `engine/testgrid/` | dashboard (Python + Jinja, fork of hip-0025/testgrid) |
| `examples/sample-product-chart/` | working consumer chart used for framework dogfood + CI |
| `docs/` | scenario authoring, CI integration, customer-scenario playbook |

See `docs/scenario-authoring.md` to write your first scenario.

## Design plan

Full plan at `/Users/rohit/.claude/plans/looking-at-the-setup-tranquil-feigenbaum.md`.
