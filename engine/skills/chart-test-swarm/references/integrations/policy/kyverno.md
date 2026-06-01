# kyverno

## What

Kyverno is a Kubernetes-native policy engine that manages policies as Kubernetes
resources — no new language to learn. Policies are written as
`ClusterPolicy` (or namespaced `Policy`) CRDs in plain YAML, supporting:

- **Validate** rules — deny non-compliant resources at admission time
- **Mutate** rules — patch resources (add labels, annotations, defaults) via JSON Patch or strategic merge
- **Generate** rules — create downstream resources (ConfigMaps, NetworkPolicies) when a trigger resource appears
- **Verify Images** — check container image signatures (Cosign/Notary) and attestations at admission

Unlike OPA Gatekeeper (which requires Rego), Kyverno policies are pure YAML,
making them accessible to platform teams who prefer KRM-style (Kubernetes
Resource Model) authoring.

This primer tests whether the sample-product chart can **coexist** with
Kyverno admission enforcement. The feasibility model is **INVERTED**: soft-check
failures surface chart non-compliances as documented findings, not harness
failures.

## When

Use this integration when your customers deploy into Kyverno-governed
clusters and you need to verify:

- The chart's resources pass representative validation rules (label requirements,
  security contexts, image sources)
- Mutating webhooks correctly annotate or default chart resources
- Generate rules produce expected downstream resources in governed namespaces
- Image verification rules reject unsigned or unapproved container images

Typical signals:
- Customers report `admission webhook "validate.kyverno.svc-fail" denied` errors
- Your platform team mandates Kyverno ClusterPolicies for all workloads
- You need to document compliance posture against Kyverno best-practices policies
- You want shift-left discovery of policy violations before the customer deploys

## How

### Test pattern

The scenarios use **dry-run server-side admission probing** for validate and
image-verify variants, plus **real resource creation** for mutate and generate
variants (which require the actual webhook to fire).

1. Install Kyverno via Helm with `validatingWebhookFailurePolicy: Fail`
2. Apply a `ClusterPolicy` matching the variant's rule type
3. Wait for Kyverno controller pods Ready + webhook sync
4. Probe: `kubectl apply --dry-run=server` for validate/image-verify
5. Probe: `kubectl apply` (real) for mutate — verify auto-injected annotation
6. Probe: create labeled namespace for generate — verify downstream ConfigMap

### Assertion flow per variant

**validate:**
1. Wait for kyverno admission controller Ready
2. Apply ClusterPolicy (require-label)
3. Sleep 8s for webhook sync
4. `kubectl apply --dry-run=server -f noncompliant.yaml` → expect non-zero, stderr names "validate.kyverno.svc-fail"
5. `kubectl apply --dry-run=server -f compliant.yaml` → expect exit 0

**mutate:**
1. Wait for kyverno admission controller Ready
2. Apply ClusterPolicy (add-annotation)
3. Apply test Pod manifest (lacking target annotation)
4. `kubectl get pod -o jsonpath` → annotation present (mutated by webhook)

**generate:**
1. Wait for kyverno admission + background controller Ready
2. Apply ClusterPolicy (generate-configmap)
3. Create namespace with trigger label
4. Within 10s, ConfigMap appears in the new namespace

**image-verify:**
1. Wait for kyverno admission controller Ready
2. Apply ClusterPolicy (require-cosign-attestation — or best-effort allowlist)
3. Sleep 8s for webhook sync
4. `kubectl apply --dry-run=server -f pod-untrusted-image.yaml` → expect non-zero, stderr names verifyImages rule
5. `kubectl apply --dry-run=server -f pod-trusted-image.yaml` → expect exit 0

## Cluster preinstall

```yaml
- kind: helm
  chart: kyverno/kyverno
  version: "3.8.1"
  release: kyverno
  namespace: kyverno
  repo:
    name: kyverno
    url: "https://kyverno.github.io/kyverno/"
  values:
    admissionController:
      replicas: 1
    backgroundController:
      enabled: true
    cleanupController:
      enabled: true
    reportsController:
      enabled: true
    features:
      admissionReports:
        enabled: true
      policyReports:
        enabled: true
  wait: pods-ready
  wait_timeout: 4m
```

Key values:
- `version: "3.8.1"` — pinned to the latest stable chart release
- Kyverno defaults to `failurePolicy: Fail` on its dynamically-managed webhooks
  (the `--forceFailurePolicyIgnore` flag, when NOT set, means Fail)
- `backgroundController.enabled: true` — required for generate rules
- `reportsController.enabled: true` — produces PolicyReports for visibility

## Variants

