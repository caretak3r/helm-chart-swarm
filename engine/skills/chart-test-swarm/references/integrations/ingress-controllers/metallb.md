# MetalLB — Bare-Metal LoadBalancer

## What

MetalLB is a load-balancer implementation for bare-metal Kubernetes clusters
(using standard routing protocols). On cloud platforms, Kubernetes
`Service.type: LoadBalancer` automatically provisions a cloud load balancer.
On bare-metal clusters (including kind and minikube), no such controller exists
by default — `LoadBalancer` Services remain in a perpetual `Pending` state.

MetalLB fills this gap by assigning IPs from a configurable pool to
`LoadBalancer` Services and advertising them via Layer 2 (ARP/NDP) or BGP.
The chart-test-swarm scenarios for MetalLB verify that the consumer chart can:

1. Deploy MetalLB controller + speaker on a kind cluster
2. Configure an `IPAddressPool` and `L2Advertisement` whose CIDR is inside
   the kind Docker bridge subnet
3. Deploy the product chart with `service.type: LoadBalancer` and have MetalLB
   assign an external IP from the pool
4. Prove the LoadBalancer endpoint serves traffic (200)

## When

| Situation | Decision |
|---|---|
| Bare-metal / kind / minikube cluster needs `LoadBalancer` Services | MetalLB with IPAddressPool + L2Advertisement |
| Cloud cluster with built-in LB | No MetalLB needed — cloud controller handles it |
| Need BGP-based load balancing (multi-path, ECMP) | MetalLB with BGP mode (advanced, not covered in M15) |
| Simple ARP-based LB with a single IP pool | MetalLB L2 mode (this primer) |
| Multiple IP pools with different subnets | MetalLB with multiple IPAddressPool resources |

**Key differentiator:** MetalLB is the only way to test `service.type:
LoadBalancer` scenarios on kind/minikube. Without it, any scenario that sets
`service.type: LoadBalancer` will hang in `Pending` state with no external IP.

## How

### Integration mechanism

MetalLB operates in two modes:
- **Layer 2 mode** — A single node responds to ARP/NDP requests for the
  LoadBalancer IP. Traffic is sent to one node, then kube-proxy distributes
  to pods. This is the simplest mode and what M15 scenarios use.
- **BGP mode** — Each speaker advertises the LoadBalancer IP to BGP peers.
  Requires an external BGP router. Not used in M15 scenarios.

MetalLB watches for `Service.type: LoadBalancer` resources. When one appears,
the controller allocates an IP from the matching `IPAddressPool` and the
speaker on the appropriate node begins advertising it via ARP.

### Probe pattern

All MetalLB scenarios verify that MetalLB has assigned an external IP to the
product Service and that the endpoint serves traffic:

```bash
# Check MetalLB has assigned an IP:
kubectl -n sample get svc sample -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Probe the assigned IP from inside the cluster:
LB_IP=$(kubectl -n sample get svc sample -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sf --max-time 10 "http://${LB_IP}/"

# Verify IPAddressPool exists:
kubectl get ipaddresspool -n metallb

# Verify L2Advertisement exists:
kubectl get l2advertisement -n metallb
```

### Chart values wiring

The consumer chart (`examples/sample-product-chart/chart`) has a `service.*`
values block. For MetalLB, set `service.type: LoadBalancer`. The chart must
expose `service.type` as a value override — if it hardcodes `ClusterIP`,
MetalLB cannot assign an external IP and the scenario will fail.

## Cluster preinstall

```yaml
- kind: helm
  chart: metallb/metallb
  version: 0.16.1
  release: metallb
  namespace: metallb
  repo:
    name: metallb
    url: "https://metallb.github.io/metallb"
  values:
    controller:
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
    speaker:
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
    installCRDs: true
  wait: pods-ready
  wait_timeout: 3m
```

After MetalLB is installed, apply an IPAddressPool and L2Advertisement as a
`raw_manifest` preinstall item. The CIDR must be within the kind Docker
bridge subnet (typically `172.18.0.0/16` or `172.17.0.0/16`):

```yaml
- kind: raw_manifest
  path: chart-test/fixtures/networking/metallb-ip-pool.yaml
  namespace: metallb
```

The fixture file contains:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: chart-test-pool
  namespace: metallb
spec:
  addresses:
    - "172.18.255.200-172.18.255.250"
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: chart-test-l2
  namespace: metallb
spec:
  ipAddressPools:
    - chart-test-pool
