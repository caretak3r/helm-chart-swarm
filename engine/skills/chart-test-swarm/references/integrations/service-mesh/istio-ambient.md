# Istio Ambient Mesh

Installs Istio in ambient mode (sidecar-less service mesh) with ztunnel node
proxies and waypoint proxies for L7 policy enforcement. The chart-test-swarm
scenarios verify that the consumer chart can:

1. Have its pods enrolled in the ambient mesh via namespace annotation
   (`istio.io/dataplane-mode: ambient`) without sidecar injection
2. Route traffic through ztunnel node proxies with transparent HBONE tunneling
3. Enforce L7 policies (AuthorizationPolicy, L7 telemetry) via waypoint proxies
4. Communicate securely with mTLS enforced by ztunnel without application changes

## What

Istio ambient mode is a sidecar-less data plane architecture introduced in
Istio 1.22+. Instead of injecting an Envoy sidecar into every pod, ambient
mode uses two components:

- **ztunnel** — A per-node DaemonSet that acts as a secure tunnel proxy. It
  handles L4 (TCP) traffic, provides mTLS, and tunnels traffic via HBONE
  (HTTP Connect over mTLS). Every node runs one ztunnel pod.
- **waypoint** — An optional per-namespace or per-service Deployment that
  provides L7 (HTTP) policy enforcement. Waypoints are Envoy-based proxies
  that apply AuthorizationPolicy, rate limits, and request-level telemetry.

Pods are enrolled in the ambient mesh by annotating their namespace with
`istio.io/dataplane-mode: ambient`. No pod-level annotation or sidecar
injection is required — the Istio CNI plugin intercepts pod traffic at the
node level and redirects it to ztunnel.

**Key distinction from sidecar mode:**
- Sidecar mode: per-pod Envoy sidecar via `istio-injection=enabled` namespace label
- Ambient mode: per-node ztunnel via `istio.io/dataplane-mode: ambient` namespace annotation

Both modes can coexist in the same cluster. This primer focuses exclusively
on ambient mode.

## When

Use these scenarios when validating that a Helm chart:

- Correctly works with ambient mesh enrollment (namespace annotation, no sidecar)
- Does not require sidecar injection for mesh functionality
- Supports L4 mTLS through ztunnel node proxies
- Optionally requires L7 policy enforcement via waypoint proxies
- Needs to verify that pod-to-pod traffic is captured by the ambient mesh

**When NOT to use ambient scenarios:**
- The chart requires sidecar-specific features (e.g., `istio-proxy` container
  introspection, per-pod proxy config)
- The chart needs `istio-init` container capabilities (ambient mode has no init
  container)
- The Kubernetes cluster version is below 1.28 (ambient requires Gateway API
  CRDs and CNI plugin support)

## How

### Integration mechanism

Ambient mode enrollment works through three layers:

1. **Istio CNI** — Installed as a DaemonSet. Detects pods in namespaces with
   `istio.io/dataplane-mode: ambient` annotation and configures iptables rules
   on the node to redirect pod traffic to ztunnel.
2. **ztunnel DaemonSet** — Runs on every node. Accepts redirected traffic from
   the CNI, establishes mTLS connections, and tunnels traffic via HBONE to the
   destination ztunnel.
3. **waypoint Deployment** (optional) — Created per-namespace or per-service.
   Handles L7 (HTTP) policies. Traffic is redirected from ztunnel to the
   waypoint for policy evaluation before reaching the destination.

### Probe pattern

Ambient scenarios verify mesh enrollment and traffic flow:

```bash
# Verify namespace is enrolled in ambient mesh:
kubectl get namespace <product-ns> -o jsonpath='{.metadata.annotations.istio\.io/dataplane-mode}'

# Verify ztunnel pods are running:
kubectl -n istio-system get pods -l app=ztunnel

# Verify CNI pods are running:
kubectl -n istio-system get pods -l app=istio-cni-node

# In-cluster probe through the ambient mesh:
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- \
  curl -sf http://sample.sample.svc.cluster.local/

# Verify mTLS by inspecting ztunnel connections:
kubectl -n istio-system exec -c istio-proxy <ztunnel-pod> -- \
  pilot-agent request GET config_dump | grep sample
```

### Chart values wiring

The consumer chart (`examples/sample-product-chart/chart`) needs NO values
changes for ambient enrollment — the mesh is applied at the namespace level
via annotation, not via pod injection. However, the scenario should ensure:

