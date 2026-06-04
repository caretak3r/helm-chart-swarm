## Area: Policy Engines

Behavioral validation assertions for Milestone 7 — policy-engine integrations:
F7.1 `opa-gatekeeper`, F7.2 `kyverno`.

All cluster operations are executed on a kind cluster whose name matches
`chart-test-swarm-<id>`. Admission-rejection assertions use `kubectl
--dry-run=server` so they exercise the live admission webhook without
mutating cluster state.

---

### VAL-POLICY-001: opa-gatekeeper primer present after category reorg
The primer markdown file MUST exist at the canonical post-reorg path under the
`policy/` subdir, documenting gatekeeper preinstall, the inverted feasibility
model (soft checks surface chart non-compliances), and helm-test pattern using
ConstraintTemplates + Constraints with dry-run server-side apply.
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/policy/opa-gatekeeper.md)

### VAL-POLICY-002: kyverno primer authored
A new Kyverno primer MUST exist documenting the kyverno helm chart preinstall,
feasibility checklist, helm-test pattern for ClusterPolicy authoring + dry-run
admission probing, and failure-mode discussion (webhook timeout, policy-report
lag, image-verify keyring trust).
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/policy/kyverno.md)

### VAL-POLICY-003: every policy scenario YAML validates against schema
Each scenario file produced for F7.1/F7.2 (8 variants combined) MUST parse
successfully and validate against `engine/templates/scenario.schema.json` with
no additional-property or missing-required errors.
Tool: jsonschema
Evidence: terminal-output — exit code 0; no error lines per file

### VAL-POLICY-004: opa-gatekeeper has 3-4 schema-valid variants
Scenarios named `policy-opa-gatekeeper-{required-labels,image-allowlist,resource-limits,sync-config}.yaml` MUST exist under `examples/sample-product-chart/chart-test/scenarios/`, each with `cluster.provider: kind`, designed to be invoked with the `CLUSTER_NAME` env var matching `^chart-test-swarm-[a-z0-9-]+$`, and a `cluster.preinstall` entry pulling the `gatekeeper/gatekeeper` helm chart at the pinned version from the primer.
Tool: yq
Evidence: file(examples/sample-product-chart/chart-test/scenarios/policy-opa-gatekeeper-*.yaml) for each of the 4 variants

### VAL-POLICY-005: kyverno has 3-4 schema-valid variants
Scenarios named `policy-kyverno-{validate,mutate,generate,image-verify}.yaml` MUST exist with the `kyverno/kyverno` helm chart in `cluster.preinstall` at a pinned version and a `validatingWebhookFailurePolicy: Fail` override (so policy enforcement is not silently skipped).
Tool: yq
Evidence: file(examples/sample-product-chart/chart-test/scenarios/policy-kyverno-*.yaml) for each of the 4 variants

### VAL-POLICY-006: opa-gatekeeper required-labels — ConstraintTemplate establishes
On the `policy-opa-gatekeeper-required-labels` variant, after the helm-test
pod applies its setup ConfigMap, the ConstraintTemplate `k8srequiredlabels`
MUST reach `status.byPod[*].observedGeneration` >= `metadata.generation` and
the matching CRD `k8srequiredlabels.constraints.gatekeeper.sh` MUST report
`condition=Established=True` within 90s.
Tool: kubectl
Evidence: kubectl-output(constrainttemplate); kubectl-output(crd) — `kubectl wait crd/k8srequiredlabels.constraints.gatekeeper.sh --for=condition=Established --timeout=90s` exits 0

### VAL-POLICY-007: opa-gatekeeper required-labels — non-compliant Deployment rejected
A Deployment intentionally missing the required `app.kubernetes.io/name` label
applied with `kubectl --dry-run=server` MUST be rejected by the
ValidatingAdmissionWebhook with a clear error message referencing the
constraint name and the missing label.
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server -f noncompliant.yaml` exit code non-zero; stderr contains `admission webhook` and `Missing required label(s): {"app.kubernetes.io/name"}`

### VAL-POLICY-008: opa-gatekeeper required-labels — compliant Deployment accepted
The mirror Deployment with the required label set MUST pass the same dry-run
admission check (exit 0, no `admission webhook ... denied` line in stderr).
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server -f compliant.yaml` exit code 0; stdout contains `deployment.apps/<name> created (server dry run)`

### VAL-POLICY-009: opa-gatekeeper image-allowlist — non-allowlisted image denied
On the `policy-opa-gatekeeper-image-allowlist` variant, a Deployment whose pod
template uses an image from a registry NOT in the `K8sAllowedRepos` parameter
list MUST be denied at admission with the webhook message naming the
disallowed registry.
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server` exit code non-zero; stderr contains `admission webhook` and the offending image string

### VAL-POLICY-010: opa-gatekeeper image-allowlist — allowlisted image accepted
A mirror Deployment using an image from the allowlisted registry MUST pass
the same dry-run admission check (exit 0).
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server -f compliant-image.yaml` exit code 0

