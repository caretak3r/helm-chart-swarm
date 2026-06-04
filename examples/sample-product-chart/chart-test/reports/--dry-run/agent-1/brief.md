# Agent 1 Brief — run --dry-run

You are executor 1 of 2 in a `chart-test-swarm` run.

- **Project:**    `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart`
- **Run dir:**    `reports/--dry-run/`
- **Your dir:**   `reports/--dry-run/agent-1/`

## Your assigned scenarios

- **`minimal`** — Vanilla cluster — no preinstalled addons
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/minimal.yaml`
  - desc: Baseline: chart installs and pods come up on a stock kind cluster.
- **`certificates-cert-manager-lets-encrypt-staging`** — cert-manager Let's Encrypt staging issuer
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-cert-manager-lets-encrypt-staging.yaml`
  - desc: Installs cert-manager with Let's Encrypt staging ACME issuer. Verifies ClusterIssuer Ready=True and uses self-signed fallback Certificate to confirm chart pods serve TLS.
- **`certificates-cert-manager-wildcard`** — cert-manager wildcard certificate
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-cert-manager-wildcard.yaml`
  - desc: Installs cert-manager with a self-signed ClusterIssuer, issues a wildcard Certificate with SAN DNS:*.test.local + test.local, and verifies both SANs are present.
- **`certificates-manual-tls-secret-ecdsa`** — manual-tls-secret ECDSA key
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-manual-tls-secret-ecdsa.yaml`
  - desc: Delivers a pre-provisioned TLS Secret with ECDSA P-256 key via raw_manifest. Verifies cert has id-ecPublicKey algorithm and pods serve HTTPS with the ECDSA key.
- **`certificates-mounted-tls-certs-csi-secret-store`** — mounted-tls-certs csi-secret-store
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-mounted-tls-certs-csi-secret-store.yaml`
  - desc: Installs the secrets-store-csi-driver helm chart and a stub SecretProviderClass, then installs the chart with a TLS secret volume. Verifies CSI driver presence, SecretProviderClass resource, and that the product pod serves HTTPS. Full CSI volume mount verification requires a real CSI provider plugin (e.g. AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, or HashiCorp Vault) which is not available on kind; the scenario validates CSI infrastructure deployment and documents the mount verification as a SKIP on kind.
- **`certificates-mounted-tls-certs-pvc-mount`** — mounted-tls-certs pvc-mount
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-mounted-tls-certs-pvc-mount.yaml`
  - desc: Creates a PVC, populates it with TLS certs via a Job, then installs the chart with a persistentVolumeClaim-backed TLS volume. Verifies the pod mount and HTTPS serving.
- **`envoy-gateway`** — Envoy Gateway (Gateway API)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/envoy-gateway.yaml`
  - desc: Installs Envoy Gateway controller via OCI helm chart (CRDs are bundled in the chart's crds/ directory and installed automatically by Helm before templates). Verifies chart coexists with a running gateway controller.
- **`gateway-api-contour-gateway-api-response-header-modifier`** — Contour Gateway API Response Header Modifier
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-contour-gateway-api-response-header-modifier.yaml`
  - desc: Installs Gateway API CRDs + Contour Gateway Provisioner, creates GatewayClass contour + Gateway + HTTPRoute with ResponseHeaderModifier filter, verifies X-Powered-By header.
- **`gateway-api-envoy-gateway-cert-manager-tls`** — Envoy Gateway + cert-manager TLS
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-envoy-gateway-cert-manager-tls.yaml`
  - desc: Installs cert-manager and envoy-gateway, issues a TLS certificate, creates Gateway with HTTPS listener using cert-manager Secret, and verifies HTTPS serving with expected cert.
- **`gateway-api-envoy-gateway-httproute`** — Envoy Gateway HTTPRoute
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-envoy-gateway-httproute.yaml`
  - desc: Installs Gateway API CRDs and envoy-gateway controller, creates GatewayClass+Gateway+HTTPRoute, and verifies HTTP routing through the Envoy proxy.
- **`gateway-api-istio-gateway-api-backend-tls-policy`** — Istio Gateway API BackendTLSPolicy
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-istio-gateway-api-backend-tls-policy.yaml`
  - desc: Installs istio/base + istio/istiod and Gateway API CRDs, generates self-signed TLS certs at runtime, creates BackendTLSPolicy targeting the Service, and verifies Policy acceptance and gateway routing.
- **`gateway-api-istio-gateway-api-multi-listener`** — Istio Gateway API Multi-Listener
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-istio-gateway-api-multi-listener.yaml`
  - desc: Installs istio/base + istio/istiod and Gateway API CRDs, creates Gateway with HTTP:80 + HTTPS:443 listeners, and verifies both protocols with TLS certificate.
- **`ingress-controllers-contour-rate-limit`** — Contour rate limit
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-contour-rate-limit.yaml`
  - desc: Installs Contour, creates an HTTPProxy with local rateLimitPolicy (5 req/min), and verifies that exceeding the limit produces 429 responses while requests within the limit succeed.
- **`ingress-controllers-nginx-ingress-basic`** — NGINX Ingress basic routing
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-nginx-ingress-basic.yaml`
  - desc: Installs NGINX Ingress controller, creates an Ingress with ingressClassName: nginx, and verifies Host-header routing returns HTTP 200.
- **`ingress-controllers-nginx-ingress-default-backend`** — NGINX Ingress custom default backend
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-nginx-ingress-default-backend.yaml`
  - desc: Installs NGINX Ingress with custom default backend Deployment+Service, verifies requests without matching Host return the custom backend's distinctive body instead of stock 404.
- **`ingress-controllers-nginx-ingress-tls-cert-manager`** — NGINX Ingress TLS with cert-manager
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-nginx-ingress-tls-cert-manager.yaml`
  - desc: Installs cert-manager + NGINX Ingress, creates self-signed ClusterIssuer+Certificate, verifies HTTPS routing through nginx with TLS terminated by cert-manager-issued cert chain.
