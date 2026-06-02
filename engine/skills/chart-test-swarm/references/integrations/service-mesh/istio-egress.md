# Istio Egress (ServiceEntry + Egress Gateway)

Installs Istio with egress traffic management using `ServiceEntry` and
`DestinationRule` CRDs to define external services, and an optional egress
gateway for controlling and monitoring outbound traffic. The chart-test-swarm
scenarios verify that the consumer chart can:

1. Reach external services defined via `ServiceEntry` from within the mesh
2. Route egress traffic through a dedicated egress gateway (Istio Gateway +
   VirtualService)
3. Enforce `REGISTRY_ONLY` outbound policy — block traffic to undefined
   external services
4. Apply `DestinationRule` TLS settings for external HTTPS endpoints

## What

Istio egress management controls how mesh workloads communicate with services
outside the cluster. By default, Istio allows all outbound traffic
(`outboundTrafficPolicy: ALLOW_ANY`). For production deployments, Istio can
be configured with `REGISTRY_ONLY` mode, which blocks traffic to any external
service not explicitly defined in a `ServiceEntry`.

The egress gateway pattern adds a dedicated gateway (Istio Gateway +
VirtualService) through which all outbound traffic is routed. This enables:

- Centralized monitoring and logging of egress traffic
- TLS origination (mesh workloads send plain HTTP; the gateway upgrades to
  HTTPS)
- Access control via `AuthorizationPolicy` on the egress gateway
- IP-based allowlisting for external endpoints

**Key components:**
- **ServiceEntry** — Registers an external service in Istio's service registry.
  Makes the external endpoint routable from within the mesh and enables
  Istio features (mTLS, telemetry, authorization) for it.
- **DestinationRule** — Configures client-side TLS settings and load-balancing
  for the external service.
- **Egress Gateway** — A dedicated Istio Gateway deployment that serves as the
  exit point for all outbound traffic. Traffic is routed through the gateway
  via VirtualService rules.
- **VirtualService** — Routes traffic from mesh workloads to the egress
  gateway, and from the egress gateway to the external endpoint.

## When

Use these scenarios when validating that a Helm chart:

- Needs to reach external APIs, databases, or services from within the mesh
- Requires egress traffic monitoring or access control
- Uses `REGISTRY_ONLY` outbound policy (block undefined external traffic)
- Needs TLS origination for external HTTPS endpoints
- Must route all egress through a centralized gateway for compliance

**When NOT to use egress scenarios:**
- The chart does not make external API calls (no egress traffic)
- The mesh is configured with `ALLOW_ANY` outbound policy and no egress
  control is required
- External services are accessed via a service mesh multi-cluster setup
  (not egress, but cross-cluster communication)

## How

### Integration mechanism

Egress management in Istio works in two tiers:

1. **ServiceEntry** — Registers the external endpoint in Istio's internal
  service registry. Without this, `REGISTRY_ONLY` mode blocks the traffic.
2. **Egress Gateway** — A dedicated Gateway + VirtualService that routes
  outbound traffic through a specific pod. The gateway acts as a proxy for
  all egress traffic.

The flow is:
```
Product pod → sidecar/ztunnel → egress gateway → external endpoint
```

Without an egress gateway:
```
Product pod → sidecar/ztunnel → external endpoint (directly)
```

### Probe pattern

Egress scenarios verify external service reachability:

```bash
# Verify ServiceEntry is registered:
kubectl get serviceentry -n <product-ns>

# Verify egress gateway is running:
kubectl -n istio-system get pods -l istio=egressgateway

# Probe external service from within the mesh:
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- \
  curl -sf http://httpbin.org/status/200

# Verify REGISTRY_ONLY blocks undefined services:
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- \
  curl -sf --max-time 5 http://undefined-external.example.com/ && echo "FAIL: should be blocked" || echo "OK: blocked"

# Verify egress gateway routing:
kubectl -n istio-system logs -l istio=egressgateway --tail=20
```

### Chart values wiring

The consumer chart (`examples/sample-product-chart/chart`) needs no special
values for egress scenarios — the ServiceEntry and egress gateway are
cluster-level objects applied at runtime. The chart simply makes HTTP calls
to external endpoints, and the mesh infrastructure handles routing.

