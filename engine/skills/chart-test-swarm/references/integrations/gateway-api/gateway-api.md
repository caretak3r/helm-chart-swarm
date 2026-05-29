# gateway-api

Adds the Gateway API CRD surface (GatewayClass, Gateway, HTTPRoute, etc.) to
the cluster. The chart-test-swarm scenario generated against this primer
verifies that the consumer chart can:
1. Coexist with Gateway API CRDs and a running gateway controller
2. Express its routing intent via HTTPRoute (or GRPCRoute / TCPRoute)
3. Have traffic reach its pods through a real Gateway

## Cluster preinstall

The Envoy Gateway helm chart (OCI) bundles Gateway API CRDs in its `crds/`
directory — Helm installs them automatically before templates, so no separate
`raw_manifest` CRD apply is needed. (If you use a different Gateway API
controller that does NOT bundle CRDs, apply them via `raw_manifest` with
`kind: raw_manifest` pointing at the standard-install.yaml URL, and
`apply-scenario.sh` uses `kubectl apply --server-side --force-conflicts`
to avoid field-manager conflicts.)

```yaml
# Envoy Gateway controller (OCI chart — no helm repo add needed;
# CRDs are bundled in crds/ and installed automatically before templates)
- chart: oci://docker.io/envoyproxy/gateway-helm
  version: v1.1.2
  release: envoy-gateway
  namespace: envoy-gateway-system
  values:
    config:
      envoyGateway:
        provider:
          type: Kubernetes
  wait: pods-ready
  wait_timeout: 4m
```

The helm-test pod creates the GatewayClass, Gateway, and HTTPRoute at runtime.

## Feasibility checklist for the consumer chart

**Required:**
- [ ] Chart has at least one pod-owning kind (Deployment / StatefulSet / DaemonSet) — there must be a backend pod for HTTPRoute to route to.
- [ ] Chart exposes at least one Service — HTTPRoute `backendRef` points to a Service, not a Pod.

**Soft:**
- [ ] Chart already defines Ingress or HTTPRoute resources (shows existing routing intent; we supplement or replace them).
- [ ] Service port names follow convention (`http`, `https`, `grpc`) — Gateway API uses named ports for protocol inference; unnamed numeric ports work but degrade observability.
- [ ] Pod annotations are value-driven (lets us add annotations without forking templates).
- [ ] Chart does NOT already define a GatewayClass or cluster-level Gateway (those belong to the cluster, not the app — duplicates cause reconcile conflicts).

## Standard values-override pattern

```yaml
chartTestSwarm:
  enabled: true              # gates the helm-test pod

# Gateway API resources (Gateway, HTTPRoute) are cluster-level objects written
# by the helm-test pod at runtime. The product chart itself rarely needs changes.
#
# If the chart has a classic Ingress toggle, disable it to avoid port conflicts:
ingress:
  enabled: false             # use HTTPRoute instead

# Expose the service port if the chart's values support it (used in backendRef)
service:
  port: 80                   # the HTTP port the product Service exposes
```

If the chart exposes its own HTTPRoute via values, prefer enabling that flag
over disabling ingress.

## Standard helm-test pattern

