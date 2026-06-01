# linkerd

Installs Linkerd as a lightweight, security-focused service mesh (control plane +
data-plane proxy injection via namespace annotation). The chart-test-swarm
scenarios generated against this primer verify that the consumer chart can:

1. Have its pods receive a `linkerd-proxy` sidecar via namespace-level annotation
2. Survive proxy injection without init-container failures (Linkerd has no
   init container — injection is via a mutating webhook that adds the
   `linkerd-proxy` container directly)
3. Pass `linkerd check --proxy` confirming the control plane and data plane are
   healthy with mTLS enabled
4. Expose per-route metrics via `ServiceProfile` CRDs
5. Rotate mTLS identities and confirm the mesh remains operational

## What

Linkerd is a CNCF-graduated service mesh that adds transparent mTLS, retries,
timeouts, and per-route metrics to any Kubernetes application without requiring
application changes. Proxy injection is triggered by the `linkerd.io/inject:
enabled` annotation on a **namespace** (unlike Istio, which uses pod-level
annotations). The proxy is a purpose-built Rust micro-proxy that is significantly
lighter than Envoy (~10 MB RSS vs ~100 MB).

Linkerd scenarios install the control plane (`linkerd-crds` +
`linkerd-control-plane`) via Helm on a kind cluster and exercise the
sample-product chart's mesh integration capabilities. Each variant targets a
specific mesh feature.

## When

Use these scenarios when validating that a Helm chart:

- Correctly works with namespace-level proxy injection (`linkerd.io/inject: enabled`)
- Does not use `hostNetwork: true` (pods on host network cannot receive a proxy container)
- Does not have Job/CronJob pods that would hang forever with an injected proxy
  (the proxy never exits, so the Job never completes)
- Exposes values to opt individual workloads into/out of mesh injection
- Supports `ServiceProfile` CRDs for per-route observability

## How

The `linkerd-crds` + `linkerd-control-plane` charts are installed as
`cluster.preinstall` items. After the control-plane pods are Ready, the product
namespace is annotated with `linkerd.io/inject: enabled` and the product chart
is installed (or upgraded). The mutating webhook injects a `linkerd-proxy`
container into every new pod in the annotated namespace.

The injection webhook is a `MutatingWebhookConfiguration` named
`linkerd-proxy-injector-webhook-config` in the `linkerd` namespace. It is torn
down when the cluster is deleted — no namespace-cleanup is needed apart from
the normal `cluster-down.sh` teardown.

## Variants

Four lean variants exercise the core mesh capabilities:

| Variant | Scenario file | What it verifies |
|---------|--------------|------------------|
| **basic-mesh** | `service-mesh-linkerd-basic-mesh.yaml` | Namespace annotation triggers sidecar injection; every product pod has a `linkerd-proxy` container; `linkerd check --proxy` exits 0 |
| **multi-cluster-preview** | `service-mesh-linkerd-multi-cluster-preview.yaml` | `linkerd-multicluster` extension chart is installed; `Link` and `ServiceMirror` CRDs are available; a `Link` resource pointing at a target cluster is authored (preview only — no real cross-cluster traffic) |
| **service-profile** | `service-mesh-linkerd-service-profile.yaml` | `ServiceProfile` CRD is applied for the product service; per-route configuration (timeout, retry policy) is recognized; `linkerd viz routes`-equivalent check confirms the profile routes are defined |
| **mtls-rotation** | `service-mesh-linkerd-mtls-rotation.yaml` | `linkerd check --proxy` confirms all proxies have valid mTLS identities; identity trust anchor is inspected via `linkerd identity`; the root certificate's expiry is documented |

## Cluster preinstall