- `ingress.enabled: "false"` if a separate Gateway is used (as with istio
  ingress gateway scenarios)
- Service port is discoverable for VirtualService routing

## Cluster preinstall

Ambient mode requires four Helm chart installations in order:

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

# Step 2: istiod control plane (ambient profile)
- kind: helm
  chart: istio/istiod
  version: 1.27.9
  release: istiod
  namespace: istio-system
  repo:
    name: istio
    url: "https://istio-release.storage.googleapis.com/charts"
  values:
    profile: ambient
    pilot:
      resources:
        requests:
          cpu: "100m"
          memory: "384Mi"
  wait: pods-ready
  wait_timeout: 5m

# Step 3: CNI node agent (ambient profile)
- kind: helm
  chart: istio/cni
  version: 1.27.9
  release: istio-cni
  namespace: istio-system
  repo:
    name: istio
    url: "https://istio-release.storage.googleapis.com/charts"
  values:
    profile: ambient
  wait: pods-ready
  wait_timeout: 3m

# Step 4: ztunnel DaemonSet (node proxy)
- kind: helm
  chart: istio/ztunnel
  version: 1.27.9
  release: ztunnel
  namespace: istio-system
  repo:
    name: istio
    url: "https://istio-release.storage.googleapis.com/charts"
  values: {}
  wait: pods-ready
  wait_timeout: 3m
```

After all components are Ready, annotate the product namespace for ambient enrollment:

```bash
kubectl annotate namespace <product-ns> istio.io/dataplane-mode=ambient --overwrite
```

This annotation MUST be applied BEFORE the product chart is installed. The CNI
plugin intercepts pod creation events and configures traffic redirection at
pod creation time. Existing pods must be restarted to be captured:

```bash
kubectl -n <product-ns> rollout restart deployment
```

For L7 policy variants, also create a waypoint proxy. Apply this as a
`raw_manifest` preinstall item:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: <product-ns>
  annotations:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - port: 15008
      protocol: HBONE
      allowedRoutes:
        namespaces:
          from: Same
```

The Gateway API CRDs must be installed before applying the waypoint:

```bash
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
  kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml
```

### Preinstall values rationale

| Setting | Why |
|---|---|
| `profile: ambient` on istiod | Configures istiod for ambient mode (disables sidecar injection features not needed) |
| `profile: ambient` on CNI | Configures CNI to detect ambient-annotated namespaces and redirect traffic to ztunnel |
| Four-chart install order | base → istiod → cni → ztunnel is required; each depends on CRDs/components from the prior |
| `pilot.resources.requests` | Reduced footprint for kind clusters |

## Variants

| Variant | Scenario file | Mechanism | What it tests |
|---|---|---|---|
| **ztunnel-basic** | `service-mesh-istio-ambient-ztunnel-basic.yaml` | Namespace annotation + ztunnel | Pods enrolled in ambient mesh via annotation; traffic flows through ztunnel with mTLS; no sidecars present |
| **waypoint-l7** | `service-mesh-istio-ambient-waypoint-l7.yaml` | ztunnel + waypoint Gateway | L7 AuthorizationPolicy applied via waypoint; HTTP-level access control enforced; waypoint proxy routes traffic |
| **mixed-mode** | `service-mesh-istio-ambient-mixed-mode.yaml` | Ambient + sidecar coexistence | Some namespaces use ambient, others use sidecar injection; cross-mode communication works with mTLS |

All scenario YAMLs live under `examples/sample-product-chart/chart-test/scenarios/service-mesh/`.

### Shared scenario shape

Every ambient variant shares:
- `cluster.preinstall[0-3]`: Istio base, istiod (ambient), CNI (ambient), ztunnel
- `product.chart: ./chart`, `product.release: sample`, `product.namespace: sample`
- Namespace annotated with `istio.io/dataplane-mode=ambient` before product install
- `mechanisms: [addon:istio-ambient]` for dashboard rollup

The waypoint variant additionally:
- Installs Gateway API CRDs as a `raw_manifest` preinstall
- Creates a waypoint Gateway via `raw_manifest`
- Applies AuthorizationPolicy via `raw_manifest`

## Feasibility checklist for the consumer chart

**Required:**
- [ ] Chart has at least one Service — ztunnel routes traffic to Services by
  FQDN; without a Service, ambient mesh has no backend to route to.
- [ ] No `hostNetwork: true` on any pod template — host-network pods share the
  host's network namespace; the CNI traffic redirection rules have no effect.
  The pod silently bypasses the mesh with no error.
