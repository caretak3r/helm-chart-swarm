# NGINX Ingress Controller

## What

The NGINX Ingress Controller is the official Kubernetes ingress controller backed
by the Kubernetes SIGs project `kubernetes/ingress-nginx`. It uses NGINX as a
reverse proxy and load balancer to expose Services to external traffic via
classic `networking.k8s.io/v1` Ingress resources. It is the most widely deployed
ingress controller and supports a rich set of annotations for fine-grained
request handling.

The chart-test-swarm scenarios for NGINX Ingress verify that the consumer chart can:

1. Route HTTP traffic through the nginx controller using `ingressClassName: nginx`
2. Apply snippet annotations (`configuration-snippet`, `server-snippet`) for
   custom NGINX configuration injected directly into the generated nginx.conf
3. Use a custom default backend to serve distinctive content for unmatched hosts
4. Split traffic between stable and canary backends using canary annotations
5. Terminate TLS with a cert-manager-issued certificate (cross-feature compose)

## When

| Situation | Decision |
|---|---|
| Annotation-driven routing tweaks (CORS headers, rewrites) | NGINX Ingress with snippet annotations |
| Canary / blue-green traffic splitting | NGINX Ingress canary annotations (weight, header) |
| Custom default backend (branded error pages, catch-all) | NGINX Ingress defaultBackend config |
| Simple Host/path Ingress routing | NGINX Ingress (ingressClassName: nginx) — minimal config |
| TCP/UDP load balancing | NGINX Ingress ConfigMap with `tcp-services` / `udp-services` |
| CRD-based routing (IngressRoute/HTTPProxy/Gateway API) | Traefik, Contour, or envoy-gateway instead |
| Authentication & rate limiting at the proxy layer | NGINX Ingress with auth annotations + snippets |

**Key differentiator:** NGINX Ingress is annotation-driven and uses the standard
`networking.k8s.io/v1` Ingress resource. Unlike Traefik (IngressRoute CRD) or
Contour (HTTPProxy CRD), there is no custom CRD to learn — only annotations on
standard Ingress objects. However, snippet annotations require the controller
to be started with `allowSnippetAnnotations: true`, which is a security-sensitive
setting because malformed snippets can break the NGINX config.

## How

### Integration mechanism

NGINX Ingress watches standard `networking.k8s.io/v1` Ingress resources whose
`spec.ingressClassName` is `nginx`. For each Ingress, it generates an NGINX
`server{}` block with `location{}` directives derived from the Ingress rules.
Annotations on the Ingress object modify the generated configuration:
- `nginx.ingress.kubernetes.io/configuration-snippet` — injected into the
  `location{}` block
- `nginx.ingress.kubernetes.io/server-snippet` — injected into the `server{}` block
- `nginx.ingress.kubernetes.io/canary` + `canary-weight` — enable canary routing

### Probe pattern

All NGINX Ingress scenarios use in-cluster HTTP probes targeting the **nginx
controller pod IP** directly. The NGINX container listens on ports **80** (HTTP)
and **443** (HTTPS) — the same ports the Service exposes. The Host header is
always required because Ingress rules match on `host:`.

```bash
# From inside the cluster:
# HTTP on port 80
curl -H "Host: sample.test.local" http://<nginx-pod-ip>/

# HTTPS on port 443 (TLS scenarios)
curl -k --resolve sample.test.local:443:<nginx-pod-ip> https://sample.test.local/

# Without matching Host header: hits the default backend
curl http://<nginx-pod-ip>/
```

### Chart values wiring

The consumer chart (`examples/sample-product-chart/chart`) has an `ingress.*`
values block. For NGINX Ingress, the scenarios use the chart's built-in Ingress
template with:
```yaml
product:
  set:
    ingress.enabled: "true"
    ingress.className: "nginx"
    ingress.host: "sample.test.local"
```

## Cluster preinstall

```yaml
- kind: helm
  chart: ingress-nginx/ingress-nginx
  version: "4.10.0"
  release: ingress-nginx
  namespace: ingress-nginx
  repo:
    name: ingress-nginx
    url: "https://kubernetes.github.io/ingress-nginx"
  values:
    controller:
      service:
        type: NodePort
      allowSnippetAnnotations: true
      ingressClassResource:
        name: nginx
        enabled: true
        default: false
        controllerValue: "k8s.io/ingress-nginx"
      watchIngressWithoutClass: true
    admissionWebhooks:
      enabled: false
  wait: pods-ready
  wait_timeout: 3m
```

### Preinstall values rationale

| Setting | Why |
|---|---|
| `controller.service.type: NodePort` | Kind has no LoadBalancer; NodePort ensures the Service is reachable. |
| `controller.allowSnippetAnnotations: true` | Required for snippet-annotations variant; allows Ingress annotations that inject custom NGINX config. |
| `controller.ingressClassResource.default: false` | Avoids conflicts with Traefik or other ingress controllers that may be installed. |
| `controller.watchIngressWithoutClass: true` | The chart's Ingress may omit an explicit class; this ensures NGINX picks it up. |
| `admissionWebhooks.enabled: false` | Kind clusters may have limited resources; disabling the admission webhook reduces startup time. |