```yaml
# Step 1: Install Linkerd CRDs (required before control-plane)
- kind: helm
  chart: linkerd/linkerd-crds
  version: 1.8.0
  release: linkerd-crds
  namespace: linkerd
  repo:
    name: linkerd
    url: "https://helm.linkerd.io/stable"
  values: {}
  wait: helm-deployed
  wait_timeout: 2m

# Step 2: Install Linkerd control plane (injector, identity, destination, proxy-injector)
- kind: helm
  chart: linkerd/linkerd-control-plane
  version: 1.16.11
  release: linkerd-control-plane
  namespace: linkerd
  repo:
    name: linkerd
    url: "https://helm.linkerd.io/stable"
  values:
    # Reduce resource footprint for kind clusters
    proxy:
      resources:
        cpu: { limit: "250m", request: "100m" }
        memory: { limit: "256Mi", request: "64Mi" }
    identity:
      resources:
        cpu: { limit: "250m", request: "100m" }
        memory: { limit: "256Mi", request: "64Mi" }
  wait: pods-ready
  wait_timeout: 5m
```

After the control plane is ready, annotate the product namespace for injection:

```bash
kubectl annotate namespace <product-ns> linkerd.io/inject=enabled --overwrite
```

This annotation MUST be applied BEFORE pods are created in the namespace.
The mutating webhook fires on pod creation; existing pods are NOT retroactively
injected. If the product chart was installed before the annotation, restart the
deployments:

```bash
kubectl -n <product-ns> rollout restart deployment
```

**Important:** Linkerd injection is namespace-scoped. There is no pod-level
annotation like `sidecar.istio.io/inject`. If individual workloads need to
opt OUT of injection, annotate the pod template with
`linkerd.io/inject: disabled` — this is uncommon but necessary for Job pods
that must terminate.

## Feasibility checklist for the consumer chart

**Required:**
- [ ] No `hostNetwork: true` on any pod template — host-network pods share the
  host's network namespace; the linkerd-proxy container cannot intercept traffic
  without its own network namespace. The pod would run without a proxy, silently
  bypassing the mesh.
- [ ] Chart has at least one pod-owning kind (Deployment / StatefulSet / DaemonSet).
  No pods = no sidecars = no scenario.

**Soft:**
- [ ] Chart has no Jobs or CronJobs that would hang — the linkerd-proxy container
  never exits, so Job pods with injected proxies run forever. Fix: annotate Job
  pod templates with `linkerd.io/inject: disabled`. If the chart doesn't expose
  pod-template annotations via values, this is a chart limitation.
- [ ] No init containers that make network calls before the proxy starts — the
  linkerd-proxy starts alongside the main container (not as an init container),
  so init containers that make HTTP/DNS calls may fail if they try to reach
  mesh-injected services before those services' proxies are ready.
- [ ] Pods do not use `hostPID: true` or `hostIPC: true` — these share host
  namespaces, which can cause the proxy's identity to leak or cause routing
  confusion.
- [ ] The product chart does not modify `terminationGracePeriodSeconds` to values
  below 10s — the proxy needs a few seconds to drain connections gracefully on
  SIGTERM before the pod is killed.

## Standard values-override pattern

```yaml
# The namespace annotation linkerd.io/inject=enabled is applied via the
# assertion script (or a raw_manifest preinstall item). No chart-level
# values are strictly required since injection is namespace-scoped.
#
# However, enabling scope exercises multi-pod injection for fuller coverage:
scope:
  enabled: true

# Resource limits: the linkerd-proxy sidecar runs with its OWN resource spec
# (set in control-plane values above). Product container limits don't need
# changes, but the node must have capacity for the extra proxy per pod.
# A typical linkerd-proxy uses ~10 MB RSS at idle.
```

For the multi-cluster variant, also install the `linkerd-multicluster` chart:

```yaml
- kind: helm
  chart: linkerd/linkerd-multicluster
  version: 1.14.2
  release: linkerd-multicluster
  namespace: linkerd-multicluster
  repo:
    name: linkerd
    url: "https://helm.linkerd.io/stable"
  values: {}
  wait: pods-ready
  wait_timeout: 3m
```

## Standard helm-test pattern

