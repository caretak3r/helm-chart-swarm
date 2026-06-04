# Agent 2 Brief — run --dry-run

You are executor 2 of 2 in a `chart-test-swarm` run.

- **Project:**    `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart`
- **Run dir:**    `reports/--dry-run/`
- **Your dir:**   `reports/--dry-run/agent-2/`

## Your assigned scenarios

- **`certificates-cert-manager-jks-pkcs12`** — cert-manager JKS/PKCS12 keystore bundle
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-cert-manager-jks-pkcs12.yaml`
  - desc: Installs cert-manager with a self-signed ClusterIssuer, issues a Certificate, wraps tls.crt+tls.key into a PKCS12 bundle, and stores as a new Secret alongside the TLS material.
- **`certificates-cert-manager-self-signed-ca`** — cert-manager self-signed CA issuer
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-cert-manager-self-signed-ca.yaml`
  - desc: Installs cert-manager, creates a self-signed ClusterIssuer, issues a Certificate for the product Service FQDN, and verifies HTTPS serving with --cacert.
- **`certificates-manual-tls-secret-basic`** — manual-tls-secret basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-manual-tls-secret-basic.yaml`
  - desc: Delivers a pre-provisioned TLS Secret (RSA 2048) via raw_manifest preinstall and verifies the chart serves HTTPS with it. No cert-manager dependency.
- **`certificates-manual-tls-secret-multiple-sans`** — manual-tls-secret multiple SANs
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-manual-tls-secret-multiple-sans.yaml`
  - desc: Delivers a pre-provisioned TLS Secret with 3 DNS SANs (sample.sample.svc, api.sample.sample.svc, admin.sample.sample.svc) via raw_manifest and verifies the cert has >=2 SAN entries.
- **`certificates-mounted-tls-certs-projected-volume`** — mounted-tls-certs projected-volume
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-mounted-tls-certs-projected-volume.yaml`
  - desc: Creates a TLS Secret, then installs the chart using a projected volume that projects the Secret into the pod. Verifies projected volume source and HTTPS serving.
- **`with-cert-manager`** — Customer ships cert-manager preinstalled
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/with-cert-manager.yaml`
  - desc: Validates chart coexists with cert-manager and its CRDs.
- **`gateway-api-contour-gateway-api-basic`** — Contour Gateway API Basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-contour-gateway-api-basic.yaml`
  - desc: Installs Gateway API CRDs and Contour Gateway Provisioner, creates GatewayClass contour + Gateway + HTTPRoute, and verifies HTTP routing through the auto-provisioned Envoy proxy.
- **`gateway-api-contour-gateway-api-route-precedence`** — Contour Gateway API Route Precedence
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-contour-gateway-api-route-precedence.yaml`
  - desc: Installs Gateway API CRDs + Contour Gateway Provisioner, creates GatewayClass contour + Gateway + two HTTPRoutes with overlapping prefixes, verifies more specific route wins.
- **`gateway-api-envoy-gateway-grpcroute`** — Envoy Gateway GRPCRoute
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-envoy-gateway-grpcroute.yaml`
  - desc: Installs Gateway API CRDs and envoy-gateway controller, deploys a gRPC backend, creates GRPCRoute, and verifies gRPC reflection through the Envoy proxy.
- **`gateway-api-envoy-gateway-security-policy-attach`** — Envoy Gateway SecurityPolicy (CORS)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-envoy-gateway-security-policy-attach.yaml`
  - desc: Installs Gateway API CRDs and envoy-gateway controller, creates HTTPRoute with SecurityPolicy (CORS) attaching to the route, and verifies CORS header on preflight.
- **`gateway-api-istio-gateway-api-basic`** — Istio Gateway API Basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-istio-gateway-api-basic.yaml`
  - desc: Installs istio/base + istio/istiod and Gateway API CRDs, creates GatewayClass istio + Gateway + HTTPRoute, and verifies HTTP routing through auto-provisioned Istio data-plane.
- **`ingress-controllers-contour-basic-httpproxy`** — Contour basic HTTPProxy
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-contour-basic-httpproxy.yaml`
  - desc: Installs Contour, creates an HTTPProxy for the product Service, and verifies HTTP routing through the envoy pod IP with Host header matching and HTTPProxy status valid.
- **`ingress-controllers-contour-tls-delegation`** — Contour TLS delegation
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-contour-tls-delegation.yaml`
  - desc: Installs Contour, deploys TLS Secret in tls-secrets NS, grants cross-namespace access via TLSCertificateDelegation, creates HTTPProxy with delegated Secret, verifies HTTPS 200.
- **`ingress-controllers-nginx-ingress-canary`** — NGINX Ingress canary traffic splitting
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-nginx-ingress-canary.yaml`
  - desc: Installs NGINX Ingress controller with stable+canary Ingresses (canary-weight=20), deploys a canary backend with distinctive response, verifies ~20% of 100 probes hit canary.
