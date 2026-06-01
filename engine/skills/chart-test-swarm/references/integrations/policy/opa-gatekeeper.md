# opa-gatekeeper

## What

OPA Gatekeeper is a Kubernetes-native policy controller that enforces
Open Policy Agent (OPA) policies via admission webhooks. It extends the
Kubernetes API with `ConstraintTemplate` and `Constraint` CRDs, allowing
cluster operators to define and enforce custom policies declaratively.

Unlike the other integration primers (which test whether the chart can USE an
addon), this primer tests whether the chart SURVIVES gatekeeper's admission
enforcement. The scenario verifies:

1. The chart's resources pass a representative set of cluster policies
2. The chart installs and re-deploys successfully with Gatekeeper in DENY mode
3. Policy violations are surfaced as named findings, not silent failures

**The feasibility model is INVERTED here.** Soft-check failures are discovered
policy non-compliances in the chart, not missing harness capabilities. A chart
that violates every soft policy is still POSSIBLE to test — the test just
surfaces the violations as documented findings.

## When

Use this integration when your customers deploy into clusters governed by
OPA Gatekeeper and you need to verify your Helm chart's resources comply
with enterprise policy standards. Policy engines are increasingly mandatory
in regulated environments (PCI-DSS, HIPAA, FedRAMP) and platform-engineering
clusters (Kubernetes Platform-as-a-Service).

Typical signals that you need gatekeeper scenarios:
- Customers report `admission webhook "validation.gatekeeper.sh" denied` errors
- Your platform team mandates specific labels, resource limits, or image registries
- You need to document policy compliance posture for auditors
- You want to discover what policies your chart currently violates BEFORE the
  customer deploys (shift-left compliance)

## How

### Test pattern

The scenarios use **dry-run server-side admission probing**: ConstraintTemplates
and Constraints are applied via `cluster.preinstall` `raw_manifest` entries, then
the smoke-script assertion runs `kubectl apply --dry-run=server` against
compliant and non-compliant test manifests.

This avoids the complexity of the helm-test pod pattern for policy authoring
while keeping the critical behavior verification: admission webhook integration.

### Assertion flow

1. Wait for gatekeeper controller pods Ready
2. Verify ConstraintTemplate `observedGeneration >= generation`
3. Wait for CRD `Established=True`
4. Verify Constraint exists with `enforcementAction: deny`
5. Sleep 8s for webhook sync
6. `kubectl apply --dry-run=server -f noncompliant.yaml` → expect non-zero exit
7. `kubectl apply --dry-run=server -f compliant.yaml` → expect exit 0

## Cluster preinstall

```yaml
- kind: helm
  chart: gatekeeper/gatekeeper
  version: "3.17.1"
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

Key values:
- `validatingWebhookFailurePolicy: Fail` — ensures policy enforcement is not
  silently skipped if the webhook is unavailable
- `auditInterval: 10` — fast audit feedback for test clusters
- `postInstall.labelNamespace.enabled: false` — avoids unnecessary mutations

## Variants

Four scenario variants exercise the core gatekeeper admission patterns.
All scenarios use `cluster.provider: kind` and the preinstall pinned above.

| Variant | Scenario file | ConstraintTemplate | What it tests |
|---|---|---|---|
| required-labels | `policy-opa-gatekeeper-required-labels.yaml` | `k8srequiredlabels` | Deployments + Ingresses must carry `app.kubernetes.io/name` label. Cross-feature compose with nginx-ingress (M4). |
| image-allowlist | `policy-opa-gatekeeper-image-allowlist.yaml` | `k8sallowedrepos` | Only images from approved registries (`nginx`, `public.ecr.aws/`) are admitted. |
| resource-limits | `policy-opa-gatekeeper-resource-limits.yaml` | `k8scontainerlimits` | All containers must declare `resources.limits.cpu` and `resources.limits.memory`. |
| sync-config | `policy-opa-gatekeeper-sync-config.yaml` | (none — Config only) | Gatekeeper `Config` resource has non-empty `spec.sync.syncOnly` for OPA cache population. |

### required-labels (composed with nginx-ingress)

This variant installs BOTH gatekeeper AND nginx-ingress. The
`k8srequiredlabels` Constraint targets `Deployment`, `StatefulSet`,
`DaemonSet` (apiGroups: apps) AND `Ingress` (apiGroups: networking.k8s.io).

The smoke assertion verifies all four admission paths:
1. Non-compliant Deployment (missing label) → `kubectl apply --dry-run=server` denied
2. Compliant Deployment (has label) → accepted
3. Non-compliant Ingress (missing label) → denied
4. Compliant Ingress (has label) → applied, reaches Ready

This validates that gatekeeper policies can span multiple resource types
and that the nginx-ingress controller correctly serves traffic through
admitted Ingress resources. Cross-feature: M7 (policy-engines) + M4
(ingress-controllers).

**Constraint matching:**
```yaml
match:
  kinds:
    - apiGroups: ["apps"]
      kinds: ["Deployment", "StatefulSet", "DaemonSet"]
    - apiGroups: ["networking.k8s.io"]
      kinds: ["Ingress"]
