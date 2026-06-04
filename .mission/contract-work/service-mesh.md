## Area: Service Mesh

Behavioral validation assertions for Milestone 6 — service-mesh integrations:
F6.1 `istio-service-mesh`, F6.2 `istio-ingress-gateway`, F6.3 `linkerd`.

All cluster operations are executed on a kind cluster whose name matches
`chart-test-swarm-<id>`. Assertions are written so they can be re-derived from
the reports artifact bundle alone.

---

### VAL-MESH-001: istio-service-mesh primer present after category reorg
The primer markdown file MUST exist at the canonical post-reorg path,
documenting cluster preinstall, feasibility checklist, helm-test pattern, and
common failure modes for the integration.
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/service-mesh/istio-service-mesh.md)

### VAL-MESH-002: istio-ingress-gateway primer present after category reorg
The primer markdown file MUST exist at the canonical post-reorg path with the
gateway-component preinstall block, feasibility checklist, helm-test pattern
covering Gateway + VirtualService application, and Istio Gateway vs Gateway API
disambiguation guidance.
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/service-mesh/istio-ingress-gateway.md)

### VAL-MESH-003: linkerd primer authored
A new Linkerd primer MUST exist documenting `linkerd-control-plane` preinstall,
feasibility checklist (no `hostNetwork`, no `runAsNonRoot: false`-forbidden
constraints), helm-test pattern injecting the test pod, and failure-mode
discussion (`linkerd check` failures, proxy not injected, mTLS rotation lag).
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/service-mesh/linkerd.md)

### VAL-MESH-004: every service-mesh scenario YAML validates against schema
Each scenario file produced for F6.1/F6.2/F6.3 (the 12 variants combined) MUST
parse successfully and validate against `engine/templates/scenario.schema.json`
with no additional-property or missing-required errors.
Tool: jsonschema
Evidence: terminal-output (exit code 0; no error lines per file)

### VAL-MESH-005: istio-service-mesh has 3-4 schema-valid variants
Scenarios named `service-mesh-istio-service-mesh-{sidecar-injection,strict-mtls,peer-authentication,telemetry-v2}.yaml` MUST exist under `examples/sample-product-chart/chart-test/scenarios/`, each with `cluster.provider: kind`, designed to be invoked with the `CLUSTER_NAME` env var matching `^chart-test-swarm-[a-z0-9-]+$`, and a complete `cluster.preinstall` list referencing the istio base + istiod charts.
Tool: yq
Evidence: file(examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-service-mesh-*.yaml) for each of the 4 variants

### VAL-MESH-006: istio-ingress-gateway has 3-4 schema-valid variants
Scenarios named `service-mesh-istio-ingress-gateway-{basic,multi-host,jwt,request-authentication}.yaml` MUST exist with the istio gateway helm chart added to `cluster.preinstall` and (for jwt + request-authentication variants) the JWT fixtures referenced under `examples/sample-product-chart/chart-test/fixtures/service-mesh/`.
Tool: yq
Evidence: file(examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-ingress-gateway-*.yaml) for each of the 4 variants

### VAL-MESH-007: linkerd has 3-4 schema-valid variants
Scenarios named `service-mesh-linkerd-{basic-mesh,multi-cluster-preview,service-profile,mtls-rotation}.yaml` MUST exist, each with linkerd `helm` preinstall items (or `raw_manifest` for CRD bootstrap) and a product release that opts the namespace into mesh injection via the `linkerd.io/inject: enabled` annotation.
Tool: yq
Evidence: file(examples/sample-product-chart/chart-test/scenarios/service-mesh-linkerd-*.yaml) for each of the 4 variants

### VAL-MESH-008: istio sidecar is injected into product pods
After `run-scenario.sh` completes the `istio-service-mesh-sidecar-injection`
variant on a kind cluster, every product pod selected by
`app.kubernetes.io/name=<release>` MUST have exactly 2 containers in
`.spec.containers[*].name`: the product container plus `istio-proxy`.
Tool: kubectl
Evidence: kubectl-output(pod) — `kubectl -n <ns> get pod -l app.kubernetes.io/name=<release> -o jsonpath='{.items[*].spec.containers[*].name}'` contains `istio-proxy`

### VAL-MESH-009: in-mesh pod can reach product Service over the sidecar
A second pod with `sidecar.istio.io/inject: "true"` and the namespace
`istio-injection=enabled` label issues an HTTP GET to the product Service FQDN
on its declared port and receives a 2xx response (curl exit 0 with `--fail`).
Tool: curl
Evidence: curl-response — HTTP 200 from `http://<release>.<ns>.svc.cluster.local:<port>/`, captured in the test pod log

### VAL-MESH-010: strict-mtls PeerAuthentication is enforced cluster-side
After the `strict-mtls` variant applies its setup, a `PeerAuthentication`
resource named `<release>-mtls` MUST exist in the product namespace with
`spec.mtls.mode == "STRICT"`.
Tool: kubectl
Evidence: kubectl-output(peerauthentication) — `kubectl -n <ns> get peerauthentication <release>-mtls -o yaml` shows `spec.mtls.mode: STRICT`

### VAL-MESH-011: plain HTTP from non-mesh pod is rejected under STRICT mTLS
A control pod created in a separate namespace with no Istio sidecar (and no
namespace injection label) issuing plain HTTP to the product Service under
the STRICT PeerAuthentication MUST be rejected — curl exits non-zero with
connection reset, or receives HTTP 503 — within the 15s probe timeout.
Tool: curl
Evidence: curl-response — non-zero exit / 503 / "Connection reset by peer" captured in helm-test log

