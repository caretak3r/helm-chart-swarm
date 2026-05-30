# Traefik Ingress Controller

## What

Traefik is a cloud-native reverse proxy and ingress controller that supports
both classic Kubernetes Ingress resources and its own CRDs (IngressRoute,
IngressRouteTCP, Middleware, TLSOption). It handles HTTP and TCP routing,
TLS termination and passthrough, and middleware chains for request/response
modification.

The chart-test-swarm scenarios for Traefik verify that the consumer chart can:

1. Coexist with Traefik's CRDs (IngressRoute, IngressRouteTCP, Middleware)
2. Route HTTP traffic through a Traefik IngressRoute with Host header matching
3. Passthrough TLS connections untouched (the backend's cert, not Traefik's)
4. Apply Middleware CRs for header injection and other transformations
5. Route exclusively via IngressRoute CRD (no classic Ingress required)

## When

| Situation | Decision |
|---|---|
| Consumer chart needs both HTTP and TCP routing | Traefik (IngressRoute + IngressRouteTCP) |
| TLS passthrough to backend (no termination at proxy) | Traefik IngressRouteTCP with `tls.passthrough: true` |
| Middleware chains (headers, strip-prefix, rate-limit, redirect) | Traefik Middleware CRs attached to IngressRoute |
| Simple classic Ingress routing with Host/path rules | Traefik classic Ingress (ingressClassName: traefik) |
| Need Gateway API support (experimental in Traefik v3) | Consider envoy-gateway or istio-gateway-api instead |
| Production-grade WAF / regex-heavy rewrite rules | NGINX Ingress with snippet annotations may be better |

**Key differentiator:** Traefik's IngressRoute CRD is simpler than HTTPProxy
(Contour) for basic routing but less expressive for delegation and JWT auth.
Middleware CRs are reusable across IngressRoutes, making them ideal for
cross-cutting concerns.

## How

### Integration mechanism

Traefik routes traffic via either:
- **Classic Ingress** — `ingressClassName: traefik` on a standard `networking.k8s.io/v1` Ingress.
  Traefik's built-in Ingress controller picks it up.
- **IngressRoute CRD** — `apiVersion: traefik.io/v1alpha1` custom resource.
  More expressive than classic Ingress: supports TCP routes, middleware
  references, and TLS passthrough.

### Probe pattern

All Traefik scenarios use in-cluster HTTP probes targeting the **Traefik pod IP**
directly. The Traefik container listens on port **8000** for the `web` entrypoint
and port **8443** for the `websecure` entrypoint — not 80/443. (The `service.type:
NodePort` maps 80→8000 and 443→8443 via the Service, but the pod's container port
is 8000/8443.) The Host header is always required — Traefik's IngressRoute rules
match on `Host(...)` and return a 404 without it.

```bash
# From inside the cluster:
# HTTP: use container port 8000 (web entrypoint)
curl -H "Host: sample.test.local" http://<traefik-pod-ip>:8000/

# Without Host header: returns Traefik 404
curl http://<traefik-pod-ip>:8000/

# TLS passthrough probe (IngressRouteTCP): use container port 8443 (websecure)
curl -k --resolve sample.test.local:8443:<traefik-pod-ip> https://sample.test.local:8443/
```

### Chart values wiring

The consumer chart (`examples/sample-product-chart/chart`) has an `ingress.*`
values block. For Traefik, we set `ingress.className: traefik` — but the
scenarios in this milestone disable the chart's built-in Ingress
(`ingress.enabled: "false"`) and instead deliver IngressRoute/IngressRouteTCP
CRs via `raw_manifest` preinstall items. This keeps the chart decoupled from
Traefik-specific CRDs while still exercising the integration.

## Cluster preinstall

```yaml
- kind: helm
  chart: traefik/traefik
  version: v28.3.0
  release: traefik
  namespace: traefik
  repo:
    name: traefik
    url: "https://traefik.github.io/charts"
  values:
    ingressClass:
      enabled: true
      isDefaultClass: false
    ingressRoute:
      dashboard:
        enabled: false
    ports:
      web:
        exposedPort: 80
      websecure:
        exposedPort: 443
    service:
      type: NodePort
    providers:
      kubernetesIngress:
        enabled: true
      kubernetesCRD:
        enabled: true
  wait: pods-ready
  wait_timeout: 3m
```

### Preinstall values rationale

| Setting | Why |
|---|---|
| `ingressClass.isDefaultClass: false` | Avoids Traefik becoming the default ingress controller — other scenarios may install nginx-ingress. |
| `ingressRoute.dashboard.enabled: false` | No dashboard needed in test clusters. |
| `service.type: NodePort` | Kind has no LoadBalancer; NodePort lets Traefik bind host ports. |
| `providers.kubernetesIngress.enabled: true` | Enables classic Ingress controller (needed for basic variant compatibility). |
| `providers.kubernetesCRD.enabled: true` | Enables IngressRoute/IngressRouteTCP/Middleware CRD processing. |

