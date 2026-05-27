# istio-service-mesh

Installs Istio as a service mesh (control plane + data-plane sidecar injection).
The chart-test-swarm scenario generated against this primer verifies that the
consumer chart can:
1. Have its pods receive an Envoy sidecar via automatic namespace-level injection
2. Survive the `istio-init` container + iptables redirect without init failures
3. Communicate pod-to-pod after `PeerAuthentication: STRICT` mTLS is enforced

## Cluster preinstall

```yaml
- chart: istio/base
  version: 1.22.0
  release: istio-base
  namespace: istio-system
  repo:
    name: istio
    url: "https://istio-release.storage.googleapis.com/charts"
  values: {}
  wait: helm-deployed
  wait_timeout: 2m
- chart: istio/istiod
  version: 1.22.0
  release: istiod
  namespace: istio-system
  repo:
    name: istio        # already registered above
    url: "https://istio-release.storage.googleapis.com/charts"
  values:
    pilot:
      resources:
        requests: { cpu: "100m", memory: "256Mi" }
    global:
      proxy:
        resources:
          requests: { cpu: "50m", memory: "64Mi" }
          limits:  { cpu: "200m", memory: "128Mi" }
      proxy_init:
        resources:
          limits: { cpu: "100m", memory: "50Mi" }
  wait: pods-ready
  wait_timeout: 5m
```

After istiod is ready, label the product namespace for injection:
```bash
kubectl label namespace <product-ns> istio-injection=enabled --overwrite
```

This label must be applied BEFORE `helm install` of the product chart; the
mutating webhook only fires on new pods, not existing ones. If the chart is
already installed without the label, do a `helm upgrade` to cycle the pods.

## Feasibility checklist for the consumer chart

**Required:**
- [ ] No `hostNetwork: true` on any pod template — host-network pods share the
  host's network namespace; the iptables redirect rules installed by `istio-init`
  have no effect on them. The pod silently bypasses the mesh with no error.
  This is not a fixable-via-values issue — it requires a chart change.
- [ ] Chart has at least one pod-owning kind (Deployment / StatefulSet / DaemonSet) — no pods, no sidecars, no scenario.

**Soft:**
- [ ] Pod annotations are value-driven — lets us set `sidecar.istio.io/inject`
  annotations per workload via override.
- [ ] Chart has no Jobs or CronJobs — Job pods with injected sidecars never
  complete (Envoy keeps running after the main container exits). Jobs require
  explicit opt-out via `sidecar.istio.io/inject: "false"` on the Job pod
  template; if annotations are not value-driven, this can't be set via override.
- [ ] No init containers that require network connectivity before `istio-init`
  finishes — `istio-init` rewrites iptables first; any init container that
  does a DNS lookup or HTTP call before `istio-proxy` is ready will time out.
- [ ] Chart does not use `hostPID: true` or `hostIPC: true` — these share
  namespaces in ways that interact poorly with sidecar network namespace isolation.

## Standard values-override pattern

```yaml
chartTestSwarm:
  enabled: true              # gates the helm-test pod

# No special values are needed for basic sidecar injection — istiod handles
# it via the namespace label. Main concern: Jobs must opt out.

# If the chart exposes pod annotations, make injection explicit:
podAnnotations:
  sidecar.istio.io/inject: "true"

# If the chart has Jobs (check templates/*.yaml for kind: Job), add:
# jobAnnotations:
#   sidecar.istio.io/inject: "false"
# This requires the chart to expose job-level podAnnotations. If it doesn't,
# report a soft finding: "chart has Jobs but cannot opt out of injection via
# values — risk of Job pods never completing in mesh namespaces."

# Resource limits: the istio-proxy sidecar runs with its OWN resource spec
# (set in istiod values above). Product container limits don't need changes,
# but the node needs capacity for the extra sidecar per pod.
```

## Standard helm-test pattern

