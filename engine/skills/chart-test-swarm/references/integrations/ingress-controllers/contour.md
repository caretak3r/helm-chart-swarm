# Contour Ingress Controller

## What

Contour is a Kubernetes ingress controller that deploys the Envoy proxy as the
data plane. It supports both classic `networking.k8s.io/v1` Ingress resources
and its own expressive CRD: the HTTPProxy (`projectcontour.io/v1`). HTTPProxy
offers features beyond standard Ingress — TLS delegation across namespaces,
local rate limiting, JWT verification, request/response header manipulation,
and weighted traffic splitting.

The chart-test-swarm scenarios for Contour verify that the consumer chart can:

1. Route HTTP traffic through a Contour-managed Envoy proxy via HTTPProxy CRD
2. Terminate TLS using a delegated cross-namespace Secret via TLSCertificateDelegation
3. Enforce rate limits using `rateLimitPolicy.local` on an HTTPProxy route
4. (Optional) Verify JWT authentication via `jwtVerificationPolicy` on an HTTPProxy

## When

| Situation | Decision |
|---|---|
| Consumer chart needs expressive routing beyond standard Ingress | Contour HTTPProxy (inclusion, delegation, header manip) |
| Cross-namespace TLS certificate sharing is required | Contour TLSCertificateDelegation |
| Per-route rate limiting without external rate-limit service | Contour local rate limiting (built-in since v1.26) |
| JWT verification at the proxy layer without custom auth services | Contour JWT verification (built-in since v1.24) |
| Simple Host/path Ingress routing | Either Contour classic Ingress (`ingressClassName: contour`) or any other standard ingress controller |
| Gateway API support (HTTPRoute, GRPCRoute) | Contour with Gateway API provisioner (see gateway-api/contour-gateway-api.md) |
| Middleware chains (reusable across routes) | Traefik Middleware CRs are simpler for that use case |
| Snippet annotations (custom NGINX config injection) | NGINX Ingress with snippet annotations |

**Key differentiator:** Contour's HTTPProxy CRD provides TLS delegation,
inclusion/delegation of routing rules across namespaces, and built-in local rate
limiting and JWT verification — all without external services. This makes it
ideal for multi-tenant platforms where different teams own different namespaces
but share a common ingress controller.

## How

### Integration mechanism

Contour's data plane (Envoy) runs as a DaemonSet — one Envoy pod per node.
The Contour controller (Deployment) watches HTTPProxy CRs and programs the Envoy
instances via xDS. Traffic reaches the product via:

1. **Classic Ingress** — `ingressClassName: contour` on a standard
   `networking.k8s.io/v1` Ingress. Contour picks it up automatically.
2. **HTTPProxy CRD** — `apiVersion: projectcontour.io/v1` custom resource.
   Much more expressive: supports TLS delegation, rate limits, JWT auth,
   and multi-namespace route inclusion.

### Probe pattern

All Contour scenarios use in-cluster HTTP probes targeting the **Envoy pod IP**
directly. The Envoy container listens on port **8080** for the `http` listener
and port **8443** for the `https` listener — not 80/443. The Host header is
always required because HTTPProxy rules match on `conditions[].prefix` with a
virtual host FQDN.

```bash
# From inside the cluster:
# HTTP: use envoy container port 8080
curl -H "Host: sample.test.local" http://<envoy-pod-ip>:8080/

# HTTPS: use envoy container port 8443
curl -k --resolve sample.test.local:8443:<envoy-pod-ip> https://sample.test.local:8443/

# Check HTTPProxy status (should be "valid")
kubectl -n sample get httpproxy sample-basic -o jsonpath='{.status.currentStatus}'
```

### Chart values wiring

The consumer chart (`examples/sample-product-chart/chart`) has an `ingress.*`
values block. For Contour, the scenarios disable the chart's built-in
Ingress (`ingress.enabled: "false"`) and instead deliver HTTPProxy CRs via
`raw_manifest` preinstall items. This keeps the chart decoupled from
Contour-specific CRDs while still exercising the integration.

## Cluster preinstall

```yaml
- kind: helm
  chart: projectcontour/contour
  version: "0.6.0"
  release: contour
  namespace: projectcontour
  repo:
    name: projectcontour
    url: "https://projectcontour.github.io/helm-charts"
  wait: pods-ready
  wait_timeout: 3m
```

### Preinstall values rationale

| Setting | Why |
|---|---|
| No custom values needed | Contour works out-of-the-box with defaults. Probes target the Envoy pod IP directly on container ports 8080 (HTTP) / 8443 (HTTPS), bypassing the Service layer entirely. |
| No `ingressClass` overrides | Contour creates the `contour` IngressClass by default. |
| No Gateway API CRDs installed | This primer focuses on HTTPProxy mode (not Gateway API). Gateway API scenarios use a separate primer. |
| No dashboard or debug flags | Minimal config for test clusters. |

## Variants

