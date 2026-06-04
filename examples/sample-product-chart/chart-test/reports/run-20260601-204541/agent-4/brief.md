# Agent 4 Brief — run run-20260601-204541

You are executor 4 of 4 in a `chart-test-swarm` run.

- **Project:**    `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart`
- **Run dir:**    `reports/run-20260601-204541/`
- **Your dir:**   `reports/run-20260601-204541/agent-4/`

## Your assigned scenarios

- **`certificates-cert-manager-wildcard`** — cert-manager wildcard certificate
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates-cert-manager-wildcard.yaml`
  - desc: Installs cert-manager with a self-signed ClusterIssuer, issues a wildcard Certificate with SAN DNS:*.test.local + test.local, and verifies both SANs are present.
- **`certificates-mounted-tls-certs-csi-secret-store`** — mounted-tls-certs csi-secret-store
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates-mounted-tls-certs-csi-secret-store.yaml`
  - desc: Installs the secrets-store-csi-driver helm chart and a stub SecretProviderClass, then installs the chart with a TLS secret volume. Verifies CSI driver presence, SecretProviderClass resource, and that the product pod serves HTTPS. Full CSI volume mount verification requires a real CSI provider plugin (e.g. AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, or HashiCorp Vault) which is not available on kind; the scenario validates CSI infrastructure deployment and documents the mount verification as a SKIP on kind.
- **`customer-b-gatekeeper`** — Customer B — OPA Gatekeeper admission policies
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/customer-B-gatekeeper.yaml`
  - desc: Customer B runs Gatekeeper with strict admission policies. Chart must satisfy required-labels + no-privileged constraints.
- **`gateway-api-contour-gateway-api-route-precedence`** — Contour Gateway API Route Precedence
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api-contour-gateway-api-route-precedence.yaml`
  - desc: Installs Gateway API CRDs + Contour Gateway Provisioner, creates GatewayClass contour + Gateway + two HTTPRoutes with overlapping prefixes, verifies more specific route wins.
- **`gateway-api-envoy-gateway-security-policy-attach`** — Envoy Gateway SecurityPolicy (CORS)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api-envoy-gateway-security-policy-attach.yaml`
  - desc: Installs Gateway API CRDs and envoy-gateway controller, creates HTTPRoute with SecurityPolicy (CORS) attaching to the route, and verifies CORS header on preflight.
- **`ingress-controllers-contour-basic-httpproxy`** — Contour basic HTTPProxy
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/ingress-controllers-contour-basic-httpproxy.yaml`
  - desc: Installs Contour, creates an HTTPProxy for the product Service, and verifies HTTP routing through the envoy pod IP with Host header matching and HTTPProxy status valid.
- **`ingress-controllers-nginx-ingress-canary`** — NGINX Ingress canary traffic splitting
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/ingress-controllers-nginx-ingress-canary.yaml`
  - desc: Installs NGINX Ingress controller with stable+canary Ingresses (canary-weight=20), deploys a canary backend with distinctive response, verifies ~20% of 100 probes hit canary.
- **`ingress-controllers-traefik-basic`** — Traefik basic IngressRoute
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/ingress-controllers-traefik-basic.yaml`
  - desc: Installs Traefik, creates an IngressRoute for the product Service, and verifies HTTP routing through the Traefik pod IP with Host header matching.
- **`minimal`** — Vanilla cluster — no preinstalled addons
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/minimal.yaml`
  - desc: Baseline: chart installs and pods come up on a stock kind cluster.
- **`policy-kyverno-validate`** — Kyverno validate: require labels on Deployments
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy-kyverno-validate.yaml`
  - desc: Installs Kyverno, creates a ClusterPolicy that requires app.kubernetes.io/name label on Deployments. Verifies non-compliant Deployment denied (stderr names validate.kyverno.svc-fail and policy name), compliant Deployment accepted. Webhook failure mode: Fail.
- **`policy-opa-gatekeeper-sync-config`** — OPA Gatekeeper sync configuration
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy-opa-gatekeeper-sync-config.yaml`
  - desc: Installs OPA Gatekeeper, applies Gatekeeper Config with sync.syncOnly listing Namespace, Pod, and Ingress kinds for OPA cache sync. Verifies Config exists with non-empty syncOnly, controller Ready.
- **`service-mesh-istio-ingress-gateway-request-authentication`** — Istio Ingress Gateway — RequestAuthentication (No Deny)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-ingress-gateway-request-authentication.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart, creates an Istio Gateway + VirtualService, applies a RequestAuthentication that validates JWTs from the test issuer but does NOT require them (no AuthorizationPolicy). Verifies: (a) requests without a token still pass through (HTTP 200), (b) requests with a valid JWT also return 200, and (c) requests with an invalid JWT (wrong issuer) are rejected with 401 by RequestAuthentication validation alone.
- **`service-mesh-istio-service-mesh-strict-mtls`** — Istio Service Mesh — strict mTLS
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-service-mesh-strict-mtls.yaml`
  - desc: Installs istio/base + istio/istiod, enables mesh injection, deploys the product chart with scope.enabled=true, creates a PeerAuthentication with mode=STRICT in the product namespace, and verifies: (a) plain HTTP from a non-mesh pod is rejected, (b) in-mesh probe pod still reaches the product Service with 200 via auto-upgraded mTLS.
- **`service-mesh-linkerd-multi-cluster-preview`** — Linkerd — Multi-Cluster Preview
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-linkerd-multi-cluster-preview.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane + linkerd-multicluster extension via Helm, verifies the multicluster Link and ServiceMirror CRDs are established, and authors a preview Link resource targeting a logical target cluster. No real cross-cluster traffic — this variant validates that the multicluster extension installs cleanly and that the CRD scaffolding is functional.




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
   `reports/run-20260601-204541/agent-4/result.yaml` using this schema:

   ```yaml
   agent: 4
   run_id: run-20260601-204541
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
