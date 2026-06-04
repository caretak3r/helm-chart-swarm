# Agent 3 Brief — run run-20260601-204541

You are executor 3 of 4 in a `chart-test-swarm` run.

- **Project:**    `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart`
- **Run dir:**    `reports/run-20260601-204541/`
- **Your dir:**   `reports/run-20260601-204541/agent-3/`

## Your assigned scenarios

- **`certificates-cert-manager-self-signed-ca`** — cert-manager self-signed CA issuer
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates-cert-manager-self-signed-ca.yaml`
  - desc: Installs cert-manager, creates a self-signed ClusterIssuer, issues a Certificate for the product Service FQDN, and verifies HTTPS serving with --cacert.
- **`certificates-manual-tls-secret-multiple-sans`** — manual-tls-secret multiple SANs
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-multiple-sans.yaml`
  - desc: Delivers a pre-provisioned TLS Secret with 3 DNS SANs (sample.sample.svc, api.sample.sample.svc, admin.sample.sample.svc) via raw_manifest and verifies the cert has >=2 SAN entries.
- **`customer-a-istio`** — Customer A — Istio mesh + cert-manager
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/customer-A-istio.yaml`
  - desc: Customer A's profile: istio sidecar injection, istio-ingress, cert-manager.
- **`gateway-api-contour-gateway-api-response-header-modifier`** — Contour Gateway API Response Header Modifier
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api-contour-gateway-api-response-header-modifier.yaml`
  - desc: Installs Gateway API CRDs + Contour Gateway Provisioner, creates GatewayClass contour + Gateway + HTTPRoute with ResponseHeaderModifier filter, verifies X-Powered-By header.
- **`gateway-api-envoy-gateway-httproute`** — Envoy Gateway HTTPRoute
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api-envoy-gateway-httproute.yaml`
  - desc: Installs Gateway API CRDs and envoy-gateway controller, creates GatewayClass+Gateway+HTTPRoute, and verifies HTTP routing through the Envoy proxy.
- **`gateway-api-istio-gateway-api-multi-listener`** — Istio Gateway API Multi-Listener
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api-istio-gateway-api-multi-listener.yaml`
  - desc: Installs istio/base + istio/istiod and Gateway API CRDs, creates Gateway with HTTP:80 + HTTPS:443 listeners, and verifies both protocols with TLS certificate.
- **`ingress-controllers-nginx-ingress-basic`** — NGINX Ingress basic routing
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/ingress-controllers-nginx-ingress-basic.yaml`
  - desc: Installs NGINX Ingress controller, creates an Ingress with ingressClassName: nginx, and verifies Host-header routing returns HTTP 200.
- **`ingress-controllers-nginx-ingress-tls-cert-manager`** — NGINX Ingress TLS with cert-manager
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/ingress-controllers-nginx-ingress-tls-cert-manager.yaml`
  - desc: Installs cert-manager + NGINX Ingress, creates self-signed ClusterIssuer+Certificate, verifies HTTPS routing through nginx with TLS terminated by cert-manager-issued cert chain.
- **`ingress-controllers-traefik-tls-passthrough`** — Traefik TLS passthrough
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/ingress-controllers-traefik-tls-passthrough.yaml`
  - desc: Installs Traefik, configures IngressRouteTCP with tls.passthrough=true, and verifies the backend's TLS certificate is served untouched through the proxy.
- **`policy-kyverno-mutate`** — Kyverno mutate: auto-add annotation to Pods
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy-kyverno-mutate.yaml`
  - desc: Installs Kyverno, creates a ClusterPolicy that adds the annotation kyverno.io/managed-by: chart-test-swarm to Pods. Verifies a Pod manifest lacking the annotation gets it auto-added after the mutating webhook fires. Webhook failure mode: Fail.
- **`policy-opa-gatekeeper-resource-limits`** — OPA Gatekeeper resource limits enforcement
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy-opa-gatekeeper-resource-limits.yaml`
  - desc: Installs OPA Gatekeeper, creates k8scontainerlimits ConstraintTemplate + Constraint requiring CPU and memory limits on all containers. Verifies Deployment without limits denied, compliant Deployment accepted.
- **`service-mesh-istio-ingress-gateway-multi-host`** — Istio Ingress Gateway — Multi-Host
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-ingress-gateway-multi-host.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart with scope.enabled=true, creates an Istio Gateway with two server blocks for different hosts, and a VirtualService that routes each host to a different backend (skywatcher vs scope). Verifies both hosts return HTTP 200 through the ingressgateway.
- **`service-mesh-istio-service-mesh-sidecar-injection`** — Istio Service Mesh — Sidecar Injection
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-service-mesh-sidecar-injection.yaml`
  - desc: Installs istio/base + istio/istiod, enables mesh injection on the product namespace, deploys the product chart with mesh.inject=true and scope.enabled=true, and verifies every product pod has exactly 2 containers including istio-proxy and in-mesh HTTP reaches the product Service with 200.
- **`service-mesh-linkerd-mtls-rotation`** — Linkerd — mTLS Identity Rotation
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh-linkerd-mtls-rotation.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane via Helm, annotates the product namespace for injection, deploys the product chart, and verifies that mTLS identities are issued and valid by running linkerd check --proxy and inspecting the identity issuer certificate. Documents the mTLS rotation window and trust-anchor expiry.
- **`with-cert-manager`** — Customer ships cert-manager preinstalled
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/with-cert-manager.yaml`
  - desc: Validates chart coexists with cert-manager and its CRDs.




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
   `reports/run-20260601-204541/agent-3/result.yaml` using this schema:

   ```yaml
   agent: 3
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
