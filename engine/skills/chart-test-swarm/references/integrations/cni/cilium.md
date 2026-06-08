# Cilium CNI

## What

Cilium is an eBPF-based CNI (Container Network Interface) that provides
networking, observability, and security for Kubernetes clusters. Unlike
traditional CNI plugins that rely on iptables or IPVS for service routing,
Cilium replaces kube-proxy entirely with an eBPF datapath — every packet
from every pod is routed through eBPF programs attached to the kernel,
delivering lower latency, higher throughput, and L3/L4/L7 network policy
enforcement without a separate proxy daemonset.

The chart-test-swarm Cilium scenarios verify that the consumer chart can:

1. Operate on a cluster whose CNI is Cilium running in **full eBPF
   kube-proxy replacement** mode (kube-proxy fully removed, eBPF service
   datapath)
2. Route HTTP traffic through the **Cilium ingress controller** in
   dedicated loadbalancerMode (per-Ingress Service)
3. Respect **CiliumNetworkPolicy** (CNP) enforcement — allowing labeled
   clients while blocking unlabeled ones

Cilium-as-CNI is fundamentally different from other preinstall integrations:
with `disableDefaultCNI: true` the kind nodes never become Ready until a
CNI is installed, so Cilium must be installed **inside cluster bring-up,
before the node-ready wait** — it cannot be a `cluster.preinstall` item.
This is driven by a dedicated `cluster.cni` block in the scenario YAML and
a new CNI hook in `cluster-up.sh`.

## When

| Situation | Decision |
|---|---|
| Consumer chart must work without kube-proxy (eBPF-only datapath) | Cilium with kube-proxy replacement |
| Need L7 network policy (HTTP method, path, headers) | CiliumNetworkPolicy (extends NetworkPolicy) |
| Need an ingress controller with per-Ingress dedicated LoadBalancer Service | Cilium ingress controller in dedicated mode |
| Simple cluster with default kindnet CNI | Other scenarios suffice; cilium is nightly-only |
| Need observability (Hubble, flow logs, DNS visibility) | Cilium (Hubble is built-in but not tested in this primer) |
| Multi-cluster service routing or cluster mesh | Cilium ClusterMesh (not covered in this primer) |
| Gateway API conformance | Consider envoy-gateway or istio-gateway-api (Cilium Gateway API is beta) |

**Key differentiator:** Cilium is the only CNI in this test suite that
replaces kube-proxy. Every other integration assumes kube-proxy is present.
Cilium scenarios prove the chart works on a cluster where `kubectl -n
kube-system get ds kube-proxy` returns NotFound.

## How

### Integration mechanism

Cilium-as-CNI is installed **inside `cluster-up.sh`**, not as a preinstall
or post-install hook. The engine detects `cluster.cni.provider: cilium` in
the scenario YAML and:

1. Creates the kind cluster **without `--wait`** (nodes stay NotReady until
   CNI is present; `--wait 60s` would time out)
2. Resolves the control-plane IP on the kind Docker network via
   `docker inspect` — Cilium's kube-proxy replacement needs the real API
   server address, not `127.0.0.1`
3. Installs Cilium via `helm install` with kube-proxy replacement enabled
4. Waits for the Cilium daemonset rollout, then for all nodes to become Ready
5. Verifies `KubeProxyReplacement: True` and `kube-proxy` daemonset absence

### Verified install recipe (Cilium 1.19.4, kind)

```bash
# 1. Create cluster WITHOUT --wait (nodes stay NotReady)
kind create cluster --name chart-test-swarm-cilium --config kind-cilium.yaml

# 2. Resolve control-plane IP on the kind docker network
CONTROL_PLANE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' \
  chart-test-swarm-cilium-control-plane)

# 3. Add Cilium helm repo
helm repo add cilium https://helm.cilium.io
helm repo update

# 4. Install Cilium (kube-proxy replacement mode)
helm install cilium cilium/cilium --version 1.19.4 -n kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${CONTROL_PLANE_IP}" \
  --set k8sServicePort=6443 \
  --set operator.replicas=1 \
  --set ipam.mode=kubernetes

# 5. Wait for Cilium and nodes
kubectl -n kube-system rollout status ds/cilium
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# 6. Verify kube-proxy replacement
POD=$(kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec "$POD" -c cilium-agent -- cilium status | grep KubeProxyReplacement
# Expected: KubeProxyReplacement    True   [eth0 ... (Direct Routing)]
kubectl -n kube-system get ds kube-proxy
# Expected: Error from server (NotFound): daemonsets.apps "kube-proxy" not found
```

### In-cluster HTTP probes (no LoadBalancer on kind)

kind has no cloud LoadBalancer, so ingress and Service datapath verification
must be probed from **inside** the cluster. Use a real curl image:

```
quay.io/curl/curl:8.6.0
```

**Do NOT use `public.ecr.aws/docker/library/curl` — it does not exist.**
`curlimages/curl:8.6.0` is an acceptable alternative.

Pattern (from existing smoke scripts):