## Cluster preinstall

The egress scenarios build on the standard Istio service mesh preinstall,
plus an egress gateway:

```yaml
# Step 1: Istio base CRDs
- kind: helm
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

# Step 2: istiod control plane with REGISTRY_ONLY outbound policy
- kind: helm
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
        requests:
          cpu: "100m"
          memory: "384Mi"
    meshConfig:
      outboundTrafficPolicy:
        mode: REGISTRY_ONLY
  wait: pods-ready
  wait_timeout: 5m

# Step 3: Egress gateway
- kind: helm
  chart: istio/gateway
  version: 1.27.9
  release: istio-egressgateway
  namespace: istio-system
  repo:
    name: istio
    url: "https://istio-release.storage.googleapis.com/charts"
  values:
    service:
      type: ClusterIP
    labels:
      istio: egressgateway
    resources:
      requests:
        cpu: "50m"
        memory: "128Mi"
  wait: pods-ready
  wait_timeout: 3m
```

After the control plane and gateway are ready, label the product namespace
for sidecar injection (egress scenarios use sidecar mode for simplicity):

```bash
kubectl label namespace <product-ns> istio-injection=enabled --overwrite
```

Then apply ServiceEntry + DestinationRule + VirtualService as `raw_manifest`
preinstall items:

```yaml
- kind: raw_manifest
  path: chart-test/fixtures/service-mesh/istio-egress-service-entry.yaml
  namespace: <product-ns>
```

The fixture file contains:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: httpbin-external
  namespace: sample
spec:
  hosts:
    - httpbin.org
  ports:
    - number: 80
      name: http
      protocol: HTTP
  resolution: DNS
  location: MESH_EXTERNAL
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: httpbin-external
  namespace: sample
spec:
  host: httpbin.org
  trafficPolicy:
    tls:
      mode: SIMPLE
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: httpbin-via-egress
  namespace: sample
spec:
  hosts:
    - httpbin.org
  gateways:
    - istio-system/istio-egressgateway
    - mesh
  http:
    - match:
        - gateways:
            - mesh
          port: 80
      route:
        - destination:
            host: istio-egressgateway.istio-system.svc.cluster.local
          weight: 100
    - match:
        - gateways:
            - istio-system/istio-egressgateway
          port: 80
      route:
        - destination:
            host: httpbin.org
            port:
              number: 80
          weight: 100
