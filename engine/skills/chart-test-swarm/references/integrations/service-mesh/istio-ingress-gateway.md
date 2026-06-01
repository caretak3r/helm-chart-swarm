# istio-ingress-gateway

Installs Istio with the dedicated ingress gateway component. The scenario
verifies that the consumer chart's Services can be reached from outside the
mesh via Istio's Gateway CR + VirtualService routing.

**Critical disambiguation:** Two different "Gateway" CRDs may coexist:
- `networking.istio.io/v1beta1 Gateway` — classic Istio gateway **(this primer)**
- `gateway.networking.k8s.io/v1 Gateway` — Kubernetes Gateway API (see `gateway-api.md` primer)

Always qualify `apiVersion` explicitly. Applying a `kind: Gateway` without the
full apiVersion when both CRDs are present creates a resource the wrong controller
reconciles — silently.

## Cluster preinstall

Istiod is required even for ingress-only deployments (the ingressgateway pods
are managed by the istiod control plane). Builds on `istio-service-mesh` preinstall;
add the gateway component as a third step.

```yaml
- chart: istio/base
  version: 1.27.9
  release: istio-base
  namespace: istio-system
  repo:
    name: istio
    url: "https://istio-release.storage.googleapis.com/charts"
  values: {}
  wait: helm-deployed
  wait_timeout: 2m
- chart: istio/istiod
  version: 1.27.9
  release: istiod
  namespace: istio-system
  values:
    pilot:
      resources:
        requests: { cpu: "100m", memory: "384Mi" }
  wait: pods-ready
  wait_timeout: 5m
- chart: istio/gateway
  version: 1.27.9
  release: istio-ingressgateway
  namespace: istio-system
  repo:
    name: istio
    url: "https://istio-release.storage.googleapis.com/charts"
  values:
    service:
      type: NodePort             # kind has no cloud LB
      ports:
        - name: http2
          port: 80
          nodePort: 30080
        - name: https
          port: 443
          nodePort: 30443
  wait: pods-ready
  wait_timeout: 3m
```

## Feasibility checklist for the consumer chart

**Required:**
- [ ] Chart exposes at least one Service — VirtualService `route[].destination.host`
  references a Service FQDN; without a Service there is no backend to route to.
- [ ] Service port is discoverable — either exposed via values or deterministic
  from the chart's Service spec (VirtualService route must specify a port number).

**Soft:**
- [ ] Chart already has an Ingress or IngressRoute concept — indicates the team
  expects external routing; an istio gateway scenario is a natural extension.
- [ ] Service name is value-driven / follows `<release>` convention — non-
  deterministic service names require a manual override in the VirtualService.
- [ ] Chart does NOT already define `networking.istio.io` Gateway or
  VirtualService resources — if it does, this scenario should TEST those existing
  resources rather than create duplicates (different scenario shape).

## Standard values-override pattern

```yaml
chartTestSwarm:
  enabled: true              # gates the helm-test pod

# The consumer chart needs no values changes for istio ingress routing —
# Gateway + VirtualService are cluster-level objects written at runtime.
# Only disable chart-side Ingress to avoid routing conflicts.

ingress:
  enabled: false             # disable classic Ingress; use VirtualService

# Expose the service port if the chart's values support it:
service:
  port: 80                   # the HTTP port the product Service exposes
```

## Standard helm-test pattern

