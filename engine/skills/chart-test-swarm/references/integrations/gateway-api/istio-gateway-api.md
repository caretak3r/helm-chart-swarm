# Istio Gateway API

## What

Istio's Gateway API mode lets you configure ingress traffic using Kubernetes
Gateway API resources (GatewayClass, Gateway, HTTPRoute) instead of Istio's
classic `Gateway` and `VirtualService` CRDs. Istio acts as the Gateway API
controller — watching Gateway API resources and programming its Envoy-based
data plane accordingly.

The GatewayClass name is `istio` and its controllerName is
`istio.io/gateway-controller`. Match these exactly when creating Gateway
resources. A Gateway referencing any other `gatewayClassName` will be ignored
by Istio's controller.

When you create a Gateway resource, Istio auto-provisions a Deployment +
Service in the Gateway's namespace (similar to how the classic
`IstioOperator` or `Gateway` injection works, but driven by Gateway API
reconciliation). The auto-provisioned Deployment runs an Envoy proxy pod
that handles traffic for that Gateway. This is the key architectural
difference from the classic ingress-gateway mode: instead of a separately
managed `istio-ingressgateway` Deployment, each Gateway resource gets its
own auto-provisioned data-plane Deployment.

**Key differences from classic Istio ingress-gateway mode:**

| Aspect | Classic (Istio CRDs) | Gateway API mode |
|---|---|---|
| Resource | `Gateway` + `VirtualService` | `Gateway` (gateway.networking.k8s.io) + `HTTPRoute` |
| Data plane provisioning | Manual via `Gateway` CR or IstioOperator | Auto-provisioned per Gateway resource |
| Deployment location | `istio-system` namespace | Gateway's own namespace |
| Deployment label | `istio=ingressgateway` | `gateway.networking.k8s.io/gateway-name=<name>` |

## When

Use Istio Gateway API scenarios when:

- The Helm chart under test should be reachable through Istio-managed Gateway API
  HTTPRoutes (HTTP traffic routed through auto-provisioned Envoy data-plane pods).
- You need multi-listener Gateways (HTTP + HTTPS on the same Gateway) managed by
  Istio's Gateway API controller.
- You need BackendTLSPolicy to enforce TLS from the gateway to upstream backends.
- You are testing Gateway API features with an Istio-based implementation.
- The chart already uses or can switch to Gateway API HTTPRoute (enabled via
  `gatewayRoute.enabled: true`).

**Do not use** Istio Gateway API if:

- The chart needs classic Istio `VirtualService`/`DestinationRule` routing —
  use the `istio-ingress-gateway` or `istio-service-mesh` primers instead.
- You are testing a different Gateway API implementation (envoy-gateway or
  contour-gateway-api) — each has its own primer.
- Your Istio installation predates 1.22 (Gateway API support was experimental
  before 1.22; stable since 1.22+).

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
referencing the named Gateway parent. The chart does **not** create
GatewayClass or Gateway resources — the scenario's smoke-script creates those.

### Scenario pattern

Every Istio Gateway API scenario follows this pattern:

1. **Preinstall istio/base** (Helm) — installs cluster-scoped Istio CRDs and
   the `istio-system` namespace.

2. **Preinstall istio/istiod** (Helm) — installs the Istio control plane
   (istiod) in `istio-system`. Gateway API support is enabled by default in
   Istio 1.22+.

3. **Preinstall Gateway API CRDs** (raw_manifest) — applies the upstream
   `standard-install.yaml` from `kubernetes-sigs/gateway-api` (and
   `experimental-install.yaml` for BackendTLSPolicy when needed).

4. **Install the product chart** with `gatewayRoute.enabled: true`.

5. **Run a smoke-script** that:
   - Creates a GatewayClass named `istio` with
     `controllerName: istio.io/gateway-controller`.
   - Creates a Gateway in the product namespace.
   - Waits for GatewayClass `Accepted=True` and Gateway `Programmed=True`.
   - Waits for HTTPRoute `Accepted=True`.
   - Probes the backend through the auto-provisioned data-plane Service.
   - Exits 0 (PASS) or non-zero (FAIL) with a diagnostic message.

## Cluster preinstall

### istio/base helm chart

```yaml
kind: helm
chart: istio/base
version: 1.27.9
release: istio-base
namespace: istio-system
repo:
  name: istio
  url: "https://istio-release.storage.googleapis.com/charts"
values: {}
wait: helm-deployed
wait_timeout: 2m
```

### istio/istiod helm chart

```yaml
kind: helm
chart: istio/istiod
version: 1.27.9
release: istiod
namespace: istio-system
repo:
  name: istio
  url: "https://istio-release.storage.googleapis.com/charts"
values:
  pilot:
    resources:
      requests: { cpu: "100m", memory: "384Mi" }
wait: pods-ready
wait_timeout: 5m
```

Gateway API support is enabled by default in Istio 1.22+. No extra
`pilot.env` settings are needed for basic Gateway API functionality.

### Gateway API CRDs (raw_manifest)

```yaml
kind: raw_manifest
path: https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```

For the BackendTLSPolicy variant, also include the experimental CRDs:

```yaml
kind: raw_manifest
path: https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/experimental-install.yaml
```

The `raw_manifest` preinstall applies these via `kubectl apply --server-side
--force-conflicts`.

### Self-signed TLS certificate (for HTTPS listeners)

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=sample.sample.svc.cluster.local" \
  -addext "subjectAltName=DNS:sample.sample.svc.cluster.local"
