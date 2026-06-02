# Kong Ingress Controller

## What

Kong Ingress Controller (KIC) is a Kubernetes-native ingress controller built on
top of the Kong Gateway. It supports classic Kubernetes Ingress resources as well
as its own CRDs (KongPlugin, KongClusterPlugin, KongIngress, TCPIngress,
UDPIngress) for advanced API management. KIC routes HTTP and TCP traffic,
performs TLS termination, and applies per-route plugins for rate-limiting,
authentication, transformation, and observability.

The chart-test-swarm scenarios for Kong verify that the consumer chart can:

1. Coexist with Kong's CRDs (KongPlugin, KongIngress)
2. Route HTTP traffic through a Kong-managed Ingress with `ingressClassName: kong`
3. Prove the Kong proxy serves the route end-to-end (200 with matching Host)
4. Document the **KongPlugin gap** — the sample chart exposes no
   `konghq.com/plugins` annotation or KongPlugin CRD knob, so plugin-based
   traffic policies are an **honest gap** (red cell) on the support matrix

## When

| Situation | Decision |
|---|---|
| Consumer chart needs classic Ingress routing via Kong | Kong with `ingressClassName: kong` |
| Per-route plugin application (rate-limit, auth, transformation) | KongPlugin CRD + `konghq.com/plugins` annotation |
| TCP/UDP routing beyond HTTP | Kong TCPIngress / UDPIngress CRDs |
| Need API gateway capabilities (auth, rate-limit, caching) | KongPlugin / KongClusterPlugin CRDs |
| Simple Ingress with no plugin requirements | Any ingress controller (traefik, nginx, kong all work) |
| Gateway API support needed | Consider istio-gateway-api or envoy-gateway instead |

**Key differentiator:** Kong's plugin ecosystem is its primary advantage over
other ingress controllers. The `KongPlugin` CRD and `konghq.com/plugins`
annotation enable per-route policy injection without modifying the upstream
service. When the consumer chart does NOT expose this annotation, it is an
**honest gap** — do NOT over-engineer the chart to add it.

## How

### Integration mechanism

Kong routes traffic via:
- **Classic Ingress** — `ingressClassName: kong` on a standard
  `networking.k8s.io/v1` Ingress. Kong's Ingress controller watches and
  translates these into Kong proxy routes.
- **KongPlugin CRD** — `apiVersion: configuration.konghq.com/v1` custom
  resource. Attaches to an Ingress or Service via the
  `konghq.com/plugins` annotation. Without this annotation, the plugin has
  no effect.

### Probe pattern

All Kong scenarios use in-cluster HTTP probes targeting the **Kong proxy pod IP**
directly. The Kong proxy container listens on port **8000** for HTTP (proxy)
and port **8443** for HTTPS. The Host header is required — Kong's Ingress
routing rules match on `Host()` and return 404 without it.

```bash
# From inside the cluster:
# HTTP probe through Kong proxy
curl -H "Host: sample.test.local" http://<kong-proxy-pod-ip>:8000/

# Without Host header: returns Kong 404
curl http://<kong-proxy-pod-ip>:8000/

# Verify IngressClass is registered
kubectl get ingressclass kong
```

### Chart values wiring

The consumer chart (`examples/sample-product-chart/chart`) has an `ingress.*`
values block. For Kong, set `ingress.className: kong`. The chart does NOT
expose a `konghq.com/plugins` annotation or a `KongPlugin` value gate —
this is an **honest gap** surfaced by the KongPlugin gap-probe scenario.

## Cluster preinstall

```yaml
- kind: helm
  chart: kong/ingress
  version: 0.24.0
  release: kong
  namespace: kong
  repo:
    name: kong
    url: "https://charts.konghq.com"
  values:
    ingressController:
      enabled: true
      ingressClass: kong
      installCRDs: true
    proxy:
      type: NodePort
      http:
        enabled: true
        nodePort: 30080
      tls:
        enabled: true
        nodePort: 30443
    env:
      database: "off"
    replicaCount: 1
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
  wait: pods-ready
  wait_timeout: 5m
```

### Preinstall values rationale

| Setting | Why |
|---|---|
| `ingressController.installCRDs: true` | Ensures KongPlugin, KongIngress, TCPIngress CRDs are created before scenarios apply them |
| `proxy.type: NodePort` | Kind has no LoadBalancer; NodePort lets Kong bind host ports |
| `env.database: "off"` | DB-less mode for simpler test-cluster setup |
| `replicaCount: 1` | Single replica sufficient for test scenarios |
| `ingressController.ingressClass: kong` | Registers IngressClass `kong` so Ingress resources with `ingressClassName: kong` are routed |

