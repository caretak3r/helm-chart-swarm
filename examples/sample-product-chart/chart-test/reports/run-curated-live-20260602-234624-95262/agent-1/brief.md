# Agent 1 Brief — run run-curated-live-20260602-234624-95262

You are executor 1 of 1 in a `chart-test-swarm` run.

- **Project:**    `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart`
- **Run dir:**    `reports/run-curated-live-20260602-234624-95262/`
- **Your dir:**   `reports/run-curated-live-20260602-234624-95262/agent-1/`

## Your assigned scenarios

- **`annotations-on`** — Capability: custom annotations stamped on every object (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/annotations-on.yaml`
  - desc: Renders the product chart with a global annotation knob set (extraAnnotations.example\.com/owner=team-x) and asserts every rendered object (all kinds) carries the configured annotation at .metadata.annotations. The sample chart does NOT expose an extraAnnotations/commonAnnotations knob — this scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks global annotation propagation.
- **`labels-on`** — Capability: extra labels stamped on every object (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/labels-on.yaml`
  - desc: Renders the product chart with a global extra-label knob set (extraLabels.team=platform, extraLabels.cost-center=42) and asserts every rendered object (all kinds, not just pod templates) carries the configured labels at .metadata.labels. The sample chart does NOT expose an extraLabels/commonLabels knob — this scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks global label propagation.
- **`rbac-on`** — Capability: RBAC objects present when enabled (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/rbac-on.yaml`
  - desc: Renders the product chart with rbac.create=true and serviceAccount.create=true and asserts a ServiceAccount, Role or ClusterRole, and matching RoleBinding or ClusterRoleBinding are present with correct wiring (roleRef, subjects, serviceAccountName). The sample chart does NOT include RBAC templates — no serviceaccount.yaml, role.yaml, or rolebinding.yaml exists. Setting rbac.create=true has no effect because the chart lacks the templates. This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks rbac.create and serviceAccount.create knobs.
- **`scheme-https-only`** — Capability: HTTPS-only scheme enforcement (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/scheme-https-only.yaml`
  - desc: Renders the product chart with TLS enabled (tls.enabled=true) and asserts no plain-HTTP Service port, container port, probe, or Ingress backend is present. The sample chart does NOT support suppressing the HTTP port — when TLS is enabled it merely ADDS an HTTPS port (443) alongside the always-present HTTP port 80 on the Service, containerPort 80 on the Deployment, probes targeting port 80, and the Ingress backend pointing at service.port (80). This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks an HTTPS-only / http-disable knob. A TLS secret fixture is preinstalled so the chart can deploy with tls.enabled=true.
- **`tls-cert-manager-self-signed`** — cert-manager self-signed Issuer -> CA Cert -> CA Issuer -> leaf Cert
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/tls-cert-manager-self-signed.yaml`
  - desc: Installs cert-manager with CRDs, applies a self-signed Issuer, a CA Certificate bootstrapping a CA Secret, a CA Issuer backed by that Secret, and a leaf Certificate for the product Service FQDN. Deploys chart with tls.enabled=true and tls.secretName pointing at the issued Secret. Verifies HTTPS 200 with --cacert and SAN match.
- **`tls-manual-secret`** — Manual TLS Secret via raw_manifest
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/tls-manual-secret.yaml`
  - desc: Delivers a pre-provisioned kubernetes.io/tls Secret (RSA 2048) via raw_manifest preinstall sourced from chart-test/fixtures/, no inline base64 blobs. The chart mounts it with tls.volumeType=secret (default) and serves HTTPS 200. Validates Secret type, data keys, PEM validity, and in-cluster HTTPS reachability.
- **`tls-mounted-projected`** — TLS via projected volume
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/tls-mounted-projected.yaml`
  - desc: Creates a kubernetes.io/tls Secret, then deploys the chart with tls.volumeType=projected so the pod has a projected volume sourcing the TLS Secret. Verifies projected volume source, tls.crt/tls.key present at mountPath, and in-cluster HTTPS curl returns 200.
- **`gateway-api-istio-gateway-api-basic`** — Istio Gateway API Basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-istio-gateway-api-basic.yaml`
  - desc: Installs istio/base + istio/istiod and Gateway API CRDs, creates GatewayClass istio + Gateway + HTTPRoute, and verifies HTTP routing through auto-provisioned Istio data-plane.
- **`ingress-controllers-contour-basic-httpproxy`** — Contour basic HTTPProxy (gap-probe)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-contour-basic-httpproxy.yaml`
  - desc: Installs Contour, creates an HTTPProxy for the product Service via fixture, and verifies HTTP routing through the envoy pod IP with Host header matching and HTTPProxy status valid. Then runs a gap-probe: the chart does NOT natively emit a Contour HTTPProxy CRD — the HTTPProxy was created by the fixture, not by a chart template. This is an honest gap (red cell); do NOT over-engineer the chart.
- **`networking-kong-ingress`** — Kong Ingress (className=kong)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/networking-kong-ingress.yaml`
  - desc: Installs Kong Ingress Controller, deploys the product chart with ingress.enabled=true and ingress.className=kong, and verifies end-to-end routing through the Kong proxy data path via the chart's built-in Ingress resource. Also includes a KongPlugin gap-probe documenting that the sample chart exposes no konghq.com/plugins annotation or KongPlugin CRD knob, which is an honest gap (red cell) — do NOT over-engineer the chart.
- **`networking-metallb-loadbalancer`** — MetalLB LoadBalancer (service.type=LoadBalancer)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/networking-metallb-loadbalancer.yaml`
  - desc: Installs MetalLB, configures an IPAddressPool + L2Advertisement whose CIDR is inside the kind Docker bridge subnet, deploys the product chart with service.type=LoadBalancer, and verifies that MetalLB assigns an external IP from the pool and the LB endpoint serves HTTP 200.
- **`networking-traefik-ingress`** — Traefik Ingress (className=traefik)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/networking-traefik-ingress.yaml`
  - desc: Installs Traefik, deploys the product chart with ingress.enabled=true and ingress.className=traefik, and verifies end-to-end routing through the Traefik data path via the chart's built-in Ingress resource.
- **`policy-opa-gatekeeper-required-labels`** — OPA Gatekeeper required labels enforcement (gap-probe)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-opa-gatekeeper-required-labels.yaml`
  - desc: Installs OPA Gatekeeper + NGINX Ingress, creates k8srequiredlabels ConstraintTemplate + Constraint targeting Deployments and Ingresses. Verifies non-compliant resources denied, compliant accepted. Cross-feature compose with M4 nginx-ingress. Then runs a gap-probe: the chart's Ingress template uses selectorLabels (just app: <release>) instead of the full common labels (which include app.kubernetes.io/name), so the chart's Ingress fails the required-labels constraint — an honest gap (red cell); do NOT over-engineer the chart.
- **`service-mesh-istio-ambient-live`** — Istio Ambient Mesh — Live mTLS Verification (ztunnel/HBONE)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-ambient-live.yaml`
  - desc: Installs istio/base + istio/istiod (profile=ambient) + istio/cni (profile=ambient) + istio/ztunnel, annotates the product namespace istio.io/dataplane-mode=ambient via raw_manifest, deploys the chart with mesh.inject=false (NO sidecar), and proves: (1) ztunnel DaemonSet pods are Ready in istio-system, (2) the product namespace carries the ambient annotation and every product pod has exactly 1 container (no istio-proxy), (3) in-mesh traffic to the product Service returns HTTP 200 and the connection is mTLS over HBONE — confirmed via ztunnel metrics/logs. Emits a PASS artifact bundle with 1-container pod manifest, ambient-annotated namespace manifest, applied-overrides recording inject: false, and versions.json.
- **`service-mesh-istio-ingress-gateway-basic`** — Istio Ingress Gateway — Basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-ingress-gateway-basic.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart with ingress disabled, creates an Istio Gateway + VirtualService to route external traffic through the ingressgateway pod, and verifies HTTP 200 via the gateway with a Host header.
- **`service-mesh-istio-service-mesh-strict-mtls`** — Istio Service Mesh — strict mTLS
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-service-mesh-strict-mtls.yaml`
  - desc: Installs istio/base + istio/istiod, enables mesh injection, deploys the product chart with scope.enabled=true, creates a PeerAuthentication with mode=STRICT in the product namespace, and verifies: (a) plain HTTP from a non-mesh pod is rejected, (b) in-mesh probe pod still reaches the product Service with 200 via auto-upgraded mTLS.
- **`service-mesh-istio-sidecar-live`** — Istio Sidecar Mesh — Live mTLS Verification
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-sidecar-live.yaml`
  - desc: Installs istio/base + istio/istiod, pre-labels the product namespace istio-injection=enabled via raw_manifest, deploys the chart with mesh.inject=true, and proves: (1) istiod is Ready and the sidecar injector webhook is present, (2) every product pod has exactly 2 containers including istio-proxy, (3) in-mesh traffic to the product Service returns HTTP 200 and the connection is mTLS — confirmed via istio-proxy stats reporting non-zero inbound SSL handshakes. Emits a PASS artifact bundle with 2-container pod manifest, applied-overrides recording inject: true, and versions.json.
- **`service-mesh-linkerd-live`** — Linkerd — Live mTLS Sidecar Mesh
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-linkerd-live.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane (with a preinstalled trust anchor / issuer cert via raw_manifest), annotates the product namespace with linkerd.io/inject=enabled, deploys the chart, and proves: (1) linkerd control-plane pods Ready and proxy-injector webhook present, (2) every product pod has a linkerd-proxy container alongside the app container, (3) linkerd check --proxy -n sample exits 0 confirming the data plane is healthy. Emits a PASS artifact bundle with a 2-container pod manifest, linkerd.io/inject-annotated namespace, and versions.json.




## Your task

For each assigned scenario YAML:

1. Run end-to-end via the engine:
   ```bash
   bash engine/scripts/run-scenario.sh <scenario.yaml>
   ```
   That brings the cluster up, applies preinstall addons, installs the
   product chart, runs the asserts, and emits a per-scenario
   `result.yaml` into `reports/scenario-<id>-<ts>/`.

2. Aggregate your scenarios' results into a single `result.yaml` at
   `reports/run-curated-live-20260602-234624-95262/agent-1/result.yaml` using this schema:

   ```yaml
   agent: 1
   run_id: run-curated-live-20260602-234624-95262
   results:
     - scenario_id: <id from scenario yaml>
       status: PASS | FAIL | PARTIAL | INCONCLUSIVE
       duration_s: <seconds>
       fail_stage: ""           # only on non-PASS
       fail_msg: ""             # only on non-PASS, include reproduction command
       log_dir: /tmp/.../...
       asserts:
         - { type: pods-ready,           status: PASS, notes: "..." }
         - { type: helm-status-deployed, status: PASS, notes: "..." }
   ```

3. Between scenarios, tear down state cleanly:
   ```bash
   bash engine/scripts/cluster-down.sh
   ```
   so the next scenario starts from a known cluster. (Or use a separate
   cluster name per scenario via `CLUSTER_NAME` env.)

## Discipline

- **No PASS without a positive assertion.** Every PASS must capture at
  least one observable proof (kubectl event, helm status, exit code).
- **No FAIL without a reproduction command.** `fail_msg` must contain
  the exact command sequence that reproduces the failure.
- **INCONCLUSIVE is a valid status.** Use it when something
  intermittent or unobservable prevents a clean PASS/FAIL judgment.
- **Don't lie to the dashboard.** If you skipped a scenario, leave it
  out — the aggregator will surface it as UNTESTED.