## Variants

| Variant | Scenario file | Mechanism | What it tests |
|---|---|---|---|
| Basic | `ingress-controllers-nginx-ingress-basic.yaml` | classic Ingress with `ingressClassName: nginx` | Host header routing, 200 from product Service, controller logs show matched request |
| Snippet annotations | `ingress-controllers-nginx-ingress-snippet-annotations.yaml` | `configuration-snippet` annotation | Custom `add_header` injected by snippet, X-Test header in response |
| Default backend | `ingress-controllers-nginx-ingress-default-backend.yaml` | Custom default backend Deployment+Service | Unmatched Host returns distinctive body from custom backend |
| Canary | `ingress-controllers-nginx-ingress-canary.yaml` | canary + canary-weight annotations | 20% traffic routed to canary backend |

All scenario YAMLs live under `examples/sample-product-chart/chart-test/scenarios/`.

Additionally, a cross-feature compose scenario:
| TLS + cert-manager | `ingress-controllers-nginx-ingress-tls-cert-manager.yaml` | cert-manager Certificate + nginx TLS Ingress | HTTPS 200 with cert chain rooted at ClusterIssuer CA |

### Shared scenario shape

Every NGINX Ingress variant shares:
- `cluster.preinstall[0]`: NGINX Ingress helm chart (identical across all variants)
- `product.chart: ./chart`, `product.release: sample`, `product.namespace: sample`
- `product.set.ingress.enabled: "true"`, `product.set.ingress.className: "nginx"`
- `mechanisms: [addon:nginx-ingress]` for dashboard rollup

Variants differ only in:
- Which `raw_manifest` preinstall items they include (custom ingress YAML, default-backend Deployment, canary Deployment)
- Additional `product.set` overrides
- Snippet or canary annotations on the Ingress resource

## Assertions

Each NGINX Ingress scenario uses a `smoke-script` assertion at
`chart-test/assertions/nginx-<variant>.sh`. The scripts:

1. Wait for nginx controller pod Ready (`kubectl -n ingress-nginx wait pod`)
2. Wait for product pod Ready
3. Get nginx controller pod IP via `kubectl -n ingress-nginx get pod -o jsonpath`
4. Run in-cluster curl probes through `kubectl run ... --image=quay.io/curl/curl`
5. Check HTTP status codes, response headers, and response bodies

For the canary variant, the script runs 100 sequential probes and counts how
many hit the canary backend vs the stable backend, verifying the ~20% split.

Additionally, `pods-ready` assertions for both `ingress-nginx` and `sample`
namespaces gate the smoke-script on controller and product availability.

## Known gotchas

- **`allowSnippetAnnotations` must be enabled** — By default the NGINX Ingress
  controller rejects Ingress objects with snippet annotations. The preinstall
  must set `controller.allowSnippetAnnotations: true`. If you see the Ingress
  stuck without an address, check the controller logs for snippet-denial messages.

- **Canary requires TWO Ingresses** — Canary routing in nginx-ingress requires
  a stable Ingress (the primary one) AND a canary Ingress (with the canary
  annotations) sharing the same host. Without the stable Ingress, the canary
  Ingress has nothing to split from.

- **Canary weight is approximate** — The `canary-weight` annotation sets the
  percentage of traffic, but the actual split over a small number of requests
  (e.g., 100 probes) can vary. For a weight of 20, expect 10–30 canary hits
  in 100 probes. Verification scripts should assert a range, not an exact count.

- **Default backend Service must exist** — The `--default-backend-service` flag
  resolves to `<namespace>/<name>` and must be passed via
  `controller.extraArgs.default-backend-service`. The custom default backend
  Service must be reachable from the controller namespace.

- **Chart defaults: `ingressClassName: nginx` but variable-driven** — The
  sample chart's `values.yaml` defaults `ingress.className: nginx`, which
  is correct. Scenarios explicitly set it via `product.set.ingress.className`
  for clarity.

- **`NodePort` on kind** — The controller Service type `NodePort` binds
  ports 80/443 on the node. In-cluster probes should use the pod IP directly
  (container ports 80/443), not the NodePort. This avoids port conflict with
  other services.

## References

- [NGINX Ingress Controller docs](https://kubernetes.github.io/ingress-nginx/)
- [NGINX Ingress Annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/)
- [Canary Annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#canary)
- [Custom Default Backend](https://kubernetes.github.io/ingress-nginx/user-guide/default-backend/)
- [Snippet Annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#configuration-snippet)
- [NGINX Ingress Helm chart](https://artifacthub.io/packages/helm/ingress-nginx/ingress-nginx)