```bash
RAW=$(kubectl run curl-test --image=quay.io/curl/curl:8.6.0 --restart=Never \
  -i --rm -- curl -s -o /dev/null -w '%{http_code}' http://<svc-cluster-ip>:<port>/)
CODE=$(echo "$RAW" | grep -oE '[0-9]{3}' | tail -1)
```

### Reading cilium status (CLI is NOT installed)

The `cilium` CLI is not installed on this machine. Read Cilium status by
exec-ing into a cilium agent pod:

```bash
POD=$(kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec "$POD" -c cilium-agent -- cilium status
```

Grep for `KubeProxyReplacement:` — it should report `True` with the device
and mode (e.g., `True   [eth0 ... (Direct Routing)]`).

## Cluster prerequisites

### kind config

Cilium-as-CNI on kind requires a dedicated kind config with:

- `networking.disableDefaultCNI: true` — prevents kindnet from being
  installed; nodes stay NotReady until Cilium is installed
- `networking.kubeProxyMode: none` — required for full kube-proxy
  replacement; without this, kube-proxy is installed by kind and Cilium's
  kube-proxy replacement cannot take full effect

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
networking:
  disableDefaultCNI: true
  kubeProxyMode: none
```

Both settings are provided by the scenario's `cluster.config` field
pointing at the kind config fixture
(`examples/sample-product-chart/chart-test/fixtures/cni/kind-cilium.yaml`).
The engine never edits the kind config; it only references it.

### Cilium helm values (optional per-scenario)

Scenarios that require additional Cilium configuration (e.g., the ingress
controller) provide a values file via `cluster.cni.values`. For example,
the ingress scenario uses:

```yaml
ingressController:
  enabled: true
  loadbalancerMode: dedicated
  default: true
```

This enables the Cilium ingress controller in **dedicated** mode, which
creates a separate LoadBalancer Service per Ingress resource — the ideal
configuration for testing ingress routing through Cilium without a shared
proxy.

### Version pin

The Cilium chart version is pinned to `1.19.4`. Resolution order:
1. `CTS_CNI_VERSION` environment variable (highest precedence)
2. Project `chart-test/versions.yaml` under `cni.cilium.version`
3. Engine fallback (hardcoded `1.19.4` in `install-cilium.sh`)

The project versions file is `examples/sample-product-chart/chart-test/versions.yaml`:

```yaml
cni:
  cilium:
    chart: "cilium"
    version: "1.19.4"
    repo: "https://helm.cilium.io"
