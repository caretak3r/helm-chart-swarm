# opa-gatekeeper

Installs OPA Gatekeeper as a validating admission controller. Unlike the other
integration primers (which test whether the chart can USE an addon), this primer
tests whether the chart SURVIVES gatekeeper's admission enforcement. The scenario
verifies:
1. The chart's resources pass a representative set of cluster policies
2. The chart installs and re-deploys successfully with Gatekeeper in DENY mode
3. Policy violations are surfaced as named findings, not silent failures

**The feasibility model is INVERTED here.** Soft-check failures are discovered
policy non-compliances in the chart, not missing harness capabilities. A chart
that violates every soft policy is still POSSIBLE to test — the test just
surfaces the violations as documented findings.

## Cluster preinstall

```yaml
- chart: gatekeeper/gatekeeper
  version: v3.17.1
  release: gatekeeper
  namespace: gatekeeper-system
  repo:
    name: gatekeeper
    url: "https://open-policy-agent.github.io/gatekeeper/charts"
  values:
    auditInterval: 10          # fast feedback in test clusters
    constraintViolationsLimit: 20
    enableExternalData: false
    postInstall:
      labelNamespace:
        enabled: false
    validatingWebhookFailurePolicy: Fail  # DENY mode — fail-open defeats the test
  wait: pods-ready
  wait_timeout: 4m
```

ConstraintTemplates and Constraints are created by the helm-test pod at runtime
(not at preinstall time) so they apply to the already-installed chart via
dry-run server-side apply.

## Feasibility checklist for the consumer chart

**Required:**
- [ ] Chart has at least one pod-owning kind (Deployment / StatefulSet / DaemonSet) — gatekeeper's admission policies target pod templates; a chart with only ConfigMaps/Secrets is trivially "compatible" but produces no meaningful findings.

**Soft (non-compliance findings, not harness failures — document these):**
- [ ] Chart sets `app.kubernetes.io/name` label on pod templates — the most common enterprise required-label policy.
- [ ] All containers declare CPU + memory `limits` — `k8scontainerlimits` is the most frequently deployed enterprise constraint.
- [ ] No container images use `latest` tag — triggers `k8sallowedtags` policies in most enterprises.
- [ ] Chart does not create ClusterRole / ClusterRoleBinding with wildcard verbs — common RBAC policy violation.
- [ ] Container images are from a pinnable registry — prerequisite for `k8sallowedrepos` policies.

## Standard values-override pattern

```yaml
chartTestSwarm:
  enabled: true              # gates the helm-test pod

# Gatekeeper tests the chart AS-IS to surface real policy gaps.
# Minimize overrides — the goal is discovery, not remediation.

# Pin the image tag if the chart defaults to 'latest' (fails most tag policies):
image:
  tag: "0.1.0"              # replace with the chart's pinned default tag

# Add resource limits if the chart doesn't set them — verifies the chart
# CAN accept limits via values (soft: even if the chart doesn't default to them):
resources:
  limits:
    cpu: "500m"
    memory: "256Mi"
  requests:
    cpu: "100m"
    memory: "128Mi"
```

Do NOT fix every policy violation via override. Violations in the chart's
default state are findings — record them in the scenario's `notes:` field
for the product team to address.

## Standard helm-test pattern

Phase 1: Install ConstraintTemplates + Constraints (tier 1 DENY, tier 2 WARN).
Phase 2: Dry-run server-side apply of existing chart resources to trigger
         admission and surface violations.

