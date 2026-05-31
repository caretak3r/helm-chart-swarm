# Contour Gateway API

## What

Contour's Gateway API implementation provides a Kubernetes Gateway API
experience on top of Envoy proxy. Unlike Contour's HTTPProxy mode (covered in
the `ingress-controllers/contour.md` primer), the Gateway API mode uses the
standard Gateway API resources — GatewayClass, Gateway, HTTPRoute, GRPCRoute,
etc. — instead of the Contour-specific HTTPProxy CRD.

The GatewayClass name is `contour` and its `controllerName` is
`projectcontour.io/gateway-controller`. Match these exactly when creating
Gateway resources — a Gateway referencing any other `gatewayClassName` will
not be reconciled by the Contour Gateway Provisioner.

The Contour Gateway Provisioner is deployed as a separate Deployment
(`contour-gateway-provisioner` in the `projectcontour` namespace) that watches
for GatewayClass and Gateway resources. When a Gateway is created with
`gatewayClassName: contour`, the provisioner automatically deploys a
Contour control plane and an Envoy data plane (DaemonSet) in the Gateway's
namespace. Each Gateway gets its own Contour + Envoy pair, fully managed by
the provisioner.

## When

Use Contour Gateway API scenarios when the Helm chart under test:

- Needs to be reachable through a Gateway API HTTPRoute using the Contour
  implementation as the data plane.
- Requires response header modification via `ResponseHeaderModifier` filters
  on the HTTPRoute (Contour fully implements the `filters` specification).
- Needs to verify route precedence behavior — Contour follows the Gateway
  API spec for route matching with overlapping path prefixes,
  where more specific paths win.

**Do not use** Contour Gateway API if:

- The chart merely needs classic Ingress routing — use the Contour HTTPProxy
  primer in `ingress-controllers/contour.md` instead (it's simpler and faster).
- The chart needs TLS delegation — this is an HTTPProxy-specific feature;
  Gateway API uses `ReferenceGrant` instead.
- The chart needs JWT verification or rate limiting — these are
  HTTPProxy-specific features not yet available in Contour's Gateway API mode.

**Key difference from HTTPProxy mode:**
In HTTPProxy mode, one Contour + Envoy pair serves all namespaces. The Envoy
runs as a DaemonSet in the `projectcontour` namespace and proxies to
HTTPProxy-defined backends. In Gateway API mode, each Gateway triggers a
separate Contour + Envoy deployment managed by the provisioner. The data plane
Envoy in Gateway API mode listens on container ports 8080 (HTTP) and 8443
(HTTPS).

## How

### Consumer chart wiring

The sample product chart exposes a `gatewayRoute` value block. Set these
values to enable the chart's HTTPRoute template:

```yaml
gatewayRoute:
  enabled: true
  parentRef:
    name: sample-gw
    sectionName: http
```

When `gatewayRoute.enabled` is `true`, the chart creates an HTTPRoute resource
referencing the named Gateway parent. The chart does **not** create GatewayClass
or Gateway resources itself — those are cluster-level objects managed by the
scenario's smoke-script assertion.

### Scenario pattern

Every Contour Gateway API scenario follows this pattern:

1. **Preinstall Gateway API CRDs** (raw_manifest) — applies the upstream
   `standard-install.yaml` from `kubernetes-sigs/gateway-api` to register
   GatewayClass, Gateway, HTTPRoute, and related CRDs.

2. **Preinstall Contour Gateway Provisioner** (raw_manifest) — applies the
   upstream quickstart YAML from `projectcontour.io` which deploys the
   provisioner Deployment, RBAC, ServiceAccount, and the necessary Contour
   CRDs (ContourConfiguration, ContourDeployment).

3. **Install the product chart** with `gatewayRoute.enabled: true`.

4. **Run a smoke-script** that:
   - Creates a GatewayClass named `contour` with `controllerName:
     projectcontour.io/gateway-controller`.
   - Creates a Gateway in the product namespace with `gatewayClassName:
     contour`, a single HTTP listener on port 80, and `allowedRoutes`
     restricted to the Same namespace.
   - Creates the route resource (HTTPRoute) — either from the fixture or
     via the chart's own template if `gatewayRoute.enabled` is `true`.
   - Waits for GatewayClass `Accepted=True`, Gateway listener
     `Programmed=True`, and HTTPRoute `Accepted=True`.
   - Waits for the auto-provisioned Envoy Deployment to be Ready.
   - Probes the backend through the Envoy Service ClusterIP on port 80.
   - Exits 0 (PASS) or non-zero (FAIL) with a diagnostic message.

### Probe pattern

All Contour Gateway API scenarios use in-cluster HTTP probes targeting the
**Envoy Service ClusterIP**. After the provisioner creates a data plane for
the Gateway, an Envoy Service is created in the same namespace as the Gateway
with the label `gateway.networking.k8s.io/gateway-name=<gw-name>`. The Envoy
container listens on port 8080 for HTTP which is mapped to Service port 80.

```bash
# Inside the cluster:
GW_SVC_IP=$(kubectl -n "${NS}" get svc \
  -l gateway.networking.k8s.io/gateway-name=sample-gw \
  -o jsonpath='{.items[0].spec.clusterIP}')
curl -sf -H "Host: sample.sample.svc.cluster.local" \
  "http://${GW_SVC_IP}:80/"
```

**Important:** In Gateway API mode (dynamic provisioning), the Envoy
Service is in the SAME namespace as the Gateway (unlike the traditional
HTTPProxy mode where the Envoy Service is in `projectcontour` namespace).

## Cluster preinstall

### Gateway API CRDs (raw_manifest)

```yaml
kind: raw_manifest
path: https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```

The manifest at this URL contains all standard Gateway API CRDs from
`kubernetes-sigs/gateway-api`. The `raw_manifest` preinstall applies
these via `kubectl apply --server-side --force-conflicts` (per
`apply-scenario.sh` conventions).

### Contour Gateway Provisioner (raw_manifest)

```yaml
kind: raw_manifest
path: https://projectcontour.io/quickstart/contour-gateway-provisioner.yaml
```

This single manifest deploys:
- The `projectcontour` namespace
- Contour CRDs (ContourConfiguration, ContourDeployment,
  ExtensionService, HTTPProxy, TLSCertificateDelegation)
- Gateway API CRDs (same as standard-install.yaml; duplicate apply is
  safe with `--server-side --force-conflicts`)
- The Contour Gateway Provisioner Deployment with RBAC

After this preinstall completes, the `contour-gateway-provisioner`
deployment pod must be Ready in the `projectcontour` namespace. The
provisioner will then begin watching for GatewayClass and Gateway
resources.

## Variants

Three scenario variants are available under
`examples/sample-product-chart/chart-test/scenarios/`:

| Variant | File | Key behavior |
|---|---|---|
| basic | `gateway-api-contour-gateway-api-basic.yaml` | GatewayClass `contour` Accepted=True; Gateway Programmed=True; HTTPRoute Accepted=True; HTTP curl returns 200 |
| response-header-modifier | `gateway-api-contour-gateway-api-response-header-modifier.yaml` | HTTPRoute `rules[0].filters[]` includes `ResponseHeaderModifier` adding `X-Powered-By: chart-test-swarm`; curl response includes it |
| route-precedence | `gateway-api-contour-gateway-api-route-precedence.yaml` | Two HTTPRoutes for same host with overlapping prefixes; more specific `/api/v2` wins for matching requests, less specific `/api` wins for non-overlapping paths |

The basic variant is the baseline (fastest to run). Each variant's
fixture file (GatewayClass + Gateway + HTTPRoute resources) lives under
`examples/sample-product-chart/chart-test/fixtures/gateway-api/`.

## Assertions

Every Contour Gateway API scenario uses these assertion types:

| Type | Purpose |
|---|---|
| `helm-status-deployed` | Confirm the product chart release is deployed |
| `pods-ready` | Confirm all pods in product and projectcontour namespaces are Ready |
| `smoke-script` | Apply GatewayClass + Gateway (+ routes), wait for admission/programming, probe the backend |

The smoke-script assertions live under
`examples/sample-product-chart/chart-test/assertions/` and are referenced by
`path` from the scenario. Each script receives `RELEASE`, `NAMESPACE`,
`KUBECONFIG`, `KUBE_CONTEXT`, and `PROJECT_DIR` via the environment.

## Known gotchas

- **GatewayClass must be named `contour`** — The Contour Gateway Provisioner
  only reconciles GatewayClasses whose `spec.controllerName` equals
  `projectcontour.io/gateway-controller`. The conventional GatewayClass name
  is `contour`.

- **Provisioner takes up to 3m to provision a Contour instance** — After
  creating a Gateway, the provisioner deploys Contour + Envoy in the
  Gateway's namespace. Use `kubectl wait gateway/<name>
  --for=condition=Programmed --timeout=5m`.

- **Envoy container ports are 8080/8443** — The Envoy data-plane container
  listens on port 8080 for HTTP and 8443 for HTTPS (same as HTTPProxy mode).
  The Service maps port 80 → container port 8080 and port 443 → container
  port 8443. Probes should use Service port 80 (HTTP).

- **Envoy Service is in the Gateway's namespace** — Unlike HTTPProxy mode
  (where Envoy Service is in `projectcontour`), in Gateway API dynamic
  provisioning mode, the Envoy Service is created in the same namespace as
  the Gateway. Look for it with:
  `kubectl -n <ns> get svc -l gateway.networking.k8s.io/gateway-name=<gw-name>`.

- **`Host` header is required** — HTTPRoute rules match against hostnames.
  A probe without a matching `Host` header may receive a 404. Include
  `-H "Host: <expected-host>"` in curl commands if the HTTPRoute specifies
  a `hostnames` list.

- **Provisioner YAML is large (~900KB)** — The quickstart YAML bundles
  multiple CRD families. Apply time may be ~30-60s on first install.
  Subsequent apply invocations using `--server-side --force-conflicts`
  are faster.

- **CRD ownership conflicts** — Both the Gateway API standard-install.yaml
  AND the provisioner YAML define overlapping CRDs. The
  `apply-scenario.sh` script uses `--server-side --force-conflicts` to
  safely reconcile them.

- **Data-plane warm-up** — After the Gateway listener reports
  `Programmed=True` and the HTTPRoute reports `Accepted=True`, the Envoy
  data-plane may need up to 30s before it actually accepts traffic. Use
  a retry loop (e.g., 20 attempts × 6s = 2m) when probing via curl.

- **Retry probe pattern** — For reliable in-cluster HTTP probes, use
  `kubectl run` with a retry loop and extract the raw HTTP code with
  the `grep -oE '[0-9]{3}' | tail -1` pattern to handle kubectl v1.36
  output doubling.

## References

- [Contour Gateway API docs](https://projectcontour.io/docs/main/config/gateway-api/)
- [Gateway API with Contour guide](https://projectcontour.io/docs/main/guides/gateway-api/)
- [Contour quickstart YAML](https://projectcontour.io/quickstart/)
- [Contour Helm chart](https://artifacthub.io/packages/helm/contour/contour)
- [Gateway API specification](https://gateway-api.sigs.k8s.io/)
- [Gateway API CRDs (upstream)](https://github.com/kubernetes-sigs/gateway-api/releases)