| Variant | Scenario file | Mechanism | What it tests |
|---|---|---|---|
| Basic HTTPProxy | `ingress-controllers-contour-basic-httpproxy.yaml` | HTTPProxy CRD | Host header routing, HTTPProxy status `valid`, 200 from backend |
| TLS delegation | `ingress-controllers-contour-tls-delegation.yaml` | TLSCertificateDelegation + HTTPProxy with TLS | Cross-namespace TLS Secret access, HTTPS 200 with delegated cert |
| Rate limit | `ingress-controllers-contour-rate-limit.yaml` | HTTPProxy with `rateLimitPolicy.local` | Rate ceiling enforced, 429 responses above limit |
| JWT auth (optional) | `ingress-controllers-contour-jwt-auth.yaml` | HTTPProxy with `jwtVerificationPolicy` | 401/403 without Bearer, 200 with valid JWT |

All scenario YAMLs live under `examples/sample-product-chart/chart-test/scenarios/`.

### Shared scenario shape

Every Contour variant shares:
- `cluster.preinstall[0]`: Contour helm chart (identical across all variants)
- `product.chart: ./chart`, `product.release: sample`, `product.namespace: sample`
- `product.set.ingress.enabled: "false"` — chart's built-in Ingress is off
- Route resources delivered as `raw_manifest` preinstall items from
  `chart-test/fixtures/ingress-controllers/`
- `mechanisms: [addon:contour]` for dashboard rollup

Variants differ only in:
- Which raw_manifest preinstall items they include (HTTPProxy CR, TLS secret,
  TLSCertificateDelegation)
- `product.set` overrides (e.g., `tls.enabled` for the TLS variant)

## Assertions

Each Contour scenario uses a `smoke-script` assertion at
`chart-test/assertions/contour-<variant>.sh`. The scripts:

1. Wait for envoy pod Ready (`kubectl -n projectcontour wait pod`)
2. Wait for product pod Ready
3. Get envoy pod IP via `kubectl -n projectcontour get pod -o jsonpath`
4. Run in-cluster curl probes through `kubectl run ... --image=quay.io/curl/curl`
5. Check HTTP status codes, response headers, and (for TLS) certificate subjects

Additionally, `pods-ready` assertions for both `projectcontour` and `sample`
namespaces gate the smoke-script on controller and product availability.

## Known gotchas

- **Envoy listens on 8080/8443, not 80/443** — The Envoy container's HTTP
  listener is on port 8080 and HTTPS is on 8443. Probes must use these
  container ports directly, not the NodePort-mapped 80/443.

- **`Host` header is required** — HTTPProxy rules match against the virtual
  host FQDN. A probe without a matching `Host` header returns a 404 from
  envoy. Always include `-H "Host: sample.test.local"` (or whatever host
  the HTTPProxy declares).

- **HTTPProxy status `currentStatus` field** — The HTTPProxy CR's
  `.status.currentStatus` must be `valid` for routing to work. If it shows
  `invalid`, check: (a) the referenced Service exists in the same namespace,
  (b) TLS secrets referenced exist and are of type `kubernetes.io/tls`,
  (c) TLSCertificateDelegation is in place for cross-namespace secrets.

- **TLSCertificateDelegation must be in the SECRET's namespace** — The
  TLSCertificateDelegation resource lives in the same namespace as the TLS
  secret it delegates, not in the HTTPProxy's namespace. The
  `spec.delegations[].targetNamespaces[]` list specifies which namespaces
  are allowed to reference it.

- **Local rate limiting is per-Envoy-pod** — Since Envoy runs as a
  DaemonSet, a rate limit of "5 per minute" means 5 per minute PER envoy
  pod. On a single-node kind cluster this is fine; on multi-node clusters
  the effective limit scales with the number of nodes.

- **Local rate limiting burst** — The `burst` parameter allows occasional
  spikes above the base rate. If you send exactly the limit and all
  requests return 200, you may not have exceeded the burst. Send 2x the
  limit to reliably trigger 429 responses.

- **`projectcontour.io/v1` vs `projectcontour.io/v1alpha1`** — HTTPProxy
  is `projectcontour.io/v1` (stable since Contour 1.18). Older references
  may use `v1alpha1`; this primer uses `v1`.

- **CRD installation** — The Contour helm chart installs CRDs automatically
  (httpproxies.projectcontour.io, tlscertificatedelegations.projectcontour.io).
  No separate CRD manifest is needed.

- **Pod label selectors** — The projectcontour/contour chart labels pods with
  `app.kubernetes.io/component=envoy` (NOT `app.kubernetes.io/name=envoy`) and
  `app.kubernetes.io/component=contour`. Use `-l app.kubernetes.io/component=envoy`
  for kubectl commands targeting the envoy pod.

- **Kind cluster extra port mappings** — Contour's Envoy DaemonSet uses
  hostPorts by default (ports 80 and 443 on the host). On kind, this works
  fine for in-cluster probes. For out-of-cluster access, you may need extra
  port mappings in the kind config.

## References

- [Contour HTTPProxy docs](https://projectcontour.io/docs/main/config/fundamentals/)
- [Contour TLS Delegation](https://projectcontour.io/docs/main/config/tls-delegation/)
- [Contour Rate Limiting](https://projectcontour.io/docs/main/config/rate-limiting/)
- [Contour JWT Verification](https://projectcontour.io/docs/main/config/jwt-verification/)
- [Contour Helm chart](https://github.com/projectcontour/helm-charts)
- [Contour kind quickstart](https://projectcontour.io/docs/main/guides/kind/)