### VAL-MESH-012: HTTPS / in-mesh traffic from mesh pod still works under STRICT mTLS
The mesh-resident probe pod (with sidecar injection enabled) issuing the same
HTTP request under STRICT MUST succeed (HTTP 200 via the auto-upgraded
sidecar-to-sidecar mTLS tunnel) — confirming the policy rejects only
non-mesh peers.
Tool: curl
Evidence: curl-response — HTTP 200 from in-mesh probe pod, captured in helm-test log

### VAL-MESH-013: istio Gateway resource is admitted and reconciled
After the `istio-ingress-gateway-basic` variant applies its setup, the
`networking.istio.io/v1beta1 Gateway` named `<release>-igw` MUST exist in the
product namespace and `kubectl get gateway` succeeds (no `no matches for kind`).
Tool: kubectl
Evidence: kubectl-output(gateway) — `kubectl -n <ns> get gateway <release>-igw -o yaml`

### VAL-MESH-014: VirtualService routes traffic through the ingress gateway
A request to the istio-ingressgateway pod IP with the Host header set to the
gateway's declared `hosts:` entry MUST be routed to the product Service and
return HTTP 200 from the application.
Tool: curl
Evidence: curl-response — HTTP 200 to `http://<gw-pod-ip>:80/` with `Host: <release>.test.local`, captured in helm-test log

### VAL-MESH-015: JWT variant rejects requests without a valid token
On the `istio-ingress-gateway-jwt` variant, a curl request through the
ingressgateway with no `Authorization: Bearer` header (or an invalid token)
MUST be rejected at the gateway with HTTP 401 or 403 from the
RequestAuthentication / AuthorizationPolicy combination.
Tool: curl
Evidence: curl-response — HTTP 401/403 captured in helm-test log

### VAL-MESH-016: JWT variant accepts requests with a valid token
On the same `istio-ingress-gateway-jwt` variant, the helm-test pod signs a
JWT with the test issuer key (mounted from `fixtures/service-mesh/jwt/`) and
curls the ingress gateway with `Authorization: Bearer <token>` — the request
MUST be admitted and return HTTP 200 from the product Service.
Tool: curl
Evidence: curl-response — HTTP 200 with valid bearer token, captured in helm-test log

### VAL-MESH-017: linkerd-proxy sidecar is injected into product pods
After `run-scenario.sh` completes the `linkerd-basic-mesh` variant, every
product pod MUST have a `linkerd-proxy` container alongside the product
container (2-container pod).
Tool: kubectl
Evidence: kubectl-output(pod) — `kubectl -n <ns> get pod -l app.kubernetes.io/name=<release> -o jsonpath='{.items[*].spec.containers[*].name}'` contains `linkerd-proxy`

### VAL-MESH-018: `linkerd check` reports healthy control plane and data plane
The helm-test probe pod invokes `linkerd check --proxy` (or the equivalent
in-cluster API call) against the linkerd control plane installed by
preinstall_items and the command MUST exit 0 with "Status check results are √".
Tool: bash
Evidence: terminal-output — `linkerd check` final line contains "Status check results are √" in helm-test log

### VAL-MESH-019: every service-mesh variant produces a PASS result.yaml on kind
After `dispatch-swarm.sh` executes all 12 service-mesh variants on the
mission's kind cluster, each `reports/run-*/result.yaml` entry for these
scenarios MUST report `status: PASS` with non-empty `detail` per assertion
and an `artifacts/` directory populated with `scenario.yaml`,
`applied-overrides.yaml`, and `versions.json`.
Tool: yq
Evidence: file(reports/run-*/result.yaml); file(reports/run-*/artifacts/<scenario>/versions.json) — `versions.json` contains keys helm, kubectl, kind, minikube, k8s_server

### VAL-MESH-020: helm lint passes for the sample chart with mesh-variant overrides
For each of the 12 service-mesh variants, `helm lint examples/sample-product-chart/chart --values <applied-overrides>` exits 0 — proving the override pattern in the primer renders without templating errors.
Tool: helm
Evidence: terminal-output — `helm lint` reports `1 chart(s) linted, 0 chart(s) failed`

### VAL-MESH-021: yamllint clean on all service-mesh scenario files
`yamllint engine/skills/chart-test-swarm/references/integrations/service-mesh/**/*.yaml examples/sample-product-chart/chart-test/scenarios/service-mesh-*.yaml` exits 0 (after the milestone's clean-as-you-go pass) — no remaining style errors on mesh-touched files.
Tool: bash
Evidence: terminal-output — `yamllint` exit code 0, no error lines

### VAL-MESH-022: Mesh teardown removes mesh-installed admission webhooks
After `cluster-down.sh` runs for a cluster that hosted a mesh variant (istio or linkerd), the next clean kind cluster created in the same Docker Desktop session shows zero `MutatingWebhookConfiguration` or `ValidatingWebhookConfiguration` entries with names matching `istio-sidecar-injector` or `linkerd-proxy-injector-webhook`. Pass requires zero mesh-installed webhooks survive teardown.
Tool: kubectl
Evidence: kubectl-output(`kubectl get mutatingwebhookconfiguration -o name | grep -E 'istio|linkerd'` returns empty), exit-code 1 from grep