```

### image-allowlist

Creates a `k8sallowedrepos` ConstraintTemplate that checks every container
image against a parameterized allowlist. The Constraint allows only
`public.ecr.aws/` and `nginx` images.

Non-allowlisted image (`docker.io/library/redis:7-alpine`) → denied.
Allowlisted image (`nginx:1.27-alpine`) → accepted.

### resource-limits

Creates a `k8scontainerlimits` ConstraintTemplate with two violation rules:
missing `resources.limits.cpu` and missing `resources.limits.memory`.

Deployment without `resources.limits` → denied with `missing cpu limit` or
`missing memory limit` message.

### sync-config

Applies a Gatekeeper `Config` resource (kind: `Config`, apiVersion:
`config.gatekeeper.sh/v1alpha1`) with `spec.sync.syncOnly` listing
`Namespace`, `Pod`, and `Ingress` kinds. This configures which resources
gatekeeper syncs into its OPA cache for policy evaluation context.

No ConstraintTemplate or Constraint is applied; the assertion simply
verifies the Config resource persists and is non-empty.

## Assertions

| Type | What it verifies |
|---|---|
| `helm-status-deployed` | Product chart installed successfully |
| `pods-ready` (gatekeeper-system) | Gatekeeper controller + audit pods Ready |
| `pods-ready` (ingress-nginx) | NGINX ingress controller Ready (required-labels only) |
| `pods-ready` (sample) | Product pods Ready |
| `smoke-script` | Admission webhook dry-run probing (per variant) |

All smoke-script assertions follow the pattern:
- Wait for controller Ready
- Verify ConstraintTemplate reconciled
- Wait for CRD Established
- Sleep for webhook sync
- Probe compliant and non-compliant manifests

## Feasibility checklist for the consumer chart

**Required:**
- [ ] Chart has at least one pod-owning kind (Deployment / StatefulSet / DaemonSet)
      — gatekeeper's admission policies target pod templates.

**Soft (non-compliance findings, not harness failures):**
- [ ] Chart sets `app.kubernetes.io/name` label on pod templates
- [ ] All containers declare CPU + memory `limits`
- [ ] No container images use `latest` tag
- [ ] Chart does not create ClusterRole / ClusterRoleBinding with wildcard verbs
- [ ] Container images are from a pinnable registry

## Known gotchas

- **ConstraintTemplate takes 30-90s to become active** — Gatekeeper syncs Rego
  into the webhook after CRD creation. Wait for `Established` on the CRD + a
  sync sleep. Failure signal: `"no matches for kind K8sRequiredLabels in version
  ...constraints..."`.

- **`dry-run=server` DENY when chart ALREADY installed fine** — This is expected
  and intentional. The chart installed before constraints existed. The dry-run
  reveals what WOULD be denied in a cluster where gatekeeper was pre-configured.

- **Gatekeeper webhook blocks its own upgrade** — Gatekeeper exempts its own
  namespace by default. Verify `gatekeeper-system` is in the exempt namespaces
  list.

- **`warning` in dry-run output is not an exit-1 error** — `kubectl apply
  --dry-run=server` writes `enforcementAction: warn` violations to stderr as
  warnings, not errors. Only `"admission webhook.*denied"` failures fail
  the test.

- **Constraint targets wrong namespace** — Default constraints have no
  namespace filter (cluster-wide). Adjust `match.namespaces` if targeting
  a scoped cluster.

- **Gatekeeper v3.17.1 minimum** — Earlier versions may not support all
  ConstraintTemplate features used. The pinned version is tested and stable.

## Webhook failure mode

This integration configures `validatingWebhookFailurePolicy: Fail` (DENY mode).
With `Fail`, if the gatekeeper webhook is unavailable (e.g., controller scaled
to 0), ALL admission requests are rejected — ensuring policies cannot be
bypassed. This is the enterprise-recommended setting.

To observe fail-close behavior:
```bash
kubectl scale deploy/gatekeeper-controller-manager -n gatekeeper-system --replicas=0
kubectl apply --dry-run=server -f <any-manifest.yaml>
# Result: "Internal error occurred: failed calling webhook..."
```

With `Ignore`, the same outage would silently admit all resources — not
recommended for security-hardened clusters.

## References

- [OPA Gatekeeper docs](https://open-policy-agent.github.io/gatekeeper/website/docs/)
- [Gatekeeper Helm chart](https://github.com/open-policy-agent/gatekeeper/tree/master/charts/gatekeeper)
- [ConstraintTemplate API](https://open-policy-agent.github.io/gatekeeper/website/docs/howto/#constraint-templates)
- [Gatekeeper library (community policies)](https://github.com/open-policy-agent/gatekeeper-library)