```

**Never add cilium to `engine/defaults/versions.yaml`** — that file is
read-only for this integration. The pin lives only in the project file plus
the hardcoded fallback.

## Variants

All scenario YAMLs live under
`examples/sample-product-chart/chart-test/scenarios/cni/`. The category is
`cni`, integration is `cilium`, tier is `live`, and all are tagged
`[nightly]`.

### cni-cilium-ebpf-kube-proxy-replacement

**Scenario file:** `cni-cilium-ebpf-kube-proxy-replacement.yaml`

Proves full eBPF kube-proxy replacement on kind. Cilium is installed with
`kubeProxyReplacement=true`. The scenario asserts:
- `KubeProxyReplacement: True` (read via `kubectl exec` into the cilium pod)
- No `kube-proxy` daemonset in `kube-system`
- The product chart's ClusterIP Service is reachable from an in-cluster
  curl pod, proving the eBPF service datapath routes traffic without
  kube-proxy.

### cni-cilium-ingress

**Scenario file:** `cni-cilium-ingress.yaml`

Exercises the Cilium ingress controller in **dedicated** loadbalancerMode.
Cilium is installed with the ingress controller enabled
(`ingressController.enabled=true`, `ingressController.loadbalancerMode=dedicated`,
`ingressController.default=true`). The product chart is configured with
`ingress.enabled=true`, `ingress.className=cilium`, and a test host
(`ingress.host=sample.test.local`). The scenario asserts that an in-cluster
HTTP probe to the dedicated per-Ingress Service with the matching Host
header reaches the product Service.

### cni-cilium-network-policy

**Scenario file:** `cni-cilium-network-policy.yaml`

Validates `CiliumNetworkPolicy` (CNP) enforcement. A `CiliumNetworkPolicy`
is applied as a `raw_manifest` preinstall, enforcing default-deny plus
allow-by-label ingress to the product Service. The smoke script deploys
two client pods: an ALLOWED client (label matches the CNP) and a DENIED
client (no matching label). It asserts that the allowed client can reach
the product while the denied client is blocked (connection times out or is
refused). This proves live policy enforcement through Cilium's eBPF
datapath.

### Shared scenario shape

Every Cilium scenario shares:
- `cluster.config`: points at `fixtures/cni/kind-cilium.yaml`
  (disableDefaultCNI + kubeProxyMode none, control-plane + worker)
- `cluster.cni.provider: cilium`
- `product.chart: ./chart`, `product.release: sample`,
  `product.namespace: sample`
- `tags: [nightly]` (these are heavyweight and run only on nightly cadence)

Variants differ in:
- `cluster.cni.kube_proxy_replacement` (true/false)
- `cluster.cni.values` (optional; ingress values for the ingress variant)
- `product.set` overrides (ingress enabled/disabled, className, host)
- `raw_manifest` preinstall items (CNP fixture for the network-policy variant)
- Smoke assert script referenced

## Assertions

Each Cilium scenario uses a `smoke-script` assertion at
`chart-test/assertions/cni/cilium-<variant>.sh`. The scripts:

1. Wait for Cilium pods Ready (`kubectl -n kube-system wait pod`)
2. For eBPF: read `cilium status` via `kubectl exec` and grep for
   `KubeProxyReplacement: True`
3. For eBPF: confirm `kubectl -n kube-system get ds kube-proxy` returns
   NotFound
4. For ingress: deploy an in-cluster curl pod and probe the per-Ingress
   Service with the matching Host header
5. For network-policy: deploy allowed and denied client pods, then verify
   allowed reaches the product and denied is blocked
6. Always cleanup curl/client pods after the probe

The assert `type` enum is unchanged — CiliumNetworkPolicy enforcement uses
the existing `smoke-script` assert type (no new assert type was added).

Additionally, `helm-status-deployed` and `pods-ready` assertions for both
`cilium` (in `kube-system`) and `sample` namespaces gate the smoke-script
on CNI and product availability.

## Known gotchas

- **`disableDefaultCNI: true` REQUIRES installing Cilium before the
  node-ready wait.** If you `kind create cluster --wait` with
  `disableDefaultCNI: true`, the command will hang indefinitely because
  nodes never become Ready without a CNI. Cilium is installed inside
  `cluster-up.sh` BEFORE the node-ready wait; it is never a
  `cluster.preinstall` item.

- **`kubeProxyMode: none` is required for full kube-proxy replacement.** If
  the kind config has `kubeProxyMode: iptables` (the default), kind
  installs kube-proxy and Cilium's kube-proxy replacement cannot fully
  replace it. Always set `networking.kubeProxyMode: none` in the kind
  config fixture.

- **`k8sServiceHost` MUST be the kind-network IP of the control-plane
  container, NOT `127.0.0.1`.** Cilium's kube-proxy replacement connects
  directly to the API server. On kind, the API server is accessible from
  pods via the Docker bridge network, not localhost. Use:
  ```bash
  docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${CLUSTER_NAME}-control-plane"
  ```
  The standard port is `6443`.

- **No LoadBalancer on kind → probe ingress/Service in-cluster.** kind has
  no cloud LoadBalancer controller. Do not attempt to reach a
  `type: LoadBalancer` Service from outside the cluster. Instead, probe
  via ClusterIP or per-Ingress Service from an in-cluster curl pod.

- **Curl image: `quay.io/curl/curl:8.6.0` or `curlimages/curl:8.6.0`.
  NEVER use `public.ecr.aws/docker/library/curl`** — that image does not
  exist and will cause `ErrImagePull` / `ImagePullBackOff`. This was the
  only failure in the planning readiness run; the Cilium eBPF datapath
  itself was fine.

- **`cilium` CLI is NOT installed on this machine.** Read Cilium status
  via `kubectl exec` into a cilium agent pod:
  ```bash
  kubectl -n kube-system exec <cilium-pod> -c cilium-agent -- cilium status
  ```
  Do not invoke `cilium` as a standalone binary — it's not available.

- **Cilium ingress controller in dedicated mode creates a Service per
  Ingress.** When using `loadbalancerMode=dedicated`, each Ingress gets
  its own Service of type LoadBalancer. On kind, this Service will have
  no external IP — use the ClusterIP of that per-Ingress Service for
  in-cluster probes.

- **CiliumNetworkPolicy requires the Cilium CRDs to be installed.** The
  `CiliumNetworkPolicy` CRD is installed automatically when Cilium is
  deployed via Helm. If the CRD is missing, the `raw_manifest` preinstall
  will fail with a "no matches for kind" error.

- **Every Cilium scenario runs live on a real kind cluster.** These are
  `tier: live` scenarios tagged `[nightly]` — they are heavyweight (~2-4
  minutes per cluster) and must tear down their cluster after the run.
  `kind get clusters` should show no `chart-test-swarm-*` entries after
  each scenario completes.

- **Cilium-as-CNI is supported on kind only in this engine.** Attempting
  `cluster.cni.provider: cilium` with a non-kind provider (minikube, k3d,
  etc.) will produce a clear error from `cluster-up.sh`. This is a
  deliberate scope boundary.

## References

- [Cilium documentation](https://docs.cilium.io/en/stable/)
- [Cilium Helm chart](https://github.com/cilium/cilium/tree/main/install/kubernetes/cilium)
- [Cilium Helm repository](https://helm.cilium.io)
- [Cilium kube-proxy replacement docs](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [Cilium ingress controller docs](https://docs.cilium.io/en/stable/network/servicemesh/ingress/)
- [CiliumNetworkPolicy reference](https://docs.cilium.io/en/stable/network/kubernetes/policy/)
- [kind — installing Cilium](https://docs.cilium.io/en/stable/installation/kind/)
- [eBPF overview](https://ebpf.io/what-is-ebpf/)