Four scenario variants exercise the core Kyverno policy types.
All scenarios use `cluster.provider: kind` and the preinstall pinned above.

| Variant | Scenario file | Policy type | What it tests |
|---|---|---|---|
| validate | `policy-kyverno-validate.yaml` | `validate` | Deployment missing required label denied; compliant accepted |
| mutate | `policy-kyverno-mutate.yaml` | `mutate` | Pod without target annotation gets it auto-added by mutating webhook |
| generate | `policy-kyverno-generate.yaml` | `generate` | Namespace with trigger label triggers downstream ConfigMap generation |
| image-verify | `policy-kyverno-image-verify.yaml` | `verifyImages` | Pod with non-allowlisted image denied; allowlisted image accepted |

### validate

Creates a `ClusterPolicy` with a `validate` rule that requires
`app.kubernetes.io/name` label on Deployments. Uses `deny` with a
CEL expression (Kyverno 1.18+/3.8+ supports CEL-based validation)
or a `pattern` match.

Non-compliant Deployment (missing `app.kubernetes.io/name`) → denied with
message naming the policy name. Compliant Deployment → accepted.

### mutate

Creates a `ClusterPolicy` with a `mutate` rule using a `patchesJson6902`
patch to add the annotation `kyverno.io/managed-by: chart-test-swarm`
to any Pod that lacks it.

A Pod manifest applied without the annotation will have it auto-added.
Verified via `kubectl get pod -o jsonpath='{.metadata.annotations.kyverno\.io/managed-by}'`.

### generate

Creates a `ClusterPolicy` with a `generate` rule that creates a
`ConfigMap` named `kyverno-generated-config` in any new namespace
labeled `kyverno.io/generate: "true"`. The ConfigMap carries a
single data key `generated-by: kyverno`.

Creating a namespace with the trigger label causes Kyverno's background
controller to create the ConfigMap within 10s.

### image-verify

Creates a `ClusterPolicy` with a `verifyImages` rule that checks
container images against a simple allowlist (images must come from
`public.ecr.aws/*` OR `nginx*`). Images from other registries (e.g.,
`docker.io/library/redis:7-alpine`) are denied.

**Note:** Full Cosign signature verification requires a keyring and
attested images. This variant uses an image allowlist approach (matched
via `imageReferences` patterns) to exercise the verifyImages rule type
without requiring external signature infrastructure. The primer documents
how to upgrade to full signature attestation verification.

## Assertions

| Type | What it verifies |
|---|---|
| `helm-status-deployed` | Product chart installed successfully |
| `pods-ready` (kyverno) | Kyverno admission + background + cleanup + reports pods Ready |
| `pods-ready` (sample) | Product pods Ready |
| `smoke-script` | Admission webhook probing (per variant) |

All smoke-script assertions follow the pattern:
- Wait for controller pods Ready
- Apply ClusterPolicy
- Wait for webhook sync (8s)
- Probe compliant + non-compliant manifests

## Feasibility checklist for the consumer chart

**Required:**
- [ ] Chart has at least one pod-owning kind (Deployment / StatefulSet / DaemonSet)
      — Kyverno's admission policies target pod templates.

**Soft (non-compliance findings, not harness failures):**
- [ ] Chart sets `app.kubernetes.io/name` label on pod templates
- [ ] All containers declare CPU + memory resource limits and requests
- [ ] No container images use `latest` tag
- [ ] Container images are from a pinnable, trusted registry
- [ ] Chart does not create ClusterRole / ClusterRoleBinding with wildcard verbs
- [ ] Chart pods do not run as root (`runAsNonRoot: true`)
- [ ] Chart supports annotation propagation (for mutate rules) and namespace labeling (for generate rules)

## Known gotchas

- **Webhook sync takes 5-10s after ClusterPolicy creation** — Kyverno
  dynamically updates its webhook configurations based on installed policies.
  Always sleep 8-10s after applying a ClusterPolicy before probing.
  Failure signal: dry-run returns exit 0 when it should fail.

- **Generate rules need the background controller** — The `backgroundController`
  must be enabled (it is by default). Generate rules do NOT fire during
  admission; they are processed asynchronously by the background controller.
  Allow up to 10s for generation.

- **`--forceFailurePolicyIgnore` is a container flag, not a chart value** —
  To change failure policy from Fail to Ignore, set:
  ```yaml
  admissionController:
    extraArgs:
      forceFailurePolicyIgnore: true
  ```
  The default (flag absent) is `Fail`.

- **CEL expressions require Kyverno 1.18+/3.8+** — Older Kyverno versions
  only support `pattern`-based validation. The validate variant uses a
  pattern-based approach for broad compatibility.