- [ ] Kubernetes version ≥ 1.28 — ambient mode requires Gateway API CRDs and
  CNI features not available in earlier versions.

**Soft:**
- [ ] Chart does not use Jobs or CronJobs — Job pods in the ambient mesh
  are captured by ztunnel like any other pod, so this is not a hard blocker
  (unlike sidecar mode where Envoy keeps the pod alive).
- [ ] Chart does not require `istio-init` capabilities — ambient mode has no
  init container. Charts that depend on `istio-init` for iptables rules will
  not work in ambient mode.
- [ ] Chart does not use `hostPID: true` or `hostIPC: true` — these share host
  namespaces, which can interfere with CNI traffic capture.

## Assertions

Each ambient scenario uses assertion scripts that:

1. Wait for istiod, CNI, and ztunnel pods Ready
2. Verify the product namespace has the `istio.io/dataplane-mode: ambient`
   annotation
3. Wait for product pod Ready
4. Verify product pods have NO `istio-proxy` sidecar container (ambient mode
   has no sidecar)
5. Run in-cluster curl to the product Service and verify HTTP 200
6. Verify traffic was captured by ztunnel (via ztunnel connection logs or
   `istioctl proxy-config`)

For waypoint-l7 variant:
7. Verify the waypoint Gateway exists and has an Accepted condition
8. Verify AuthorizationPolicy is enforced (allowed routes succeed, denied
   routes return 403)

## Known gotchas

- **`istio.io/dataplane-mode` is an annotation, NOT a label** — Ambient
  enrollment uses `metadata.annotations`, not `metadata.labels`. Setting
  `istio.io/dataplane-mode: ambient` as a label has no effect. Verify with:
  `kubectl get ns <ns> -o jsonpath='{.metadata.annotations.istio\.io/dataplane-mode}'`.

- **CNI requires `NET_ADMIN` capabilities on kind nodes** — The Istio CNI
  plugin needs `NET_ADMIN` to configure iptables rules. Kind nodes support
  this by default, but if capabilities are restricted, CNI will fail
  silently and pods will bypass the mesh.

- **Gateway API CRDs must be installed before waypoint** — The waypoint
  Gateway uses `gateway.networking.k8s.io/v1` Gateway CRD. If Gateway API
  CRDs are not installed, `kubectl apply` of the waypoint returns an error.
  Install with the command shown in the preinstall section.

- **ztunnel DNS resolution lag** — ztunnel uses DNS-based service discovery
  for HBONE tunneling. After a new pod is created, there may be a 1-5 second
  delay before ztunnel can resolve the pod's IP via DNS. If the first probe
  fails, retry after 5 seconds.

- **Ambient + sidecar coexistence** — Both modes can coexist in the same
  cluster. Namespaces with `istio-injection=enabled` (label) get sidecars;
  namespaces with `istio.io/dataplane-mode=ambient` (annotation) get ztunnel.
  Do NOT set both on the same namespace — the behavior is undefined.

- **Waypoint proxy creates an additional hop** — Traffic from ztunnel to the
  destination pod goes through the waypoint proxy, adding one network hop.
  This increases latency by ~1-5ms per request. For test scenarios this is
  acceptable, but it means the waypoint variant should not be used for
  latency-sensitive benchmarks.

- **Istio version pinning** — All four Helm charts (base, istiod, cni, ztunnel)
  MUST use the same version. Version skew between components causes
  compatibility errors. Pin to `1.27.9` across all preinstall items.

- **`istio/gateway` chart is NOT required for ambient** — The `istio/gateway`
  chart deploys an ingress gateway (for receiving external traffic). Ambient
  mesh only needs istiod + CNI + ztunnel for in-mesh communication. If you
  also need external ingress, add the gateway chart separately.

## References

- [Istio ambient installation with Helm](https://istio.io/latest/docs/ambient/install/helm/)
- [Istio ambient architecture](https://istio.io/latest/docs/ambient/architecture/data-plane/)
- [ztunnel overview](https://istio.io/latest/docs/ambient/architecture/ztunnel/)
- [Waypoint proxy](https://istio.io/latest/docs/ambient/usage/l7-features/)
- [Gateway API CRD installation](https://istio.io/latest/docs/ambient/install/helm/#install-or-upgrade-the-kubernetes-gateway-api-crds)
- [Ambient getting started](https://istio.io/latest/docs/ambient/getting-started/)