```yaml
{{- if .Values.chartTestSwarm.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: "{{ .Release.Name }}-ct-gatekeeper-setup"
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": hook-succeeded
data:
  constraints.yaml: |
    apiVersion: templates.gatekeeper.sh/v1
    kind: ConstraintTemplate
    metadata: { name: k8srequiredlabels }
    spec:
      crd:
        spec:
          names: { kind: K8sRequiredLabels }
          validation:
            openAPIV3Schema:
              type: object
              properties:
                labels: { type: array, items: { type: string } }
      targets:
        - target: admission.k8s.gatekeeper.sh
          rego: |
            package k8srequiredlabels
            violation[{"msg": msg, "details": {"missing_labels": missing}}] {
              provided := {label | input.review.object.metadata.labels[label]}
              required := {label | label := input.parameters.labels[_]}
              missing := required - provided
              count(missing) > 0
              msg := sprintf("Missing required label(s): %v", [missing])
            }
    ---
    apiVersion: k8srequiredlabels.constraints.gatekeeper.sh/v1beta1
    kind: K8sRequiredLabels
    metadata: { name: require-app-name-label }
    spec:
      enforcementAction: deny
      match:
        kinds:
          - apiGroups: ["apps"]
            kinds: ["Deployment", "StatefulSet", "DaemonSet"]
      parameters:
        labels: ["app.kubernetes.io/name"]
    ---
    apiVersion: templates.gatekeeper.sh/v1
    kind: ConstraintTemplate
    metadata: { name: k8scontainerlimits }
    spec:
      crd:
        spec:
          names: { kind: K8sContainerLimits }
          validation:
            openAPIV3Schema: { type: object }
      targets:
        - target: admission.k8s.gatekeeper.sh
          rego: |
            package k8scontainerlimits
            violation[{"msg": msg}] {
              container := input.review.object.spec.template.spec.containers[_]
              not container.resources.limits.cpu
              msg := sprintf("Container '%v' missing cpu limit", [container.name])
            }
            violation[{"msg": msg}] {
              container := input.review.object.spec.template.spec.containers[_]
              not container.resources.limits.memory
              msg := sprintf("Container '%v' missing memory limit", [container.name])
            }
    ---
    apiVersion: k8scontainerlimits.constraints.gatekeeper.sh/v1beta1
    kind: K8sContainerLimits
    metadata: { name: require-container-limits }
    spec:
      enforcementAction: deny
      match:
        kinds:
          - apiGroups: ["apps"]
            kinds: ["Deployment", "StatefulSet", "DaemonSet"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: "{{ .Release.Name }}-ct-gatekeeper"
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: "{{ .Release.Name }}-ct-gatekeeper"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
rules:
  - apiGroups: ["templates.gatekeeper.sh"]
    resources: ["constrainttemplates"]
    verbs: ["create", "get", "list", "watch", "delete"]
  - apiGroups: ["k8srequiredlabels.constraints.gatekeeper.sh",
                "k8scontainerlimits.constraints.gatekeeper.sh"]
    resources: ["*"]
    verbs: ["create", "get", "list", "watch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: "{{ .Release.Name }}-ct-gatekeeper"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": hook-succeeded
subjects:
  - kind: ServiceAccount
    name: "{{ .Release.Name }}-ct-gatekeeper"
    namespace: {{ .Release.Namespace }}
roleRef:
  kind: ClusterRole
  name: "{{ .Release.Name }}-ct-gatekeeper"
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: "{{ .Release.Name }}-ct-gatekeeper-test"
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/component: chart-test-swarm
    integration: opa-gatekeeper
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  serviceAccountName: {{ .Release.Name }}-ct-gatekeeper
  restartPolicy: Never
  containers:
    - name: probe
      image: bitnami/kubectl:1.30
      command: ["sh", "-c"]
      args:
        - |
          set -eu
          echo "==> Installing ConstraintTemplates + Constraints"
          kubectl apply -f /setup/constraints.yaml
          echo "==> Waiting for ConstraintTemplates to establish (90s max)"
          for CT in k8srequiredlabels k8scontainerlimits; do
            kubectl wait crd/${CT}.constraints.gatekeeper.sh \
              --for=condition=Established --timeout=90s
          done
          sleep 8  # gatekeeper webhook sync lag after constraint creation

          echo "==> Phase 1: verify DENY constraints pass (compliant path)"
          kubectl -n {{ .Release.Namespace }} get deploy -o json \
            | kubectl apply --dry-run=server -f - 2>&1 | tee /tmp/admit-deny.txt
          if grep -q "admission webhook.*denied" /tmp/admit-deny.txt; then
            echo "FAIL: gatekeeper DENY constraint blocked chart resources"
            cat /tmp/admit-deny.txt
            exit 1
          fi
          echo "  ✓ No DENY violations"

          echo "==> Phase 2: surface WARN violations as documented findings"
          grep -i "warning" /tmp/admit-deny.txt && \
            echo "NOTE: WARN violations above are policy findings for the product team" || true

          echo "PASS: chart resources admitted under gatekeeper DENY constraints"
      volumeMounts:
        - { name: setup, mountPath: /setup }
  volumes:
    - name: setup
      configMap:
        name: "{{ .Release.Name }}-ct-gatekeeper-setup"
{{- end }}
```

## Common failure modes

- **ConstraintTemplate takes 30-90s to become active** → Gatekeeper syncs Rego
  into the webhook after CRD creation. If you apply a Constraint immediately
  after the ConstraintTemplate, you get "no matches for kind K8sRequiredLabels".
  The test waits for `Established` on the CRD + a sync sleep. Failure signal:
  `"no matches for kind K8sRequiredLabels in version ...constraints..."`.

- **`dry-run=server` DENY when chart ALREADY installed fine** → This is expected
  and intentional. The chart installed before constraints existed. The dry-run
  reveals what WOULD be denied in a cluster where gatekeeper was pre-configured
  (the customer's real scenario). PASS/FAIL reflects current admission posture,
  not what happened at install time.

- **Gatekeeper webhook blocks its own upgrade** → Gatekeeper exempts its own
  namespace by default. If this fires, verify `gatekeeper-system` is in the
  exempt namespaces list (`kubectl get config -n gatekeeper-system config -o yaml`).

- **RBAC for test SA needs cluster-scoped access** → ConstraintTemplates and
  Constraints are cluster-scoped. The SA needs a ClusterRole (not a Role).
  The standard pattern above uses ClusterRole correctly.

- **`warning` in dry-run output is not an exit-1 error** → `kubectl apply
  --dry-run=server` writes `enforcementAction: warn` violations to stderr as
  warnings, not errors. The test grep for `"admission webhook.*denied"` (which
  IS an exit 1 scenario) separately from warnings. Only denied admissions fail
  the test.

- **Constraint targets wrong namespace** → If the Constraint's `match` block
  has a namespace filter that excludes the product namespace, policies won't
  apply and the test yields a false PASS. The standard constraints above have
  no namespace filter (cluster-wide). Adjust if the scenario targets a scoped
  cluster.