```yaml
{{- if .Values.chartTestSwarm.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: "{{ .Release.Name }}-ct-gwapi-setup"
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": hook-succeeded
data:
  manifests.yaml: |
    apiVersion: gateway.networking.k8s.io/v1
    kind: GatewayClass
    metadata: { name: envoy }
    spec: { controllerName: gateway.envoyproxy.io/gatewayclass-controller }
    ---
    apiVersion: gateway.networking.k8s.io/v1
    kind: Gateway
    metadata:
      name: {{ .Release.Name }}-gw
      namespace: {{ .Release.Namespace }}
    spec:
      gatewayClassName: envoy
      listeners:
        - name: http
          protocol: HTTP
          port: 80
          allowedRoutes:
            namespaces: { from: Same }
    ---
    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
      name: {{ .Release.Name }}-route
      namespace: {{ .Release.Namespace }}
    spec:
      parentRefs:
        - name: {{ .Release.Name }}-gw
          sectionName: http
      rules:
        - matches:
            - path: { type: PathPrefix, value: / }
          backendRefs:
            - name: {{ .Release.Name }}
              port: {{ .Values.service.port | default 80 }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: "{{ .Release.Name }}-ct-gwapi"
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: "{{ .Release.Name }}-ct-gwapi"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["gatewayclasses", "gateways", "httproutes"]
    verbs: ["create", "get", "list", "watch", "patch"]
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: "{{ .Release.Name }}-ct-gwapi"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
subjects:
  - kind: ServiceAccount
    name: "{{ .Release.Name }}-ct-gwapi"
    namespace: {{ .Release.Namespace }}
roleRef:
  kind: ClusterRole
  name: "{{ .Release.Name }}-ct-gwapi"
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: "{{ .Release.Name }}-ct-gwapi-test"
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/component: chart-test-swarm
    integration: gateway-api
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  serviceAccountName: {{ .Release.Name }}-ct-gwapi
  restartPolicy: Never
  containers:
    - name: probe
      image: bitnami/kubectl:1.30
      command: ["sh", "-c"]
      args:
        - |
          set -eu
          echo "==> Applying GatewayClass + Gateway + HTTPRoute"
          kubectl apply -f /setup/manifests.yaml
          echo "==> Waiting for Gateway Programmed condition (3m max)"
          kubectl -n {{ .Release.Namespace }} wait gateway "{{ .Release.Name }}-gw" \
            --for=condition=Programmed --timeout=3m
          echo "==> Verifying HTTPRoute is Accepted"
          kubectl -n {{ .Release.Namespace }} get httproute "{{ .Release.Name }}-route" \
            -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' \
            | grep -q "True"
          echo "==> Getting gateway address"
          GW_IP=$(kubectl -n {{ .Release.Namespace }} get gateway "{{ .Release.Name }}-gw" \
            -o jsonpath='{.status.addresses[0].value}')
          echo "==> Probing backend via gateway"
          curl -sf --max-time 15 "http://${GW_IP}/" -o /dev/null \
            && echo "  ✓ Traffic routed through gateway-api gateway"
          echo "PASS: gateway-api integration verified"
      volumeMounts:
        - { name: setup, mountPath: /setup }
  volumes:
    - name: setup
      configMap:
        name: "{{ .Release.Name }}-ct-gwapi-setup"
{{- end }}
```

## Common failure modes

- **GatewayClass not accepted** → Envoy Gateway controller takes up to 2m to
  reconcile a new GatewayClass. Poll until `ACCEPTED: True`.
  Failure signal: `kubectl get gatewayclass envoy` shows `ACCEPTED: False`.

- **HTTPRoute not accepted (`NotAllowedByListeners`)** → The HTTPRoute's
  `parentRef` must match the Gateway name exactly, and the Gateway's
  `allowedRoutes.namespaces` must include the HTTPRoute's namespace.
  Failure signal: HTTPRoute status `.parents[0].conditions` type=Accepted,
  reason=NotAllowedByListeners.

- **Gateway has no address (`status.addresses` empty)** → Envoy Gateway
  provisions a LoadBalancer Service; on kind this requires MetalLB or
  `cloud-provider-kind`. Alternative: probe the envoy pod IP directly on
  port 80 (skip the LB address lookup).

- **CRDs not installed — "no matches for kind HTTPRoute"** → Run
  `kubectl get crd | grep gateway.networking.k8s.io` to confirm. The CRD
  apply step (in the test pod) must complete before the HTTPRoute apply.

- **Consumer Service port mismatch** → HTTPRoute `backendRef.port` must
  match a port on the Service spec exactly (number or named port). Check
  `kubectl get svc {{ .Release.Name }} -o yaml` for port definitions.

- **Istio Gateway vs Gateway API Gateway confusion** → Both may coexist.
  Always specify `apiVersion: gateway.networking.k8s.io/v1` (not
  `networking.istio.io/v1beta1`) for this primer's resources. Mixing
  apiVersions silently creates a resource the wrong controller reconciles.