```yaml
{{- if .Values.chartTestSwarm.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: "{{ .Release.Name }}-ct-istio-igw-setup"
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": hook-succeeded
data:
  routing.yaml: |
    apiVersion: networking.istio.io/v1beta1
    kind: Gateway
    metadata:
      name: {{ .Release.Name }}-igw
      namespace: {{ .Release.Namespace }}
    spec:
      selector:
        istio: ingressgateway    # selects pods with label istio=ingressgateway
      servers:
        - port: { number: 80, name: http, protocol: HTTP }
          hosts: ["{{ .Release.Name }}.test.local"]
    ---
    apiVersion: networking.istio.io/v1beta1
    kind: VirtualService
    metadata:
      name: {{ .Release.Name }}-vs
      namespace: {{ .Release.Namespace }}
    spec:
      hosts: ["{{ .Release.Name }}.test.local"]
      gateways: ["{{ .Release.Name }}-igw"]
      http:
        - match:
            - uri: { prefix: / }
          route:
            - destination:
                host: "{{ .Release.Name }}.{{ .Release.Namespace }}.svc.cluster.local"
                port: { number: {{ .Values.service.port | default 80 }} }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: "{{ .Release.Name }}-ct-istio-igw"
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: "{{ .Release.Name }}-ct-istio-igw"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
rules:
  - apiGroups: ["networking.istio.io"]
    resources: ["gateways", "virtualservices"]
    verbs: ["create", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods", "services"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: "{{ .Release.Name }}-ct-istio-igw"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
subjects:
  - kind: ServiceAccount
    name: "{{ .Release.Name }}-ct-istio-igw"
    namespace: {{ .Release.Namespace }}
roleRef:
  kind: ClusterRole
  name: "{{ .Release.Name }}-ct-istio-igw"
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: "{{ .Release.Name }}-ct-istio-igw-test"
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/component: chart-test-swarm
    integration: istio-ingress-gateway
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  serviceAccountName: {{ .Release.Name }}-ct-istio-igw
  restartPolicy: Never
  containers:
    - name: probe
      image: bitnami/kubectl:1.30
      command: ["sh", "-c"]
      args:
        - |
          set -eu
          echo "==> Applying Gateway + VirtualService"
          kubectl apply -f /setup/routing.yaml
          sleep 10  # istiod reconcile lag for new Gateway/VirtualService
          echo "==> Getting istio-ingressgateway pod IP (probe bypasses NodePort)"
          GW_POD_IP=$(kubectl -n istio-system get pod \
            -l app=istio-ingressgateway \
            -o jsonpath='{.items[0].status.podIP}')
          echo "==> Probing via istio ingress gateway (Host header required)"
          curl -sf --max-time 20 \
            -H "Host: {{ .Release.Name }}.test.local" \
            "http://${GW_POD_IP}:80/" -o /dev/null \
            && echo "  ✓ Traffic routed through istio ingress gateway"
          echo "==> Verifying Gateway resource reconciled"
          kubectl -n {{ .Release.Namespace }} get gateway "{{ .Release.Name }}-igw"
          echo "==> Verifying VirtualService resource reconciled"
          kubectl -n {{ .Release.Namespace }} get virtualservice "{{ .Release.Name }}-vs"
          echo "PASS: istio ingress gateway integration verified"
      volumeMounts:
        - { name: setup, mountPath: /setup }
  volumes:
    - name: setup
      configMap:
        name: "{{ .Release.Name }}-ct-istio-igw-setup"
{{- end }}
```

## Common failure modes

- **VirtualService 404 — `gateways:` or `hosts:` mismatch** → Two causes:
  (a) VirtualService `gateways:` must reference the Gateway by exact
  `<namespace>/<name>` or bare `<name>` (same-namespace shorthand). A wrong
  name is silently ignored — no error, just 404.
  (b) VirtualService `hosts:` must exactly match the Gateway `servers[].hosts`.
  Both fields must contain the same hostname string.

- **Gateway shows no `status` or stays `UNINITIALIZED`** → istiod takes 5-15s
  to reconcile a new Gateway resource. The test sleeps 10s after apply; if the
  cluster is under load, increase the sleep or add a polling loop.

- **`networking.istio.io` CRDs not installed** → `istio/base` installs them.
  If `base` is skipped, `kubectl apply -f routing.yaml` returns "no matches for
  kind Gateway in version networking.istio.io/v1beta1". Verify with:
  `kubectl get crd | grep istio.io`.

- **Gateway selector `istio: ingressgateway` doesn't match pods** → The
  `istio/gateway` chart deploys pods labeled `istio: ingressgateway`. If the
  chart release was named differently (or extra labels were added), the selector
  may not match. Check: `kubectl -n istio-system get pod --show-labels | grep gateway`.

- **NodePort unreachable — probe via pod IP instead** → On kind, the NodePort
  is bound to the node's IP, not 127.0.0.1. The test pattern above probes the
  gateway pod IP directly on port 80 (the container port), bypassing NodePort
  indirection entirely. This is more reliable for in-cluster test pods.

- **Consumer Service FQDN wrong** → VirtualService `destination.host` must be
  the exact Service FQDN. Short name (just `<release>`) works only when the
  VirtualService is in the same namespace as the Service. If namespaces differ,
  use the full `<release>.<namespace>.svc.cluster.local` form.

- **Istio Gateway vs Gateway API Gateway — critical** → If both CRDs coexist,
  `kubectl apply -f` with `kind: Gateway` without an explicit `apiVersion` may
  apply to whichever controller responds first. Always use:
  - `apiVersion: networking.istio.io/v1beta1` for Istio Gateway (this primer)
  - `apiVersion: gateway.networking.k8s.io/v1` for Gateway API Gateway
  Applying to the wrong CRD creates a resource that reconciles without error
  but produces no routing.