### VAL-POLICY-011: opa-gatekeeper resource-limits — Deployment without limits denied
On the `policy-opa-gatekeeper-resource-limits` variant, a Deployment whose
containers omit `resources.limits.cpu` or `resources.limits.memory` MUST be
denied with the `K8sContainerLimits` constraint message naming the offending
container.
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server` exit code non-zero; stderr names the container missing the limit

### VAL-POLICY-012: opa-gatekeeper sync-config — Config resource present
On the `policy-opa-gatekeeper-sync-config` variant, a Gatekeeper `Config`
resource MUST exist in the `gatekeeper-system` namespace with `spec.sync.syncOnly`
listing at least one referential type (e.g., `Namespace`, `Service`) so
referential constraints can resolve.
Tool: kubectl
Evidence: kubectl-output(config) — `kubectl -n gatekeeper-system get config config -o yaml` shows non-empty `spec.sync.syncOnly`

### VAL-POLICY-013: kyverno validate — non-compliant Deployment rejected
On the `policy-kyverno-validate` variant, a Deployment violating the
ClusterPolicy validation rule (e.g., missing required label, latest tag,
runAsRoot) MUST be denied by the kyverno admission webhook with a message
referencing the policy + rule name.
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server -f noncompliant.yaml` exit code non-zero; stderr contains `admission webhook "validate.kyverno.svc-fail"` and the policy name

### VAL-POLICY-014: kyverno validate — compliant Deployment accepted
The corresponding compliant Deployment MUST pass the same dry-run check
(exit 0).
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server -f compliant.yaml` exit code 0

### VAL-POLICY-015: kyverno mutate — pod without annotation gets it auto-added
On the `policy-kyverno-mutate` variant, after applying a Pod manifest that
LACKS the target annotation, the resulting in-cluster Pod (after the mutating
webhook fires) MUST carry the annotation set by the ClusterPolicy mutate rule.
Tool: kubectl
Evidence: kubectl-output(pod) — `kubectl -n <ns> get pod <pod-name> -o jsonpath='{.metadata.annotations}'` contains the policy-injected key/value

### VAL-POLICY-016: kyverno generate — namespace triggers ConfigMap / NetworkPolicy creation
On the `policy-kyverno-generate` variant, creating a fresh namespace labelled
to match the ClusterPolicy `match` block MUST cause kyverno to generate the
template's downstream resource (default ConfigMap or default-deny NetworkPolicy)
in that namespace within 10s.
Tool: kubectl
Evidence: kubectl-output(configmap/networkpolicy) — `kubectl -n <new-ns> get cm,networkpolicy` lists the generated resource named per the policy

### VAL-POLICY-017: kyverno image-verify — unsigned image denied (best-effort)
On the `policy-kyverno-image-verify` variant, a Pod referencing an image
without the configured signature attestation MUST be denied by the kyverno
verifyImages rule with an error message naming the policy.
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server` exit code non-zero; stderr names the verifyImages rule

### VAL-POLICY-018: every policy variant produces a PASS result.yaml on kind
After `dispatch-swarm.sh` executes all 8 policy variants on the mission's
kind cluster, each `reports/run-*/result.yaml` entry MUST report
`status: PASS` with non-empty `detail` per assertion and a populated
`artifacts/` directory.
Tool: yq
Evidence: file(reports/run-*/result.yaml); file(reports/run-*/artifacts/<scenario>/versions.json)

### VAL-POLICY-019: helm lint passes for the sample chart with policy-variant overrides
For each of the 8 policy variants, `helm lint examples/sample-product-chart/chart --values <applied-overrides>` exits 0 — proving the override pattern in the primer renders without templating errors.
Tool: helm
Evidence: terminal-output — `helm lint` reports `1 chart(s) linted, 0 chart(s) failed`

### VAL-POLICY-020: Policy webhook failure mode is documented and exercised
Each policy primer (opa-gatekeeper, kyverno) declares in a "Webhook failure mode" section whether the chart-as-shipped configures `failurePolicy: Fail` or `failurePolicy: Ignore`. For at least one variant per engine, the rendered admission webhook (verified via `kubectl get validatingwebhookconfiguration -o yaml`) shows the declared failurePolicy. A scenario that intentionally takes the policy controller offline (e.g., `kubectl scale deploy/gatekeeper-controller --replicas=0`) THEN applies a target resource exhibits the documented behavior (apply succeeds under Ignore; apply fails with webhook-timeout under Fail). Pass requires primer-documented + cluster-observed + scenario-exercised match.
Tool: kubectl
Evidence: file(<primer>.md contains `## Webhook failure mode`), kubectl-output(`.webhooks[0].failurePolicy`), terminal-output(deliberate-outage probe result)