```

> **Note on CIDR selection:** The IP pool range must be routable from within
> the kind cluster. On Docker Desktop, the kind network bridge typically uses
> `172.18.0.0/16`. Use `docker network inspect kind` to find the actual
> subnet and choose a high-range slice (e.g., `172.18.255.200-250`) that is
> unlikely to conflict with running containers. The fixture file should be
> parameterized or documented so scenario authors can adjust the range.

### Preinstall values rationale

| Setting | Why |
|---|---|
| `installCRDs: true` | Ensures IPAddressPool and L2Advertisement CRDs are created before applying the raw_manifest |
| `controller.resources` / `speaker.resources` | Reduced footprint for kind clusters (4 CPU / 16 GiB Docker limit) |
| `namespace: metallb` | MetalLB's default namespace; the IPAddressPool and L2Advertisement must be in the same namespace |

## Variants

| Variant | Scenario file | Mechanism | What it tests |
|---|---|---|---|
| Basic LoadBalancer | `networking-metallb-loadbalancer.yaml` | Service.type=LoadBalancer + IPAddressPool + L2Advertisement | MetalLB assigns external IP; in-cluster curl to LB IP returns 200 |
| Multiple IP pools | `networking-metallb-multi-pool.yaml` | Multiple IPAddressPools + L2Advertisement | Services in different pools receive IPs from the correct pool |

All scenario YAMLs live under `examples/sample-product-chart/chart-test/scenarios/networking/`.

### Shared scenario shape

Every MetalLB variant shares:
- `cluster.preinstall[0]`: MetalLB helm chart
- `cluster.preinstall[1]`: raw_manifest with IPAddressPool + L2Advertisement
- `product.chart: ./chart`, `product.release: sample`, `product.namespace: sample`
- `product.set.service.type: LoadBalancer`
- `mechanisms: [addon:metallb]` for dashboard rollup

## Assertions

Each MetalLB scenario uses assertion scripts that:

1. Wait for MetalLB controller + speaker pods Ready
2. Verify `IPAddressPool` and `L2Advertisement` CRs exist
3. Wait for product pod Ready
4. Wait for the product Service to have an assigned external IP
   (`status.loadBalancer.ingress[0].ip` is non-empty, timeout 60s)
5. Run in-cluster curl to the assigned LB IP and verify HTTP 200

## Known gotchas

- **IP pool CIDR must be inside the kind Docker bridge subnet** — If the
  `IPAddressPool.spec.addresses` range is outside the Docker network, MetalLB
  will assign the IP but it will not be routable from inside the cluster.
  Use `docker network inspect kind` to find the actual subnet. The default
  `172.18.255.200-172.18.255.250` range works on most Docker Desktop
  installations.

- **`Service.status.loadBalancer.ingress` is eventually-consistent** — After
  creating a `LoadBalancer` Service, MetalLB takes 1-5 seconds to allocate
  an IP and update the Service status. Scenarios must poll for the IP rather
  than assuming it is immediately available.

- **L2 mode is single-node** — In Layer 2 mode, traffic is sent to a single
  node (the one that wins the ARP response). This is not a real load balancer
  — it's a failover-capable single-node entry point. For testing purposes
  this is sufficient, but do not expect true load distribution.

- **CRD version** — MetalLB v0.13+ uses `metallb.io/v1beta1` API for
  IPAddressPool and L2Advertisement. Earlier versions used a different API.
  The helm chart v0.16.x installs the correct CRDs automatically.

- **Speaker DaemonSet on every node** — MetalLB speaker runs as a DaemonSet
  on every schedulable node. On kind clusters with 1 control-plane node,
  this is a single pod. If the speaker pod is not Ready on the node with
  the LoadBalancer IP, ARP advertisements will not work.

- **Kind cluster network varies** — The Docker bridge subnet used by kind
  can vary depending on Docker Desktop configuration and other networks
  already allocated. Always verify with `docker network inspect kind` before
  relying on a hardcoded CIDR in the IP pool.

- **MetalLB webhook requires CRDs first** — The helm chart installs CRDs
  via hooks. The webhook configuration references these CRDs. If applying
  an IPAddressPool via `raw_manifest` immediately after `helm install`,
  wait for the CRD `Established` condition before applying:
  `kubectl wait --for condition=Established crd/ipaddresspools.metallb.io`.

## References

- [MetalLB installation docs](https://metallb.universe.tf/installation/)
- [MetalLB Helm chart](https://artifacthub.io/packages/helm/metallb/metallb)
- [MetalLB IPAddressPool API](https://metallb.universe.tf/configuration/#address-pools)
- [MetalLB L2 mode](https://metallb.universe.tf/concepts/layer2/)
- [Kind LoadBalancer guide](https://kind.sigs.k8s.io/docs/user/loadbalancer/)