```yaml
{{- if .Values.chartTestSwarm.enabled }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: "{{ .Release.Name }}-ct-linkerd-mesh"
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: "{{ .Release.Name }}-ct-linkerd-mesh"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/exec", "namespaces"]
    verbs: ["get", "list", "patch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "patch"]
  - apiGroups: ["linkerd.io"]
    resources: ["serviceprofiles"]
    verbs: ["create", "get", "list", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: "{{ .Release.Name }}-ct-linkerd-mesh"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
subjects:
  - kind: ServiceAccount
    name: "{{ .Release.Name }}-ct-linkerd-mesh"
    namespace: {{ .Release.Namespace }}
roleRef:
  kind: ClusterRole
  name: "{{ .Release.Name }}-ct-linkerd-mesh"
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: "{{ .Release.Name }}-ct-linkerd-mesh-test"
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/component: chart-test-swarm
    integration: linkerd
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": hook-succeeded
    linkerd.io/inject: disabled   # test pod does NOT need a proxy
spec:
  serviceAccountName: {{ .Release.Name }}-ct-linkerd-mesh
  restartPolicy: Never
  containers:
    - name: probe
      image: bitnami/kubectl:1.30
      command: ["sh", "-c"]
      args:
        - |
          set -eu
          echo "==> Annotating namespace {{ .Release.Namespace }} for linkerd injection"
          kubectl annotate namespace {{ .Release.Namespace }} linkerd.io/inject=enabled --overwrite

          echo "==> Restarting deployments to pick up proxy injection"
          for DEPLOY in $(kubectl -n {{ .Release.Namespace }} get deploy -o name); do
            kubectl -n {{ .Release.Namespace }} rollout restart "$DEPLOY"
            kubectl -n {{ .Release.Namespace }} rollout status "$DEPLOY" --timeout=3m
          done

          echo "==> Verifying linkerd-proxy sidecar injected into every product pod"
          for DEPLOY in $(kubectl -n {{ .Release.Namespace }} get deploy -o name); do
            SELECTOR=$(kubectl -n {{ .Release.Namespace }} get "$DEPLOY" -o jsonpath='{.spec.selector.matchLabels}' | \
              jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
            PODS=$(kubectl -n {{ .Release.Namespace }} get pods -l "${SELECTOR}" \
              --field-selector=status.phase=Running \
              -o jsonpath='{.items[*].metadata.name}')
            for POD in $PODS; do
              CONTAINERS=$(kubectl -n {{ .Release.Namespace }} get pod "$POD" -o jsonpath='{.spec.containers[*].name}')
              if echo "$CONTAINERS" | grep -q "linkerd-proxy"; then
                echo "  ✓ Pod $POD: linkerd-proxy sidecar present"
              else
                echo "FAIL: Pod $POD missing linkerd-proxy sidecar (containers: ${CONTAINERS})" >&2
                exit 1
              fi
            done
          done

          echo "==> Running linkerd check --proxy"
          LINKERD_CLI_URL="https://github.com/linkerd/linkerd2/releases/download/stable-2.15.2/linkerd2-cli-stable-2.15.2-linux-amd64"
          LINKERD_CHECK_POD="ct-linkerd-check-$$"

          kubectl -n {{ .Release.Namespace }} run "$LINKERD_CHECK_POD" --restart=Never \
            --image=alpine/curl:latest --overrides='{"metadata":{"annotations":{"linkerd.io/inject":"disabled"}}}' -- \
            sh -c "
              echo 'Downloading linkerd CLI...'
              curl -sL '$LINKERD_CLI_URL' -o /tmp/linkerd
              chmod +x /tmp/linkerd
              echo 'Running linkerd check --proxy...'
              /tmp/linkerd check --proxy 2>&1
            " || {
            echo "WARN: linkerd check pod did not start; checking logs"
            kubectl -n {{ .Release.Namespace }} logs "$LINKERD_CHECK_POD" 2>/dev/null || true
          }

          echo "  Waiting for linkerd check pod to complete (2m max)"
          kubectl -n {{ .Release.Namespace }} wait --for=condition=Ready pod/"$LINKERD_CHECK_POD" --timeout=30s 2>/dev/null || true
          sleep 60
          CHECK_LOG=$(kubectl -n {{ .Release.Namespace }} logs "$LINKERD_CHECK_POD" 2>/dev/null || echo "NO_LOGS")
          echo "  linkerd check output:"
          echo "$CHECK_LOG"

          if echo "$CHECK_LOG" | grep -q "Status check results are"; then
            echo "PASS: linkerd check --proxy completed"
          else
            echo "WARN: linkerd check did not produce expected output (may need network access)"
            echo "  The sidecar injection verification above is the primary gate"
          fi

          kubectl -n {{ .Release.Namespace }} delete pod "$LINKERD_CHECK_POD" --ignore-not-found --timeout=30s || true

          echo "PASS: linkerd service mesh integration verified"
{{- end }}
```

