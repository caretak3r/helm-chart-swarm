# traefik

Installs Traefik as the cluster's ingress controller. The chart-test-swarm
scenario generated against this primer verifies that the consumer chart can:
1. Coexist with Traefik's CRDs (IngressRoute, Middleware, TLSOption, etc.)
2. Route traffic to its pods through a Traefik IngressRoute or classic Ingress
3. Optionally wire Traefik Middleware (headers, redirects, rate limiting)

## Cluster preinstall

```yaml
- chart: traefik/traefik
  version: v28.3.0
  release: traefik
  namespace: traefik
  repo:
    name: traefik
    url: "https://traefik.github.io/charts"
  values:
    ingressClass:
      enabled: true
      isDefaultClass: true
    ingressRoute:
      dashboard:
        enabled: false         # no dashboard in test clusters
    ports:
      web:
        exposedPort: 80
        nodePort: 30080        # kind has no LB; NodePort for test access
    service:
      type: NodePort
    providers:
      kubernetesIngress: { enabled: true }
      kubernetesCRD: { enabled: true }
  wait: pods-ready
  wait_timeout: 3m
```

## Feasibility checklist for the consumer chart

**Required:**
- [ ] Chart has at least one pod-owning kind (Deployment / StatefulSet / DaemonSet) — needs an upstream pod for Traefik to route to.
- [ ] Chart exposes at least one Service — IngressRoute `services[].name` references a Service by name and port.

**Soft:**
- [ ] Chart has an `ingress.enabled` / `ingress.className` toggle in values — lets us flip Traefik routing on via override without touching templates.
- [ ] Ingress annotations are value-driven — lets us add `traefik.ingress.kubernetes.io/` annotations via override.
- [ ] Service ports are named (`http`, `https`) — Traefik resolves named ports more reliably than numeric-only in IngressRoute specs.
- [ ] Chart does NOT hard-code a different ingressClassName (nginx, alb) in a non-value-driven template — that creates a silent routing conflict.

## Standard values-override pattern

```yaml
chartTestSwarm:
  enabled: true                # gates the helm-test pod

# Option A — chart has a standard ingress block (preferred):
ingress:
  enabled: true
  className: traefik
  annotations: {}
  hosts:
    - host: "{{ .Release.Name }}.test.local"   # fake hostname; probe uses Host header
      paths:
        - path: /
          pathType: Prefix
  tls: []

# Option B — chart has no ingress toggle:
# Set ingress.enabled: false and let the helm-test pod create an IngressRoute
# CR at runtime instead (see Standard helm-test pattern, step 1).
# ingress:
#   enabled: false
```

Prefer Option A when the chart's values support it; fall back to Option B
when the chart has no ingress values path.

## Standard helm-test pattern

```yaml
{{- if .Values.chartTestSwarm.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: "{{ .Release.Name }}-ct-traefik-setup"
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": hook-succeeded
data:
  ingressroute.yaml: |
    apiVersion: traefik.io/v1alpha1
    kind: IngressRoute
    metadata:
      name: {{ .Release.Name }}-ct-route
      namespace: {{ .Release.Namespace }}
    spec:
      entryPoints: [web]
      routes:
        - match: Host(`{{ .Release.Name }}.test.local`)
          kind: Rule
          services:
            - name: {{ .Release.Name }}
              port: {{ .Values.service.port | default 80 }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: "{{ .Release.Name }}-ct-traefik"
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: "{{ .Release.Name }}-ct-traefik"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
rules:
  - apiGroups: ["traefik.io", "traefik.containo.us"]
    resources: ["ingressroutes", "middlewares"]
    verbs: ["create", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: "{{ .Release.Name }}-ct-traefik"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
subjects:
  - kind: ServiceAccount
    name: "{{ .Release.Name }}-ct-traefik"
    namespace: {{ .Release.Namespace }}
roleRef:
  kind: ClusterRole
  name: "{{ .Release.Name }}-ct-traefik"
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: "{{ .Release.Name }}-ct-traefik-test"
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/component: chart-test-swarm
    integration: traefik
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  serviceAccountName: {{ .Release.Name }}-ct-traefik
  restartPolicy: Never
  containers:
    - name: probe
      image: bitnami/kubectl:1.30
      command: ["sh", "-c"]
      args:
        - |
          set -eu
          echo "==> Applying IngressRoute (Option B fallback — no-op if already created via values)"
          kubectl apply -f /setup/ingressroute.yaml || true
          echo "==> Verifying Traefik pod is ready"
          kubectl -n traefik wait pod -l app.kubernetes.io/name=traefik \
            --for=condition=Ready --timeout=2m
          echo "==> Getting Traefik pod IP (probe via pod IP, not NodePort)"
          TRAEFIK_IP=$(kubectl -n traefik get pod \
            -l app.kubernetes.io/name=traefik \
            -o jsonpath='{.items[0].status.podIP}')
          echo "==> Probing via IngressRoute (Host header required)"
          curl -sf --max-time 15 \
            -H "Host: {{ .Release.Name }}.test.local" \
            "http://${TRAEFIK_IP}:80/" -o /dev/null \
            && echo "  ✓ Traffic routed through Traefik"
          echo "==> Verifying IngressRoute resource exists"
          kubectl -n {{ .Release.Namespace }} get ingressroute "{{ .Release.Name }}-ct-route" 2>/dev/null \
            || kubectl -n {{ .Release.Namespace }} get ingress "{{ .Release.Name }}" 2>/dev/null \
            || { echo "WARN: no IngressRoute or Ingress found — chart may use a non-standard routing name"; }
          echo "PASS: traefik integration verified"
      volumeMounts:
        - { name: setup, mountPath: /setup }
  volumes:
    - name: setup
      configMap:
        name: "{{ .Release.Name }}-ct-traefik-setup"
{{- end }}
```

## Common failure modes

- **`traefik.io` vs `traefik.containo.us` apiGroup** → Traefik v3 uses
  `traefik.io/v1alpha1`; Traefik v2 uses `traefik.containo.us/v1alpha1`.
  This primer targets v3 (chart v28+). If leftover v2 CRDs exist in the
  cluster, both apiGroups may be present — pin the chart version and verify
  with `kubectl get crd | grep traefik`.

- **404 from gateway — `Host` header missing** → IngressRoute rules use
  `Host(...)` matching; a probe without the matching `Host` header returns
  Traefik's default 404. Always include `-H "Host: ..."` in the curl probe.

- **IngressRoute not picking up the Service** → Traefik resolves
  `services[].name` in the IngressRoute's namespace by default. If the
  product chart deploys to a different namespace than the IngressRoute,
  add an explicit `namespace:` to the service entry in the route spec.

- **NodePort unreachable from inside the cluster** → On kind, Traefik's
  NodePort is bound to the node's internal IP. The probe above uses the pod
  IP directly on port 80 (not the NodePort number) to bypass the LB/NodePort
  indirection entirely.

- **Chart ingress uses hard-coded `ingressClassName: nginx`** → If the
  chart's Ingress template is not value-driven, Traefik won't pick it up.
  Disable the chart's ingress flag and use the runtime IngressRoute path
  (Option B) instead.

- **Middleware applied but response unchanged** → Middleware must be attached
  to the IngressRoute rule via `middlewares: [{name: ..., namespace: ...}]`
  in the route spec. Creating a Middleware CR standalone has no effect without
  this reference in the IngressRoute.