- **`ingress-controllers-nginx-ingress-snippet-annotations`** — NGINX Ingress snippet annotations
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-nginx-ingress-snippet-annotations.yaml`
  - desc: Installs NGINX Ingress with allowSnippetAnnotations=true, creates an Ingress with configuration-snippet annotation injecting add_header X-Test, verifies the header appears.
- **`ingress-controllers-traefik-basic`** — Traefik basic IngressRoute
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-traefik-basic.yaml`
  - desc: Installs Traefik, creates an IngressRoute for the product Service, and verifies HTTP routing through the Traefik pod IP with Host header matching.
- **`ingress-controllers-traefik-middleware-chain`** — Traefik middleware chain
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-traefik-middleware-chain.yaml`
  - desc: Installs Traefik, creates a Middleware CR that injects custom headers, references it from an IngressRoute, and verifies the middleware effect is observable.
- **`customer-b-gatekeeper`** — Customer B — OPA Gatekeeper admission policies
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/customer-b-gatekeeper.yaml`
  - desc: Customer B runs Gatekeeper with strict admission policies. Chart must satisfy required-labels + no-privileged constraints.
- **`policy-kyverno-image-verify`** — Kyverno image-verify: only approved registries
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-kyverno-image-verify.yaml`
  - desc: Installs Kyverno, creates a ClusterPolicy that only allows images from public.ecr.aws/* or nginx* registries. Verifies a Pod referencing docker.io/library/redis:7-alpine is denied (stderr names rule), while a Pod with an approved image is accepted. Webhook failure mode: Fail.
- **`policy-kyverno-validate`** — Kyverno validate: require labels on Deployments
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-kyverno-validate.yaml`
  - desc: Installs Kyverno, creates a ClusterPolicy that requires app.kubernetes.io/name label on Deployments. Verifies non-compliant Deployment denied (stderr names validate.kyverno.svc-fail and policy name), compliant Deployment accepted. Webhook failure mode: Fail.
- **`policy-opa-gatekeeper-required-labels`** — OPA Gatekeeper required labels enforcement
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-opa-gatekeeper-required-labels.yaml`
  - desc: Installs OPA Gatekeeper + NGINX Ingress, creates k8srequiredlabels ConstraintTemplate + Constraint targeting Deployments and Ingress. Verifies non-compliant resources denied, compliant accepted. Cross-feature compose with M4 nginx-ingress.
- **`policy-opa-gatekeeper-sync-config`** — OPA Gatekeeper sync configuration
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-opa-gatekeeper-sync-config.yaml`
  - desc: Installs OPA Gatekeeper, applies Gatekeeper Config with sync.syncOnly listing Namespace, Pod, and Ingress kinds for OPA cache sync. Verifies Config exists with non-empty syncOnly, controller Ready.
- **`service-mesh-istio-ingress-gateway-basic`** — Istio Ingress Gateway — Basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-ingress-gateway-basic.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart with ingress disabled, creates an Istio Gateway + VirtualService to route external traffic through the ingressgateway pod, and verifies HTTP 200 via the gateway with a Host header.
- **`service-mesh-istio-ingress-gateway-multi-host`** — Istio Ingress Gateway — Multi-Host
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-ingress-gateway-multi-host.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart with scope.enabled=true, creates an Istio Gateway with two server blocks for different hosts, and a VirtualService that routes each host to a different backend (skywatcher vs scope). Verifies both hosts return HTTP 200 through the ingressgateway.
- **`service-mesh-istio-service-mesh-cert-manager-tls`** — Istio Service Mesh + cert-manager TLS Gateway
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-service-mesh-cert-manager-tls.yaml`
  - desc: Cross-feature compose: installs cert-manager + istio (base + istiod + gateway), creates a cert-manager self-signed ClusterIssuer and Certificate that issues a TLS Secret, then creates an Istio Gateway with a TLS listener referencing that Secret via credentialName. Verifies: istioctl analyze clean, HTTPS through gateway returns 200 with the cert-manager-issued certificate.
- **`service-mesh-istio-service-mesh-sidecar-injection`** — Istio Service Mesh — Sidecar Injection
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-service-mesh-sidecar-injection.yaml`
  - desc: Installs istio/base + istio/istiod, enables mesh injection on the product namespace, deploys the product chart with mesh.inject=true and scope.enabled=true, and verifies every product pod has exactly 2 containers including istio-proxy and in-mesh HTTP reaches the product Service with 200.
- **`service-mesh-istio-service-mesh-telemetry-v2`** — Istio Service Mesh — Telemetry v2
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-service-mesh-telemetry-v2.yaml`
  - desc: Installs istio/base + istio/istiod, deploys the product chart with mesh.inject=true, applies a Telemetry resource in the product namespace to configure Envoy access logging and metrics, and verifies proxy stats are accessible and telemetry configuration is active.
- **`service-mesh-linkerd-mtls-rotation`** — Linkerd — mTLS Identity Rotation
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-linkerd-mtls-rotation.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane via Helm, annotates the product namespace for injection, deploys the product chart, and verifies that mTLS identities are issued and valid by running linkerd check --proxy and inspecting the identity issuer certificate. Documents the mTLS rotation window and trust-anchor expiry.
- **`service-mesh-linkerd-service-profile`** — Linkerd — ServiceProfile (Per-Route Observability)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-linkerd-service-profile.yaml`
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
   `reports/--dry-run/agent-2/result.yaml` using this schema:

   ```yaml
   agent: 2
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
