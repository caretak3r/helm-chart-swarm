# Agent 1 Brief — run run-20260601-204541

You are executor 1 of 4 in a `chart-test-swarm` run.

- **Project:**    `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart`
- **Run dir:**    `reports/run-20260601-204541/`
- **Your dir:**   `reports/run-20260601-204541/agent-1/`

## Your assigned scenarios

- **`certificates-cert-manager-jks-pkcs12`** — cert-manager JKS/PKCS12 keystore bundle
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates-cert-manager-jks-pkcs12.yaml`
  - desc: Installs cert-manager with a self-signed ClusterIssuer, issues a Certificate, wraps tls.crt+tls.key into a PKCS12 bundle, and stores as a new Secret alongside the TLS material.
- **`certificates-manual-tls-secret-basic`** — manual-tls-secret basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-basic.yaml`
  - desc: Delivers a pre-provisioned TLS Secret (RSA 2048) via raw_manifest preinstall and verifies the chart serves HTTPS with it. No cert-manager dependency.
- **`certificates-mounted-tls-certs-projected-volume`** — mounted-tls-certs projected-volume
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates-mounted-tls-certs-projected-volume.yaml`
  - desc: Creates a TLS Secret, then installs the chart using a projected volume that projects the Secret into the pod. Verifies projected volume source and HTTPS serving.
- **`envoy-gateway`** — Envoy Gateway (Gateway API)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/envoy-gateway.yaml`
  - desc: Installs Envoy Gateway controller via OCI helm chart (CRDs are bundled in the chart's crds/ directory and installed automatically by Helm before templates). Verifies chart coexists with a running gateway controller.
- **`gateway-api-envoy-gateway-cert-manager-tls`** — Envoy Gateway + cert-manager TLS
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api-envoy-gateway-cert-manager-tls.yaml`
  - desc: Installs cert-manager and envoy-gateway, issues a TLS certificate, creates Gateway with HTTPS listener using cert-manager Secret, and verifies HTTPS serving with expected cert.
- **`gateway-api-istio-gateway-api-backend-tls-policy`** — Istio Gateway API BackendTLSPolicy
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api-istio-gateway-api-backend-tls-policy.yaml`
  - desc: Installs istio/base + istio/istiod and Gateway API CRDs, generates self-signed TLS certs at runtime, creates BackendTLSPolicy targeting the Service, and verifies Policy acceptance and gateway routing.
- **`ingress-controllers-contour-rate-limit`** — Contour rate limit
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/ingress-controllers-contour-rate-limit.yaml`
  - desc: Installs Contour, creates an HTTPProxy with local rateLimitPolicy (5 req/min), and verifies that exceeding the limit produces 429 responses while requests within the limit succeed.
- **`ingress-controllers-nginx-ingress-default-backend`** — NGINX Ingress custom default backend
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/ingress-controllers-nginx-ingress-default-backend.yaml`
  - desc: Installs NGINX Ingress with custom default backend Deployment+Service, verifies requests without matching Host return the custom backend's distinctive body instead of stock 404.
- **`ingress-controllers-traefik-ingressroute-crd`** — Traefik IngressRoute CRD
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/ingress-controllers-traefik-ingressroute-crd.yaml`
  - desc: Installs Traefik, uses IngressRoute CRD exclusively for routing (no classic Ingress), and verifies HTTP traffic reaches the backend.
- **`policy-kyverno-generate`** — Kyverno generate: ConfigMap in labeled namespaces
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy-kyverno-generate.yaml`
  - desc: Installs Kyverno, creates a ClusterPolicy that generates a ConfigMap in any namespace labeled kyverno.io/generate=true. Verifies that creating a fresh namespace with the trigger label causes Kyverno to generate the ConfigMap within 10s. Webhook failure mode: Fail.
- **`policy-opa-gatekeeper-image-allowlist`** — OPA Gatekeeper image allowlist enforcement
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy-opa-gatekeeper-image-allowlist.yaml`
  - desc: Installs OPA Gatekeeper, creates k8sallowedrepos ConstraintTemplate + Constraint allowing only nginx + public.ecr.aws images. Verifies non-allowlisted image denied, allowlisted image accepted.
- **`service-mesh-istio-ingress-gateway-basic`** — Istio Ingress Gateway — Basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-ingress-gateway-basic.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart with ingress disabled, creates an Istio Gateway + VirtualService to route external traffic through the ingressgateway pod, and verifies HTTP 200 via the gateway with a Host header.
- **`service-mesh-istio-service-mesh-cert-manager-tls`** — Istio Service Mesh + cert-manager TLS Gateway
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-service-mesh-cert-manager-tls.yaml`
  - desc: Cross-feature compose: installs cert-manager + istio (base + istiod + gateway), creates a cert-manager self-signed ClusterIssuer and Certificate that issues a TLS Secret, then creates an Istio Gateway with a TLS listener referencing that Secret via credentialName. Verifies: istioctl analyze clean, HTTPS through gateway returns 200 with the cert-manager-issued certificate.
- **`service-mesh-istio-service-mesh-telemetry-v2`** — Istio Service Mesh — Telemetry v2
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-service-mesh-telemetry-v2.yaml`
  - desc: Installs istio/base + istio/istiod, deploys the product chart with mesh.inject=true, applies a Telemetry resource in the product namespace to configure Envoy access logging and metrics, and verifies proxy stats are accessible and telemetry configuration is active.
- **`service-mesh-linkerd-service-profile`** — Linkerd — ServiceProfile (Per-Route Observability)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-linkerd-service-profile.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane via Helm, annotates the product namespace for injection, deploys the product chart, creates a ServiceProfile CRD for the sample Service defining routes with timeout and retry policies, and verifies the ServiceProfile is recognized.




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
   `reports/run-20260601-204541/agent-1/result.yaml` using this schema:

   ```yaml
   agent: 1
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