- **`ingress-controllers-traefik-ingressroute-crd`** — Traefik IngressRoute CRD
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-traefik-ingressroute-crd.yaml`
  - desc: Installs Traefik, uses IngressRoute CRD exclusively for routing (no classic Ingress), and verifies HTTP traffic reaches the backend.
- **`ingress-controllers-traefik-tls-passthrough`** — Traefik TLS passthrough
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-traefik-tls-passthrough.yaml`
  - desc: Installs Traefik, configures IngressRouteTCP with tls.passthrough=true, and verifies the backend's TLS certificate is served untouched through the proxy.
- **`policy-kyverno-generate`** — Kyverno generate: ConfigMap in labeled namespaces
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-kyverno-generate.yaml`
  - desc: Installs Kyverno, creates a ClusterPolicy that generates a ConfigMap in any namespace labeled kyverno.io/generate=true. Verifies that creating a fresh namespace with the trigger label causes Kyverno to generate the ConfigMap within 10s. Webhook failure mode: Fail.
- **`policy-kyverno-mutate`** — Kyverno mutate: auto-add annotation to Pods
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-kyverno-mutate.yaml`
  - desc: Installs Kyverno, creates a ClusterPolicy that adds the annotation kyverno.io/managed-by: chart-test-swarm to Pods. Verifies a Pod manifest lacking the annotation gets it auto-added after the mutating webhook fires. Webhook failure mode: Fail.
- **`policy-opa-gatekeeper-image-allowlist`** — OPA Gatekeeper image allowlist enforcement
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-opa-gatekeeper-image-allowlist.yaml`
  - desc: Installs OPA Gatekeeper, creates k8sallowedrepos ConstraintTemplate + Constraint allowing only nginx + public.ecr.aws images. Verifies non-allowlisted image denied, allowlisted image accepted.
- **`policy-opa-gatekeeper-resource-limits`** — OPA Gatekeeper resource limits enforcement
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-opa-gatekeeper-resource-limits.yaml`
  - desc: Installs OPA Gatekeeper, creates k8scontainerlimits ConstraintTemplate + Constraint requiring CPU and memory limits on all containers. Verifies Deployment without limits denied, compliant Deployment accepted.
- **`customer-a-istio`** — Customer A — Istio mesh + cert-manager
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/customer-a-istio.yaml`
  - desc: Customer A's profile: istio sidecar injection, istio-ingress, cert-manager.
- **`service-mesh-istio-ingress-gateway-jwt`** — Istio Ingress Gateway — JWT Authentication
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-ingress-gateway-jwt.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart, creates an Istio Gateway + VirtualService, applies a RequestAuthentication + AuthorizationPolicy requiring a valid JWT, and verifies: (a) requests without a Bearer token are rejected with 401/403, (b) requests with a valid JWT signed by the test issuer key from fixtures/service-mesh/jwt/ return HTTP 200.
- **`service-mesh-istio-ingress-gateway-request-authentication`** — Istio Ingress Gateway — RequestAuthentication (No Deny)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-ingress-gateway-request-authentication.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart, creates an Istio Gateway + VirtualService, applies a RequestAuthentication that validates JWTs from the test issuer but does NOT require them (no AuthorizationPolicy). Verifies: (a) requests without a token still pass through (HTTP 200), (b) requests with a valid JWT also return 200, and (c) requests with an invalid JWT (wrong issuer) are rejected with 401 by RequestAuthentication validation alone.
- **`service-mesh-istio-service-mesh-peer-authentication`** — Istio Service Mesh — PeerAuthentication lifecycle
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-service-mesh-peer-authentication.yaml`
  - desc: Installs istio/base + istio/istiod, deploys the product chart with mesh.inject=true, and exercises the PeerAuthentication lifecycle: PERMISSIVE mode allows both mesh and non-mesh traffic; switching to STRICT mode blocks non-mesh traffic while mesh traffic continues via auto-upgraded mTLS.
- **`service-mesh-istio-service-mesh-strict-mtls`** — Istio Service Mesh — strict mTLS
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-service-mesh-strict-mtls.yaml`
  - desc: Installs istio/base + istio/istiod, enables mesh injection, deploys the product chart with scope.enabled=true, creates a PeerAuthentication with mode=STRICT in the product namespace, and verifies: (a) plain HTTP from a non-mesh pod is rejected, (b) in-mesh probe pod still reaches the product Service with 200 via auto-upgraded mTLS.
- **`service-mesh-linkerd-basic-mesh`** — Linkerd — Basic Mesh (Sidecar Injection)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-linkerd-basic-mesh.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane via Helm, annotates the product namespace with linkerd.io/inject=enabled, deploys the product chart with scope.enabled=true, and verifies every product pod has a linkerd-proxy sidecar alongside the app container (2-container pods), with linkerd check --proxy returning healthy.
- **`service-mesh-linkerd-multi-cluster-preview`** — Linkerd — Multi-Cluster Preview
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-linkerd-multi-cluster-preview.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane + linkerd-multicluster extension via Helm, verifies the multicluster Link and ServiceMirror CRDs are established, and authors a preview Link resource targeting a logical target cluster. No real cross-cluster traffic — this variant validates that the multicluster extension installs cleanly and that the CRD scaffolding is functional.
- **`subchart-postgres-internal`** — Internal postgres subchart enabled
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/storage/subchart-postgres-internal.yaml`
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
   `reports/--dry-run/agent-1/result.yaml` using this schema:

   ```yaml
   agent: 1
   run_id: --dry-run
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