```yaml
{{- if .Values.chartTestSwarm.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: "{{ .Release.Name }}-ct-istio-mesh-setup"
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": hook-succeeded
data:
  mtls.yaml: |
    apiVersion: security.istio.io/v1beta1
    kind: PeerAuthentication
    metadata:
      name: {{ .Release.Name }}-mtls
      namespace: {{ .Release.Namespace }}
    spec:
      mtls: { mode: STRICT }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: "{{ .Release.Name }}-ct-istio-mesh"
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: "{{ .Release.Name }}-ct-istio-mesh"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
rules:
  - apiGroups: ["security.istio.io"]
    resources: ["peerauthentications"]
    verbs: ["create", "get", "list", "delete"]
  - apiGroups: [""]
    resources: ["pods", "pods/exec"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: "{{ .Release.Name }}-ct-istio-mesh"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
subjects:
  - kind: ServiceAccount
    name: "{{ .Release.Name }}-ct-istio-mesh"
    namespace: {{ .Release.Namespace }}
roleRef:
  kind: ClusterRole
  name: "{{ .Release.Name }}-ct-istio-mesh"
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: "{{ .Release.Name }}-ct-istio-mesh-test"
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/component: chart-test-swarm
    integration: istio-service-mesh
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": hook-succeeded
    sidecar.istio.io/inject: "true"   # test pod itself is IN the mesh for mTLS probe
spec:
  serviceAccountName: {{ .Release.Name }}-ct-istio-mesh
  restartPolicy: Never
  containers:
    - name: probe
      image: bitnami/kubectl:1.30
      command: ["sh", "-c"]
      args:
        - |
          set -eu
          echo "==> Applying PeerAuthentication (mTLS STRICT)"
          kubectl apply -f /setup/mtls.yaml
          echo "==> Verifying sidecar injected into product pods"
          PODS=$(kubectl -n {{ .Release.Namespace }} get pods \
            -l app.kubernetes.io/name={{ .Release.Name }} \
            -o jsonpath='{.items[*].metadata.name}')
          for POD in $PODS; do
            CONTAINERS=$(kubectl -n {{ .Release.Namespace }} get pod "$POD" \
              -o jsonpath='{.spec.containers[*].name}')
            echo "$CONTAINERS" | grep -q "istio-proxy" || {
              echo "FAIL: Pod $POD missing istio-proxy sidecar (check namespace label)"
              exit 1
            }
            echo "  ✓ $POD has istio-proxy sidecar"
          done
          echo "==> Verifying intra-mesh communication under mTLS STRICT"
          PRODUCT_SVC="{{ .Release.Name }}.{{ .Release.Namespace }}.svc.cluster.local"
          PRODUCT_PORT="{{ .Values.service.port | default 80 }}"
          curl -sf --max-time 15 "http://${PRODUCT_SVC}:${PRODUCT_PORT}/" -o /dev/null \
            && echo "  ✓ mTLS STRICT: intra-mesh request succeeded"
          echo "PASS: istio service mesh integration verified"
      volumeMounts:
        - { name: setup, mountPath: /setup }
  volumes:
    - name: setup
      configMap:
        name: "{{ .Release.Name }}-ct-istio-mesh-setup"
{{- end }}
```

## Common failure modes

- **`PodInitializing` forever — `istio-init` fails** → `istio-init` needs
  `NET_ADMIN` and `NET_RAW` capabilities to rewrite iptables. On kind clusters
  with restricted capabilities, this fails silently: the pod stays in
  `PodInitializing`. Fix: use Istio CNI mode (`--set cni.enabled=true` in istiod
  values), which moves iptables injection into the CNI plugin and removes the
  init container requirement. This is the canonical fix for kind-based istio.
  Failure signal: `kubectl describe pod` shows `istio-init` in `Init:Error` or
  `Init:CrashLoopBackOff`.

- **Job pods never complete** → Envoy sidecar keeps the pod alive after the
  main container exits. Jobs hang indefinitely in `Running` state. Fix:
  annotate Job pod templates with `sidecar.istio.io/inject: "false"`. If the
  chart doesn't expose this via values, it's a chart limitation — document as
  a soft finding.

- **mTLS STRICT blocks test pod** → If the helm-test pod itself isn't in the
  mesh (no sidecar), it cannot communicate with mesh-members under STRICT mTLS.
  The standard pattern injects the test pod via `sidecar.istio.io/inject: "true"`.
  If the namespace label is missing, the annotation is ignored. Verify:
  `kubectl -n <ns> get pod <test-pod> -o jsonpath='{.spec.containers[*].name}'`
  should include `istio-proxy`.

- **Product pods running without sidecar (istiod not ready at install time)** →
  If the product chart was installed before istiod pods were fully ready, the
  mutating webhook call timed out and pods started without a sidecar. Fix:
  `helm upgrade` the product chart to cycle pods through the now-ready webhook.

- **`hostNetwork: true` pod silently bypasses mesh** → No runtime error; the
  pod communicates outside the mesh transparently. The feasibility check flags
  this as IMPOSSIBLE. If it slips through, the sidecar IS injected but iptables
  rules have no effect. Verify: `kubectl exec -n <ns> <pod> -c istio-proxy
  -- pilot-agent request GET stats | grep cx_active` — will show 0 connections
  if bypassed.

- **Init containers fail with DNS/HTTP errors** → If a product init container
  makes network calls before `istio-proxy` is ready, it fails because iptables
  redirects the traffic to the proxy, which isn't up yet. Fix: set
  `global.proxy.holdApplicationUntilProxyStarts: true` in istiod values. This
  holds all containers (including init containers) until Envoy's `/healthz/ready`
  responds. Adds ~1s to startup universally.