kubectl -n sample create secret tls gateway-tls-cert --cert=tls.crt --key=tls.key
```

## Variants

Three scenario variants are available under
`examples/sample-product-chart/chart-test/scenarios/`:

| Variant | File | Key behavior |
|---|---|---|
| basic | `gateway-api-istio-gateway-api-basic.yaml` | GatewayClass `istio` Accepted=True; Gateway Programmed=True; auto-provisioned Deployment; HTTPRoute Accepted=True; HTTP curl returns 200 |
| multi-listener | `gateway-api-istio-gateway-api-multi-listener.yaml` | Gateway declares ≥ 2 listeners (HTTP:80 + HTTPS:443); both Programmed=True; HTTP 200 + HTTPS 200 |
| backend-tls-policy | `gateway-api-istio-gateway-api-backend-tls-policy.yaml` | BackendTLSPolicy targets product Service with Accepted=True; gateway initiates TLS to upstream; visible in Istio access logs |

The basic variant is the baseline (fastest to run). The backend-tls-policy
variant exercises the experimental Gateway API CRDs.

## Assertions

Every Istio Gateway API scenario uses these assertion types:

| Type | Purpose |
|---|---|
| `helm-status-deployed` | Confirm istio-base, istiod, and product chart releases are deployed |
| `pods-ready` | Confirm all pods in sample and istio-system namespaces are Ready |
| `smoke-script` | Create Gateway API resources, wait for admission/programming, probe the backend |

The smoke-script assertions live under
`examples/sample-product-chart/chart-test/assertions/` and are referenced by
`path` from the scenario.

## Known gotchas

- **GatewayClass must be named `istio`** — The Istio Gateway API controller
  only reconciles GatewayClasses whose `spec.controllerName` equals
  `istio.io/gateway-controller`. The GatewayClass `metadata.name` MUST be
  `istio` — not `istio-gateway`, `istio-gw`, or any other name.

- **Gateway address on kind** — The auto-provisioned Service is of type
  `LoadBalancer`. On kind clusters without MetalLB, the external IP stays
  `<pending>`. Use the Service ClusterIP to probe the gateway.

- **Data-plane Deployment label** — The auto-provisioned Deployment is
  labeled `gateway.networking.k8s.io/gateway-name=<gw-name>`. Use this to find
  the deployment: `kubectl get deploy -n <ns> -l gateway.networking.k8s.io/gateway-name=sample-gw`.

- **istiod resource requirements** — istiod needs at minimum ~384Mi memory
  on kind. If the kind node has less available, reduce the resource request
  or increase Docker Desktop memory.

- **Gateway API version compatibility** — Istio Gateway API support tracks
  the Gateway API specification. Use the standard-install.yaml from the
  matching release. `v1.2.0` is the recommended CRD version for Istio 1.27+.

- **BackendTLSPolicy requires experimental CRDs and alpha flag** —
  BackendTLSPolicy is in the experimental channel of Gateway API CRDs
  (`v1alpha3`). Apply `experimental-install.yaml` BEFORE creating
  BackendTLSPolicy resources. For Istio 1.27.x, you must also set
  `pilot.env.PILOT_ENABLE_ALPHA_GATEWAY_API: "true"` in istiod values.
  Istio 1.28+ supports BackendTLSPolicy natively (v1) without this flag.

- **BackendTLSPolicy API version** — In Gateway API v1.2.0 experimental
  CRDs, the only served version is `v1alpha3`. Use:
  `apiVersion: gateway.networking.k8s.io/v1alpha3`.

- **BackendTLSPolicy status** — Accepted conditions are nested under
  `status.ancestors[0].conditions`, not at top-level `status.conditions`.
  Use jsonpath:
  `{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}`.

- **Backend TLS requires nginx HTTPS listener** — For BackendTLSPolicy to
  work, the backend nginx must serve TLS. Set `tls.waitForCerts: "true"`
  to enable the TLS server block in nginx config. The TLS certificate and
  key must be available in the namespace before the product chart is
  installed (use preinstall `raw_manifest` fixtures).

- **Avoid conflicting HTTPRoutes** — When using BackendTLSPolicy with a
  custom HTTPRoute (e.g., routing to port 443), disable the product chart's
  auto-generated HTTPRoute with `gatewayRoute.enabled: "false"`. Otherwise
  two HTTPRoutes with different backend ports on the same listener create
  routing ambiguity.

- **Multi-listener TLS certificate** — The HTTPS listener requires a TLS
  Secret in the Gateway's namespace. The certificate must cover the hostname
  used in the curl probe. For kind testing, a self-signed certificate with
  the SAN `sample.sample.svc.cluster.local` works with `curl --insecure`.

- **Retry probes (data-plane warm-up)** — After the Gateway listener reports
  `Programmed=True`, the auto-provisioned Envoy may need up to 30s to become
  ready for traffic. Use a retry loop (20 attempts × 6s = 2m) when probing.

- **Preinstall order matters** — `istio/base` MUST be installed before
  `istio/istiod`. The base chart creates the CRDs and namespace that istiod
  depends on. Gateway API CRDs can be installed before or after Istio.

- **Istio Gateway API does not create GatewayClass** — Unlike the classic
  Istio installation (which creates a default `istio` GatewayClass), the
  Gateway API integration requires you to manually create the GatewayClass
  resource. The controller reconciles GatewayClasses it finds but does not
  auto-create them.

## References

- [Istio Gateway API documentation](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/)
- [Istio Helm installation](https://istio.io/latest/docs/setup/install/helm/)
- [Gateway API specification](https://gateway-api.sigs.k8s.io/)
- [Gateway API CRDs (upstream)](https://github.com/kubernetes-sigs/gateway-api/releases)
- [BackendTLSPolicy (Gateway API experimental)](https://gateway-api.sigs.k8s.io/api-types/backendtlspolicy/)
- [Istio Change Notes 1.28 (BackendTLSPolicy)](https://istio.io/latest/news/releases/1.28.x/announcing-1.28/change-notes/)