- **Kyverno v3 namespace** — Kyverno installs into the `kyverno` namespace
  by default (not `kyverno-system`). Earlier versions used `kyverno`.

- **PolicyReport CRDs are installed by default** — The reports controller
  produces `PolicyReport` and `ClusterPolicyReport` resources. These may
  appear in the policy-report namespace. The primer does not test these
  reports directly but documents their existence.

- **Image verification with real signatures** — Full Cosign/Notary signature
  verification requires: (a) a public key or keyring Secret in the Kyverno
  namespace, (b) images that have been signed with the corresponding private
  key, (c) the Kyverno `verifyImages` rule referencing the key. The primer's
  image-verify variant uses image pattern matching for self-contained testing.

## Webhook failure mode

Kyverno defaults to `failurePolicy: Fail` on all its dynamically-managed
validating and mutating webhook configurations. This means:

- **Fail (default):** If the Kyverno webhook is unavailable, ALL admission
  requests matching the webhook's rules are **rejected**. This prevents
  policy bypass during outages.
- **Ignore:** If changed via `--forceFailurePolicyIgnore=true`, an unavailable
  webhook **silently admits** all requests regardless of policy.

To verify the webhook failure policy in a live cluster:

```bash
# Check the validating webhook configuration
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{.webhooks[0].failurePolicy}'
# Output: Fail

# Check the mutating webhook configuration
kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
  -o jsonpath='{.webhooks[0].failurePolicy}'
# Output: Fail
```

### Deliberate-outage probe

Kyverno **dynamically manages** its webhook configurations. When the
admission controller pod terminates (e.g., scaled to 0), Kubernetes
garbage collection removes the webhook configs via ownerReferences.
This means admission is effectively **bypassed** during an outage
despite `failurePolicy: Fail` — because the webhook configuration
itself is removed.

This is a known architectural difference from Gatekeeper (which uses
static webhook configs). For clusters that require admission to
**always** fail closed during an outage, Kyverno recommends running at
least 2 admission controller replicas with pod anti-affinity.

```bash
# Scale down the admission controller
kubectl scale deploy/kyverno-admission-controller -n kyverno --replicas=0

# Wait for pod termination + webhook config GC (usually < 5s)
kubectl wait pod -l app.kubernetes.io/component=admission-controller \
  -n kyverno --for=delete --timeout=2m

# Check if webhook config still exists (may have been GC'd)
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg

# If webhook config still present: apply FAILS with timeout
# If webhook config was GC'd: apply SUCCEEDS (admission bypassed)
kubectl apply --dry-run=server -f test-deploy.yaml 2>&1

# Restore the controller
kubectl scale deploy/kyverno-admission-controller -n kyverno --replicas=1
```

With `Ignore` mode explicitly set (not recommended for production), the
outcome is identical — admission succeeds because there is no webhook to
call:

```bash
# Reinstall Kyverno with forceFailurePolicyIgnore
helm upgrade kyverno kyverno/kyverno -n kyverno \
  --set admissionController.extraArgs.forceFailurePolicyIgnore=true \
  --reuse-values

# Scale down, apply resource — succeeds despite outage
kubectl scale deploy/kyverno-admission-controller -n kyverno --replicas=0
kubectl apply --dry-run=server -f test-deploy.yaml 2>&1
# Expected: "deployment.apps/test-deploy created (server dry run)" (exit 0)
```

**Bottom line:** Kyverno's `failurePolicy: Fail` on the webhook
configuration is architecturally different from Gatekeeper's static
webhook. Because Kyverno dynamically manages and cleans up its
webhooks, the effective failure mode during a controller outage is
**always Ignore** (admission bypassed). The `Fail` setting only takes
effect when the webhook endpoint is reachable but returns an error — not
when the webhook config itself is garbage collected.

## References

- [Kyverno docs](https://kyverno.io/docs/)
- [Kyverno Helm chart](https://artifacthub.io/packages/helm/kyverno/kyverno)
- [ClusterPolicy reference](https://kyverno.io/docs/policy-types/cluster-policy/)
- [Validate rules](https://kyverno.io/docs/policy-types/cluster-policy/validate/)
- [Mutate rules](https://kyverno.io/docs/policy-types/cluster-policy/mutate/)
- [Generate rules](https://kyverno.io/docs/policy-types/cluster-policy/generate/)
- [Verify Images](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/)
- [Kyverno policies library](https://kyverno.io/policies/)
- [Webhook configuration](https://kyverno.io/docs/installation/customization/#webhooks)