## Variants

| Variant | Scenario file | Mechanism | What it tests |
|---|---|---|---|
| Basic ingress | `networking-kong-ingress.yaml` | Ingress (className: kong) | Host header routing via Kong proxy, 200 with matching Host |
| KongPlugin gap-probe | `networking-kong-ingress-kongplugin-gap.yaml` | KongPlugin CRD + `konghq.com/plugins` annotation | **Honest gap**: chart exposes no `konghq.com/plugins` annotation; gap-probe documents this as a red cell |

All scenario YAMLs live under `examples/sample-product-chart/chart-test/scenarios/networking/`.

### Shared scenario shape

Every Kong variant shares:
- `cluster.preinstall[0]`: Kong ingress helm chart (identical across variants)
- `product.chart: ./chart`, `product.release: sample`, `product.namespace: sample`
- `product.set.ingress.enabled: "true"` with `ingress.className: kong`
- `mechanisms: [addon:kong]` for dashboard rollup

The gap-probe variant additionally:
- Creates a `KongPlugin` CRD (e.g., rate-limiting) via `raw_manifest`
- Probes whether the chart's Ingress template renders the `konghq.com/plugins`
  annotation
- **Expected result: FAIL (gap)** — the chart does not support this annotation

## Assertions

Each Kong scenario uses assertion scripts that:

1. Wait for Kong controller + proxy pods Ready (`kubectl -n kong wait pod`)
2. Verify IngressClass `kong` is registered
3. Wait for product pod Ready
4. Get Kong proxy pod IP via `kubectl -n kong get pod -o jsonpath`
5. Run in-cluster curl probes through `kubectl run ... --image=curlimages/curl`
6. Check HTTP status codes (200 for matching Host, 404 without)

For the KongPlugin gap-probe:
7. Verify a `KongPlugin` CRD was created and is Accepted
8. Verify the chart's Ingress does NOT have the `konghq.com/plugins` annotation
9. Report status: **FAIL (gap)** — this is the honest outcome

## Known gotchas

- **`konghq.com/plugins` annotation is per-Ingress, not global** — The
  annotation must be on the Ingress metadata (or Service metadata). Creating
  a KongPlugin CRD without the annotation has no effect on routing. The
  gap-probe documents that the sample chart does not render this annotation.

- **Kong proxy container port is 8000, not 80** — The Kong proxy container
  listens on port 8000 for HTTP and 8443 for HTTPS. The Service maps 80→8000
  and 443→8443. When probing pod IP directly, use port 8000.

- **IngressClass `kong` must exist before applying Ingress** — If the Kong
  helm chart is not fully deployed (CRDs + IngressClass not yet registered),
  applying an Ingress with `ingressClassName: kong` results in a
  `FailedDraw` condition. Wait for Kong pods Ready before applying the
  product chart.

- **DB-less mode limitation** — In DB-less mode (`env.database: "off"`),
  KongPlugin declarations are declarative and must exist before the Ingress
  references them. Declaring a KongPlugin after the Ingress is created may
  require a Kong pod restart to pick up the new plugin configuration.

- **CRD installation timing** — The `installCRDs: true` setting in the
  helm chart installs CRDs via helm hooks. If CRD creation is slow, applying
  a KongPlugin immediately after `helm install` may fail with "server could
  not find the requested resource". Wait for CRDs to be established:
  `kubectl wait --for condition=Established crd/kongplugins.configuration.konghq.com`.

- **Multiple IngressClass controllers** — If other ingress controllers
  (nginx, traefik) are also installed, ensure Ingress resources explicitly
  set `ingressClassName: kong`. Without an explicit class, Kubernetes may
  route the Ingress to the default controller.

## References

- [Kong Ingress Controller Helm chart](https://github.com/Kong/charts/tree/main/charts/kong)
- [Kong Ingress Controller docs](https://docs.konghq.com/kubernetes-ingress-controller/latest/)
- [KongPlugin CRD reference](https://docs.konghq.com/kubernetes-ingress-controller/latest/concepts/custom-resources/)
- [Kong DB-less mode](https://docs.konghq.com/kubernetes-ingress-controller/latest/guides/provider/konnect/)