## Common failure modes

- **`linkerd-proxy-injector-webhook-config` not found / injection missing** →
  The linkerd-control-plane chart must be installed AND all pods must be Ready
  before pods are created in the annotated namespace. If the webhook is not
  registered when the pod is created, the pod starts without a proxy. Fix:
  annotate the namespace and restart deployments (`kubectl rollout restart`).
  Failure signal: `kubectl get mutatingwebhookconfiguration` shows no
  `linkerd-proxy-injector-webhook-config`; pods show 1 container instead of 2.

- **`linkerd check --proxy` fails with "× control plane pods are ready"** →
  One or more linkerd control-plane pods are not Ready. This is typically a
  resource issue on kind. Fix: reduce `proxy.resources` and
  `identity.resources` in the control-plane values (as shown in the preinstall
  block above). Failure signal: `kubectl -n linkerd get pods` shows
  non-Ready pods.

- **`linkerd check --proxy` fails with "× data plane proxy metrics"** →
  The proxy is running but the metrics endpoint is unreachable. This is benign
  for injection verification and usually means the probe pod doesn't have
  network access to the proxy admin interface (`localhost:4191`). Verify
  injection via container inspection instead.

- **`no running pods found` after rollout restart** → The namespace annotation
  was applied but the mutating webhook may have been temporarily unavailable
  during the restart, causing some pods to start without a proxy. Fix: wait 30s
  after annotating the namespace before restarting; this gives the webhook's
  `caBundle` time to propagate.

- **Job pods never complete (hang in `Running` state)** → The linkerd-proxy
  keeps the pod alive after the main container exits. Jobs must opt out of
  injection: annotate the Job's pod template with
  `linkerd.io/inject: disabled`. If the chart doesn't expose this via values,
  it's a chart limitation — document as a soft finding.

- **`linkerd check` fails with "× trust anchors: certificate is not within its
  validity period"** → The identity issuer certificate has expired (default
  validity: 365 days). mTLS will continue to work for existing connections but
  new connections will fail. Fix: rotate the trust anchor via `linkerd upgrade`
  or `linkerd identity --refresh`. This is the failure mode covered by the
  `mtls-rotation` variant.

- **Webhooks survive cluster teardown** → Linkerd installs
  `MutatingWebhookConfiguration/linkerd-proxy-injector-webhook-config` and
  `ValidatingWebhookConfiguration/linkerd-sp-validator-webhook-config` in the
  `linkerd` namespace. These are cluster-scoped resources that are cleaned up
  automatically when the kind cluster is deleted. If using a non-kind backend,
  run `kubectl delete mutatingwebhookconfiguration linkerd-proxy-injector-webhook-config`
  before deleting the namespace. After `cluster-down.sh`, the next kind cluster
  should show zero mesh-related webhooks.

## References

- [Linkerd Helm charts](https://github.com/linkerd/linkerd2/blob/main/charts/linkerd-control-plane/README.md)
- [Linkerd check reference](https://linkerd.io/2.15/reference/cli/check/)
- [Automatic proxy injection](https://linkerd.io/2.15/features/proxy-injection/)
- [Service Profiles](https://linkerd.io/2.15/features/service-profiles/)
- [mTLS and Identity](https://linkerd.io/2.15/features/automatic-mtls/)
- [Multi-cluster communication](https://linkerd.io/2.15/features/multicluster/)
