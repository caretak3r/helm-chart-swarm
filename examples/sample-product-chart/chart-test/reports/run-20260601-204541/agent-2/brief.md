# Agent 2 Brief — run run-20260601-204541

You are executor 2 of 4 in a `chart-test-swarm` run.

- **Project:**    `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart`
- **Run dir:**    `reports/run-20260601-204541/`
- **Your dir:**   `reports/run-20260601-204541/agent-2/`

## Your assigned scenarios

- **`certificates-cert-manager-lets-encrypt-staging`** — cert-manager Let's Encrypt staging issuer
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates-cert-manager-lets-encrypt-staging.yaml`
  - desc: Installs cert-manager with Let's Encrypt staging ACME issuer. Verifies ClusterIssuer Ready=True and uses self-signed fallback Certificate to confirm chart pods serve TLS.
- **`certificates-manual-tls-secret-ecdsa`** — manual-tls-secret ECDSA key
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-ecdsa.yaml`
  - desc: Delivers a pre-provisioned TLS Secret with ECDSA P-256 key via raw_manifest. Verifies cert has id-ecPublicKey algorithm and pods serve HTTPS with the ECDSA key.
- **`certificates-mounted-tls-certs-pvc-mount`** — mounted-tls-certs pvc-mount
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates-mounted-tls-certs-pvc-mount.yaml`
  - desc: Creates a PVC, populates it with TLS certs via a Job, then installs the chart with a persistentVolumeClaim-backed TLS volume. Verifies the pod mount and HTTPS serving.
- **`gateway-api-contour-gateway-api-basic`** — Contour Gateway API Basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api-contour-gateway-api-basic.yaml`
  - desc: Installs Gateway API CRDs and Contour Gateway Provisioner, creates GatewayClass contour + Gateway + HTTPRoute, and verifies HTTP routing through the auto-provisioned Envoy proxy.
- **`gateway-api-envoy-gateway-grpcroute`** — Envoy Gateway GRPCRoute
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api-envoy-gateway-grpcroute.yaml`
  - desc: Installs Gateway API CRDs and envoy-gateway controller, deploys a gRPC backend, creates GRPCRoute, and verifies gRPC reflection through the Envoy proxy.
- **`gateway-api-istio-gateway-api-basic`** — Istio Gateway API Basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api-istio-gateway-api-basic.yaml`
  - desc: Installs istio/base + istio/istiod and Gateway API CRDs, creates GatewayClass istio + Gateway + HTTPRoute, and verifies HTTP routing through auto-provisioned Istio data-plane.
- **`ingress-controllers-contour-tls-delegation`** — Contour TLS delegation
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/ingress-controllers-contour-tls-delegation.yaml`
  - desc: Installs Contour, deploys TLS Secret in tls-secrets NS, grants cross-namespace access via TLSCertificateDelegation, creates HTTPProxy with delegated Secret, verifies HTTPS 200.
- **`ingress-controllers-nginx-ingress-snippet-annotations`** — NGINX Ingress snippet annotations
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/ingress-controllers-nginx-ingress-snippet-annotations.yaml`
  - desc: Installs NGINX Ingress with allowSnippetAnnotations=true, creates an Ingress with configuration-snippet annotation injecting add_header X-Test, verifies the header appears.
- **`ingress-controllers-traefik-middleware-chain`** — Traefik middleware chain
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/ingress-controllers-traefik-middleware-chain.yaml`
  - desc: Installs Traefik, creates a Middleware CR that injects custom headers, references it from an IngressRoute, and verifies the middleware effect is observable.
- **`policy-kyverno-image-verify`** — Kyverno image-verify: only approved registries
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy-kyverno-image-verify.yaml`
  - desc: Installs Kyverno, creates a ClusterPolicy that only allows images from public.ecr.aws/* or nginx* registries. Verifies a Pod referencing docker.io/library/redis:7-alpine is denied (stderr names rule), while a Pod with an approved image is accepted. Webhook failure mode: Fail.
- **`policy-opa-gatekeeper-required-labels`** — OPA Gatekeeper required labels enforcement
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy-opa-gatekeeper-required-labels.yaml`
  - desc: Installs OPA Gatekeeper + NGINX Ingress, creates k8srequiredlabels ConstraintTemplate + Constraint targeting Deployments and Ingress. Verifies non-compliant resources denied, compliant accepted. Cross-feature compose with M4 nginx-ingress.
- **`service-mesh-istio-ingress-gateway-jwt`** — Istio Ingress Gateway — JWT Authentication
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-ingress-gateway-jwt.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart, creates an Istio Gateway + VirtualService, applies a RequestAuthentication + AuthorizationPolicy requiring a valid JWT, and verifies: (a) requests without a Bearer token are rejected with 401/403, (b) requests with a valid JWT signed by the test issuer key from fixtures/service-mesh/jwt/ return HTTP 200.
- **`service-mesh-istio-service-mesh-peer-authentication`** — Istio Service Mesh — PeerAuthentication lifecycle
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-service-mesh-peer-authentication.yaml`
  - desc: Installs istio/base + istio/istiod, deploys the product chart with mesh.inject=true, and exercises the PeerAuthentication lifecycle: PERMISSIVE mode allows both mesh and non-mesh traffic; switching to STRICT mode blocks non-mesh traffic while mesh traffic continues via auto-upgraded mTLS.
- **`service-mesh-linkerd-basic-mesh`** — Linkerd — Basic Mesh (Sidecar Injection)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-linkerd-basic-mesh.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane via Helm, annotates the product namespace with linkerd.io/inject=enabled, deploys the product chart with scope.enabled=true, and verifies every product pod has a linkerd-proxy sidecar alongside the app container (2-container pods), with linkerd check --proxy returning healthy.
- **`subchart-postgres-internal`** — Internal postgres subchart enabled
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/subchart-postgres-internal.yaml`
  - desc: Product chart bundles postgres via subchart; verify both come up together.




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
   `reports/run-20260601-204541/agent-2/result.yaml` using this schema:

   ```yaml
   agent: 2
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