## Variants

| Variant | Scenario file | Mechanism | What it tests |
|---|---|---|---|
| Basic | `ingress-controllers-traefik-basic.yaml` | IngressRoute | Host header routing, 404 without Host |
| TLS passthrough | `ingress-controllers-traefik-tls-passthrough.yaml` | IngressRouteTCP + tls.passthrough | Backend cert served untouched |
| Middleware chain | `ingress-controllers-traefik-middleware-chain.yaml` | Middleware + IngressRoute | Custom header injected by Middleware CR |
| IngressRoute CRD | `ingress-controllers-traefik-ingressroute-crd.yaml` | IngressRoute (CRD only) | No classic Ingress; CRD-only routing |

All scenario YAMLs live under `examples/sample-product-chart/chart-test/scenarios/`.

### Shared scenario shape

Every Traefik variant shares:
- `cluster.preinstall[0]`: Traefik helm chart (identical across all variants)
- `product.chart: ./chart`, `product.release: sample`, `product.namespace: sample`
- `product.set.ingress.enabled: "false"` — chart's built-in Ingress is off
- Route resources delivered as `raw_manifest` preinstall items from
  `chart-test/fixtures/ingress-controllers/`
- `mechanisms: [addon:traefik]` for dashboard rollup

Variants differ only in:
- Which raw_manifest preinstall items they include (route CR, middleware, TLS secret)
- `product.set` overrides (e.g., `tls.enabled` for the passthrough variant)

## Assertions

Each Traefik scenario uses a `smoke-script` assertion at
`chart-test/assertions/traefik-<variant>.sh`. The scripts:

1. Wait for Traefik pod Ready (`kubectl -n traefik wait pod`)
2. Wait for product pod Ready
3. Get Traefik pod IP via `kubectl -n traefik get pod -o jsonpath`
4. Run in-cluster curl probes through `kubectl run ... --image=curlimages/curl`
5. Check HTTP status codes and response headers

Additionally, `pods-ready` assertions for both `traefik` and `sample`
namespaces gate the smoke-script on controller and product availability.

## Known gotchas

- **`traefik.io` vs `traefik.containo.us` apiGroup** — Traefik v3 uses
  `traefik.io/v1alpha1`; Traefik v2 uses `traefik.containo.us/v1alpha1`.
  This primer targets v3 (chart v28+). Verify with
  `kubectl get crd | grep traefik`.

- **404 from gateway — `Host` header missing** — IngressRoute rules use
  `Host(...)` matching; a probe without the matching `Host` header returns
  Traefik's default 404. Always include `-H "Host: ..."` in curl probes.
  Also ensure you're targeting the correct container port (8000 for HTTP,
  not 80).

- **IngressRoute not picking up the Service** — Traefik resolves
  `services[].name` in the IngressRoute's namespace by default. If the
  product chart deploys to a different namespace than the IngressRoute,
  add an explicit `namespace:` to the service entry.

- **NodePort unreachable from inside the cluster** — On kind, Traefik's
  NodePort is bound to the node's internal IP. Use the pod IP directly on
  port **8000** (not port 80) for HTTP and **8443** for HTTPS — the
  container's `web`/`websecure` entrypoints listen on these ports, while
  `web.exposedPort`/`websecure.exposedPort` only affect the Service's
  NodePort mapping.

- **Chart ingress uses hard-coded `ingressClassName: nginx`** — If the
  chart's Ingress template is not value-driven, Traefik won't pick it up.
  Disable the chart's ingress and use a raw_manifest IngressRoute instead.

- **Middleware applied but response unchanged** — Middleware must be attached
  to the IngressRoute rule via `middlewares: [{name: ..., namespace: ...}]`
  in the route spec. Creating a Middleware CR standalone has no effect.

- **TLS passthrough: cert mismatch** — In TLS passthrough mode, Traefik
  forwards the TCP stream without inspecting or terminating TLS. The
  certificate served to the client is the backend's certificate, NOT
  Traefik's default cert. Use `openssl s_client -servername <host>` with
  the correct SNI to verify.

- **CRD installation** — Starting with chart v28.3.0, Traefik CRDs are
  installed automatically via the Helm chart (no separate CRD manifest
  needed). If using an older chart version, you may need to install CRDs
  manually.

## References

- [Traefik Helm chart](https://github.com/traefik/traefik-helm-chart)
- [Traefik v3 IngressRoute docs](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/)
- [Traefik Middleware docs](https://doc.traefik.io/traefik/middlewares/overview/)
- [Traefik TCP routing docs](https://doc.traefik.io/traefik/routing/routers/#configuring-tcp-routers)
