# Authoring scenarios

A **scenario** is one YAML file describing a customer-shaped cluster, the
product chart deployed into it, and the assertions that define "this
worked." Scenarios live in your chart repo under
`chart-test/scenarios/` and are versioned with the chart.

## Anatomy

```yaml
id: customer-A-istio                          # stable kebab-case identifier
name: "Customer A — Istio mesh + cert-manager"
description: "Customer A's profile: istio sidecar injection, …"
labels: { customer: A, mesh: istio }

cluster:
  provider: kind                              # kind | k3d  (cloud providers: Phase 2)
  k8s_version: v1.30.0
  config: chart-test/fixtures/kind-istio.yaml # optional --config for the provider
  preinstall:                                 # ordered list, applied before product chart
    - chart:     jetstack/cert-manager
      version:   v1.14.0
      release:   cert-manager
      namespace: cert-manager
      repo: { name: jetstack, url: "https://charts.jetstack.io" }
      values:    { installCRDs: true }
      wait:      pods-ready                   # none | helm-deployed | pods-ready
    - chart:     istio/base
      version:   1.21.0
      release:   istio-base
      namespace: istio-system
      repo: { name: istio, url: "https://istio-release.storage.googleapis.com/charts" }
      wait:      helm-deployed

product:
  chart:     ./chart                          # path (project-relative) or oci://… ref
  release:   my-product
  namespace: my-product
  values:    chart-test/fixtures/customer-A-values.yaml
  set:                                        # --set overrides on top of values
    image.tag: "v1.2.3"
  subcharts:                                  # informational; surfaces in dashboard rollup
    postgres: internal

asserts:                                      # at least one required
  - { type: helm-status-deployed, release: my-product, namespace: my-product }
  - { type: pods-ready,           namespace: my-product, timeout: 5m }
  - { type: service-reachable,    service: my-product-api.my-product, port: 8080, path: /healthz }
  - { type: smoke-script,         path: chart-test/assertions/upgrade-survives.sh }

tags: [nightly, customer-replica]             # which suites this scenario joins
mechanisms:                                   # rollup labels for the dashboard
  - addon:istio
  - addon:cert-manager
  - customer:A
```

## Path resolution

Every path field — `cluster.config`, `cluster.preinstall[].values` (if a
string), `product.chart`, `product.values`, `asserts[].path` — is
resolved relative to the **project root** (the directory containing
`chart-test-swarm.yaml`). The engine walks up from the scenario file
to find it.

## Built-in assertion types

| Type | Fields | Passes when |
|------|--------|-------------|
| `pods-ready` | `namespace`, `selector?`, `timeout` | `kubectl wait --for=condition=Ready` succeeds |
| `service-reachable` | `service` (`name.ns`), `port`, `path`, `expect`, `timeout` | HTTP GET from an ephemeral curl pod returns expected status |
| `helm-status-deployed` | `release`, `namespace` | `helm status -o json` reports `info.status = deployed` |
| `smoke-script` | `path` | Script exits 0. Receives `RELEASE`, `NAMESPACE`, `KUBECONFIG`, `PROJECT_DIR` env |

For anything more, write a `smoke-script` that calls `kubectl` /
`helm` / your own probes directly.

## Mechanism vocabulary

Free-form tags grouped by category prefix. The dashboard rolls up by
category. Use these conventions:

| Category | Examples | Meaning |
|----------|----------|---------|
| `addon:`     | `addon:istio`, `addon:cert-manager`, `addon:gatekeeper` | Preinstalled cluster addon present |
| `subchart:`  | `subchart:postgres-internal`, `subchart:redis-external` | Which subchart variant is exercised |
| `mesh:`      | `mesh:istio`, `mesh:linkerd`, `mesh:none` | Service mesh in play |
| `ingress:`   | `ingress:nginx`, `ingress:istio-gw`, `ingress:traefik` | Ingress controller in play |
| `customer:`  | `customer:A`, `customer:B` | Replicates a specific customer's setup |
| `cloud:`     | `cloud:eks`, `cloud:gke` | Cloud-managed K8s flavor (Phase 2) |
| `version:`   | `version:1.29`, `version:1.30` | K8s version under test |

A scenario can declare any combination. Anything that doesn't match a
known prefix falls under `other:` in the dashboard.

## Tags vs mechanisms

- **Tags** decide *which suite* a scenario joins (`pr-subset`,
  `nightly`, `customer-replica`).
- **Mechanisms** decide *how it's grouped* in the dashboard's coverage
  rollup ("is `addon:istio` PASSING anywhere?").

Most scenarios will have several of each.

## Adding a customer-reported scenario

1. Customer files an issue with cluster details (addons, versions, configs).
2. Reproduce locally: copy `chart-test/scenarios/_template.yaml`, fill in
   the customer's preinstalled addons.
3. Tag with `customer-replica` so it runs nightly. Once the fix lands and
   the scenario flips green, optionally promote to `pr-subset` so future
   PRs can't regress it.
4. The YAML file is the test case — versioned with the chart, owned by
   the team.

See [customer-scenario-playbook.md](customer-scenario-playbook.md) for
the full intake → codification flow.