```

### Preinstall values rationale

| Setting | Why |
|---|---|
| `meshConfig.outboundTrafficPolicy.mode: REGISTRY_ONLY` | Blocks traffic to undefined external services — this is the policy the egress scenarios enforce |
| Egress gateway with `istio: egressgateway` label | Used by VirtualService to route egress traffic through the gateway |
| `service.type: ClusterIP` | Egress gateway is internal-only; no external load balancer needed |
| Sidecar injection on product namespace | Egress scenarios use sidecar mode (simpler for testing) — the proxy handles traffic redirection to the egress gateway |

## Variants

| Variant | Scenario file | Mechanism | What it tests |
|---|---|---|---|
| **service-entry-basic** | `service-mesh-istio-egress-service-entry-basic.yaml` | ServiceEntry + REGISTRY_ONLY | ServiceEntry makes httpbin.org reachable; undefined hosts are blocked; `ALLOW_ANY` → `REGISTRY_ONLY` transition verified |
| **egress-gateway** | `service-mesh-istio-egress-gateway.yaml` | ServiceEntry + egress Gateway + VirtualService | Egress traffic routes through the dedicated egress gateway; gateway logs confirm the request |
| **tls-origination** | `service-mesh-istio-egress-tls-origination.yaml` | ServiceEntry + DestinationRule TLS mode: SIMPLE | Client sends HTTP; egress gateway upgrades to HTTPS for the external endpoint |

All scenario YAMLs live under `examples/sample-product-chart/chart-test/scenarios/service-mesh/`.

### Shared scenario shape

Every egress variant shares:
- `cluster.preinstall[0-2]`: Istio base, istiod (with REGISTRY_ONLY), egress gateway
- `product.chart: ./chart`, `product.release: sample`, `product.namespace: sample`
- Product namespace labeled for sidecar injection
- `mechanisms: [addon:istio-egress]` for dashboard rollup

The service-entry-basic variant uses only ServiceEntry + DestinationRule
(no egress gateway). The egress-gateway variant adds VirtualService routing
through the gateway. The tls-origination variant adds DestinationRule
TLS settings.

## Feasibility checklist for the consumer chart

**Required:**
- [ ] Chart has at least one workload that makes outbound HTTP calls — egress
  scenarios exercise external service reachability. Without outbound calls,
  there is nothing to test.
- [ ] Chart does not hardcode IP addresses for external services — Istio's
  ServiceEntry works by hostname, not IP. If the chart uses IPs, the
  ServiceEntry will not match.

**Soft:**
- [ ] External API URLs are value-driven — lets scenarios override the
  external endpoint to use a test-friendly target like `httpbin.org`.
- [ ] Chart does not use `hostNetwork: true` — host-network pods bypass
  the sidecar proxy and egress routing has no effect.

## Assertions

Each egress scenario uses assertion scripts that:

1. Wait for istiod and egress gateway pods Ready
2. Verify ServiceEntry is created and has `MESH_EXTERNAL` location
3. Verify product pod has `istio-proxy` sidecar (sidecar injection)
4. Probe the external service (httpbin.org) from within the mesh → 200
5. Probe an undefined external host → connection refused/timeout (blocked by
   REGISTRY_ONLY)

For egress-gateway variant:
6. Verify egress gateway pod logs contain the routed request
7. Verify VirtualService routes traffic through the gateway

For tls-origination variant:
8. Verify DestinationRule TLS mode is `SIMPLE`
9. Verify the external request is upgraded from HTTP to HTTPS at the gateway

## Known gotchas

- **`REGISTRY_ONLY` blocks ALL undefined external traffic** — After switching
  to `REGISTRY_ONLY`, any external service not in a `ServiceEntry` is
  unreachable. This includes package registries, Docker Hub, and any
  CRD-downloaded URLs. If the product chart's init containers pull
  configuration from an external URL, add a ServiceEntry for that URL too.

- **ServiceEntry must be in the same namespace as the workload** — If the
  ServiceEntry is in a different namespace than the calling pod, it must be
  a `ExportTo: "."` or namespace-scoped entry. For simplicity, M15 scenarios
  put the ServiceEntry in the product namespace.

- **Egress gateway VirtualService must list both `mesh` and the gateway** —
  The VirtualService that routes traffic through the egress gateway must have
  `gateways: [istio-system/istio-egressgateway, mesh]`. The `mesh` entry
  captures outbound traffic from sidecars; the gateway entry handles the
  second leg (gateway → external). Omitting `mesh` means sidecars route
  directly; omitting the gateway name means the gateway doesn't know where
  to forward.

- **DNS resolution for ServiceEntry** — `resolution: DNS` means Istio
  resolves the external hostname at request time. If the cluster's DNS
  cannot resolve `httpbin.org`, the ServiceEntry is useless. Verify DNS
  resolution from inside the cluster before running scenarios.

- **TLS origination changes the SNI** — When DestinationRule sets `tls.mode:
  SIMPLE`, the sidecar/egress gateway originates a new TLS connection. The
  original HTTP request is wrapped in TLS. The external server sees a
  standard HTTPS request, not the original HTTP one.

- **Egress gateway adds latency** — Routing through the egress gateway adds
  one network hop (~1-5ms). For test scenarios this is acceptable.

- **`istio/gateway` chart creates an ingress gateway by default** — The
  standard `istio/gateway` chart creates a Deployment labeled
  `istio: ingressgateway`. For an egress gateway, override the labels with
  `istio: egressgateway` to distinguish it from the ingress gateway.

- **Istio version pinning** — The base, istiod, and gateway charts MUST use
  the same version. Version skew causes compatibility errors. Pin to
  `1.27.9` across all preinstall items.

## References

- [Istio Egress Gateways](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/)
- [Istio ServiceEntry](https://istio.io/latest/docs/reference/config/networking/service-entry/)
- [Istio Egress Traffic Control](https://istio.io/latest/docs/tasks/traffic-management/egress/)
- [Istio TLS Origination for Egress](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/)
- [Istio Gateway chart](https://artifacthub.io/packages/helm/istio-official/gateway)
