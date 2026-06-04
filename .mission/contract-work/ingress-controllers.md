## Area: Ingress Controllers

Coverage: F4.1 traefik refresh + variants, F4.2 nginx-ingress primer + variants,
F4.3 contour primer + variants.

All cluster operations referenced below run on a cluster whose name matches
`^chart-test-swarm-[a-z0-9-]+$`. Scenario YAMLs live under
`examples/sample-product-chart/chart-test/scenarios/` and are validated against
`engine/templates/scenario.schema.json`. HTTP probes use `curl` with the appropriate
`Host:` header against the controller pod IP (kind has no LoadBalancer; this avoids
NodePort indirection, matching the pattern in the existing traefik primer).

### Structural / artifact assertions (per integration)

### VAL-INGRESS-001: traefik primer exists, is in the ingress-controllers/ subdir, and documents required preinstall_items
The primer file at `engine/skills/chart-test-swarm/references/integrations/ingress-controllers/traefik.md` exists, is non-empty, and contains a `## Cluster preinstall` section that declares the `traefik/traefik` Helm chart + its repo URL + the `wait: pods-ready` directive. The primer also documents what the controller does, when to pick it, and how IngressRoute CRD-based routing differs from classic Ingress.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/ingress-controllers/traefik.md`), terminal-output of `grep -E '^- chart: traefik/traefik' engine/skills/chart-test-swarm/references/integrations/ingress-controllers/traefik.md` returns ≥ 1 match, terminal-output of `grep -c '^## ' engine/skills/chart-test-swarm/references/integrations/ingress-controllers/traefik.md` ≥ 3

### VAL-INGRESS-002: traefik scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/ingress-controllers-traefik-*.yaml`, covering basic, tls-passthrough, middleware-chain, and (optionally) ingressroute-crd variants. Each file's `id` field matches its filename stem and `mechanisms` includes `addon:traefik`.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/ingress-controllers-traefik-*.yaml | wc -l` ≥ 3, terminal-output of `for f in examples/sample-product-chart/chart-test/scenarios/ingress-controllers-traefik-*.yaml; do yq -r '.mechanisms[]' "$f"; done | grep -c 'addon:traefik'` ≥ 3

### VAL-INGRESS-003: nginx-ingress primer exists and documents required preinstall_items
The primer at `engine/skills/chart-test-swarm/references/integrations/ingress-controllers/nginx-ingress.md` exists, is non-empty, and contains a `## Cluster preinstall` section declaring the `ingress-nginx/ingress-nginx` Helm chart (or `kubernetes/ingress-nginx`) with its repo URL and a `pods-ready` wait. It documents what NGINX Ingress does, when to use it (annotation-driven snippets, canary, default-backend), and how the consumer chart wires `ingressClassName: nginx`.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/ingress-controllers/nginx-ingress.md`), terminal-output of `grep -E '^- chart: (ingress-nginx|kubernetes/ingress-nginx)' engine/skills/chart-test-swarm/references/integrations/ingress-controllers/nginx-ingress.md` returns ≥ 1 match

### VAL-INGRESS-004: nginx-ingress scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/ingress-controllers-nginx-ingress-*.yaml`, covering basic, snippet-annotations, default-backend, and canary variants.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/ingress-controllers-nginx-ingress-*.yaml | wc -l` ≥ 3

### VAL-INGRESS-005: contour primer exists and documents required preinstall_items
The primer at `engine/skills/chart-test-swarm/references/integrations/ingress-controllers/contour.md` exists, is non-empty, and documents the `bitnami/contour` (or `projectcontour/contour`) Helm chart preinstall, what Contour does, when to use HTTPProxy CRD vs classic Ingress, and how TLS delegation works.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/ingress-controllers/contour.md`), terminal-output of `grep -E '^- chart: .*/contour' engine/skills/chart-test-swarm/references/integrations/ingress-controllers/contour.md` returns ≥ 1 match

### VAL-INGRESS-006: contour scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/ingress-controllers-contour-*.yaml`, covering basic-httpproxy, tls-delegation, rate-limit, and (optionally) jwt-auth variants.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/ingress-controllers-contour-*.yaml | wc -l` ≥ 3

### Variant execution assertions (traefik)

### VAL-INGRESS-007: traefik-basic scenario routes HTTP traffic through the controller
Running `bash engine/scripts/run-scenario.sh examples/sample-product-chart/chart-test/scenarios/ingress-controllers-traefik-basic.yaml` against a `chart-test-swarm-<test-id>` kind cluster results in `status: PASS`. An in-cluster `curl -H "Host: sample.test.local" http://<traefik-pod-ip>/` returns `HTTP/1.1 200 OK` with a body served by the product chart's pod (containing the chart's default response payload). Without the `Host:` header, the same curl returns the Traefik 404.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-ingress-controllers-traefik-basic-*/result.yaml`) with `status: PASS`, curl-response(headers: `HTTP/1.1 200 OK`; body matches the chart's response signature), terminal-output of `kubectl -n sample get ingress` (or `kubectl -n sample get ingressroute`) shows the routing resource

### VAL-INGRESS-008: traefik-tls-passthrough scenario forwards encrypted traffic untouched
Running `ingress-controllers-traefik-tls-passthrough.yaml` via `run-scenario.sh` results in `status: PASS`. The IngressRoute (or IngressRouteTCP) has `tls.passthrough: true`. A `curl --insecure --resolve sample.test.local:443:<traefik-pod-ip> https://sample.test.local/` returns `HTTP/1.1 200` AND the certificate returned in the TLS handshake is the *backend's* certificate (matches what the pod serves), NOT Traefik's self-signed default.
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-traefik-tls-passthrough-*/result.yaml`) with `status: PASS`, terminal-output of `openssl s_client -connect <traefik-pod-ip>:443 -servername sample.test.local </dev/null 2>/dev/null | openssl x509 -noout -subject` matches the backend pod's cert subject

### VAL-INGRESS-009: traefik-middleware-chain scenario applies declared middleware
Running `ingress-controllers-traefik-middleware-chain.yaml` via `run-scenario.sh` results in `status: PASS`. The IngressRoute references at least one Middleware CR (e.g. `headers` or `stripPrefix`). A curl through the controller shows the *effect* of the middleware: e.g. with a `headers` middleware adding `X-Test: chart-test-swarm`, the response includes that header; with a `stripPrefix` middleware, the backend log shows the stripped path. Without the middleware reference, the same curl does not exhibit the effect.
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-traefik-middleware-chain-*/result.yaml`) with `status: PASS`, curl-response(headers includes the added header OR backend log shows stripped path), kubectl-output(`kubectl get middleware -n sample`) lists the declared middlewares

### VAL-INGRESS-010: traefik-ingressroute-crd scenario uses IngressRoute CRD, not classic Ingress (optional 4th variant)
If `ingress-controllers-traefik-ingressroute-crd.yaml` is present, running it via `run-scenario.sh` results in `status: PASS` and the routing resource created in the product namespace is `IngressRoute.traefik.io/v1alpha1` (verified via `kubectl get ingressroute`), not a classic `networking.k8s.io/v1` Ingress. HTTP traffic still reaches the backend via Host header. If absent, this assertion is N/A.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-ingress-controllers-traefik-ingressroute-crd-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get ingressroute.traefik.io -n sample -o name`) is non-empty, kubectl-output(`kubectl get ingress -n sample`) shows no classic Ingress

### Variant execution assertions (nginx-ingress)

### VAL-INGRESS-011: nginx-ingress-basic scenario routes through nginx controller
Running `ingress-controllers-nginx-ingress-basic.yaml` via `run-scenario.sh` results in `status: PASS`. The Ingress resource carries `ingressClassName: nginx`. An in-cluster `curl -H "Host: sample.test.local" http://<nginx-controller-pod-ip>/` returns `HTTP/1.1 200`. The nginx controller logs (`kubectl logs -n ingress-nginx`) show the request was matched to the product Service.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-ingress-controllers-nginx-ingress-basic-*/result.yaml`) with `status: PASS`, curl-response(headers: `HTTP/1.1 200`), kubectl-output(`kubectl get ingress -n sample -o jsonpath='{.items[0].spec.ingressClassName}'` == `nginx`)

### VAL-INGRESS-012: nginx-ingress-snippet-annotations scenario activates the configured snippet
Running `ingress-controllers-nginx-ingress-snippet-annotations.yaml` via `run-scenario.sh` results in `status: PASS`. The Ingress carries an annotation like `nginx.ingress.kubernetes.io/configuration-snippet` (or `server-snippet`); the cluster's nginx-ingress controller is started with `--enable-annotation-validation` configured to allow snippets, OR the controller chart's values enable `allowSnippetAnnotations: true`. A curl through the controller exhibits the snippet's effect — e.g. an injected `add_header X-Test true;` snippet causes the response to include `x-test: true`.
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-nginx-ingress-snippet-annotations-*/result.yaml`) with `status: PASS`, curl-response(headers includes `x-test: true`), kubectl-output(`kubectl get ingress -n sample -o jsonpath='{.items[0].metadata.annotations}'`) includes `nginx.ingress.kubernetes.io/.*-snippet`

### VAL-INGRESS-013: nginx-ingress-default-backend scenario serves a custom 404 for unmatched hosts
Running `ingress-controllers-nginx-ingress-default-backend.yaml` via `run-scenario.sh` results in `status: PASS`. The nginx controller is configured (via preinstall values OR an additional Deployment + Service named in `defaultBackend.service.name`) to use a custom default backend. An in-cluster `curl http://<nginx-controller-pod-ip>/` (with NO Host header matching any Ingress) returns the custom-backend's distinctive response body (NOT nginx's stock `default backend - 404`).
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-nginx-ingress-default-backend-*/result.yaml`) with `status: PASS`, curl-response(body contains the custom default backend's signature string, e.g. `chart-test-swarm-default-backend`), kubectl-output(`kubectl -n ingress-nginx get deploy <default-backend-name>`) returns a Deployment

### VAL-INGRESS-014: nginx-ingress-canary scenario splits traffic in measurable proportions
Running `ingress-controllers-nginx-ingress-canary.yaml` via `run-scenario.sh` results in `status: PASS`. Two Ingress resources exist for the same host; one carries `nginx.ingress.kubernetes.io/canary: "true"` plus `nginx.ingress.kubernetes.io/canary-weight: "20"` (or similar). A scripted set of 100 in-cluster curl probes against the controller routes between 10–30 of those requests to the canary backend and the remainder to the stable backend (validating the weight-driven split is *measurable*, not silently absent).
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-nginx-ingress-canary-*/result.yaml`) with `status: PASS`, terminal-output of a probe loop counting responses by backend label (e.g. response header `x-backend: canary` vs `x-backend: stable`) reports counts within the documented tolerance window (e.g. `canary=22 stable=78` for a 20% canary)

### Variant execution assertions (contour)

### VAL-INGRESS-015: contour-basic-httpproxy scenario routes via HTTPProxy CRD
Running `ingress-controllers-contour-basic-httpproxy.yaml` via `run-scenario.sh` results in `status: PASS`. The routing resource created is `HTTPProxy.projectcontour.io/v1`, NOT a classic Ingress. An in-cluster `curl -H "Host: sample.test.local" http://<envoy-pod-ip>/` (Contour uses Envoy as the data plane) returns `HTTP/1.1 200`. The HTTPProxy's `status.currentStatus` is `valid`.
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-contour-basic-httpproxy-*/result.yaml`) with `status: PASS`, curl-response(headers: `HTTP/1.1 200`), kubectl-output(`kubectl get httpproxy -n sample -o jsonpath='{.items[0].status.currentStatus}'` == `valid`)

### VAL-INGRESS-016: contour-tls-delegation scenario serves HTTPS using a Secret in a different namespace
Running `ingress-controllers-contour-tls-delegation.yaml` via `run-scenario.sh` results in `status: PASS`. A `TLSCertificateDelegation` resource exists granting the HTTPProxy access to a TLS Secret in a namespace OTHER than the HTTPProxy's namespace. An in-cluster `curl --insecure --resolve sample.test.local:443:<envoy-pod-ip> https://sample.test.local/` returns `HTTP/1.1 200` and serves the delegated Secret's certificate (Subject CN matches the host).
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-contour-tls-delegation-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get tlscertificatedelegation -A`) lists the delegation, terminal-output of `openssl s_client -connect <envoy-pod-ip>:443 -servername sample.test.local </dev/null | openssl x509 -noout -subject` includes the expected CN

### VAL-INGRESS-017: contour-rate-limit scenario enforces request-rate ceiling
Running `ingress-controllers-contour-rate-limit.yaml` via `run-scenario.sh` results in `status: PASS`. The HTTPProxy carries a `rateLimitPolicy.local` (or `global`) limiting requests-per-second. Sending more than the limit (e.g. 50 curl probes in < 1s) produces at least one `HTTP/1.1 429 Too Many Requests` response. Below the limit, all probes return `200`.
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-contour-rate-limit-*/result.yaml`) with `status: PASS`, curl-response(at least one response with `HTTP/1.1 429`), kubectl-output(`kubectl get httpproxy -n sample -o jsonpath='{.items[0].spec.virtualhost.rateLimitPolicy}'`) is non-empty

### VAL-INGRESS-018: contour-jwt-auth scenario rejects requests without a valid JWT (optional 4th variant)
If `ingress-controllers-contour-jwt-auth.yaml` is present, running it via `run-scenario.sh` results in `status: PASS`. An in-cluster curl WITHOUT an `Authorization: Bearer <jwt>` header returns `HTTP/1.1 401` (or `403`); a curl WITH a JWT signed by the configured JWKS issuer returns `HTTP/1.1 200`. If absent, this assertion is N/A.
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-contour-jwt-auth-*/result.yaml`) with `status: PASS`, curl-response(no-auth: `HTTP/1.1 401`; valid-jwt: `HTTP/1.1 200`)

### Area-wide structural assertions

### VAL-INGRESS-019: All ingress-controllers scenario YAMLs pass jsonschema validation
Every scenario file under `examples/sample-product-chart/chart-test/scenarios/ingress-controllers-*.yaml` validates cleanly against `engine/templates/scenario.schema.json`.
Tool: bash
Evidence: terminal-output of `for f in examples/sample-product-chart/chart-test/scenarios/ingress-controllers-*.yaml; do uv run --directory engine/testgrid python -m testgrid validate-scenario "$f" && echo OK $f || echo FAIL $f; done` shows `OK` for every file and exit code 0 overall

### VAL-INGRESS-020: helm lint passes for the sample-product-chart
`helm lint examples/sample-product-chart/chart` exits 0 with no `[ERROR]` lines. The chart is the only chart referenced by the ingress-controllers-area scenarios via `product.chart`.
Tool: helm-lint
Evidence: terminal-output of `helm lint examples/sample-product-chart/chart` shows `1 chart(s) linted, 0 chart(s) failed` and exit code 0

### VAL-INGRESS-021: Variant scenarios for the same controller differ ONLY in the feature they exercise
For each controller (traefik, nginx-ingress, contour), comparing any two variant scenario YAMLs side-by-side reveals shared `cluster.preinstall` for the controller chart itself and shared `product.chart` / `product.release` / `product.namespace`. The only meaningful diffs are in `product.set` overrides, ingress/HTTPProxy/IngressRoute annotations or spec fields, OR an added `raw_manifest` preinstall delivering a feature-specific CR (TLSCertificateDelegation, Middleware, ConfigMap with snippets, second Ingress for canary). No variant introduces a different ingress controller chart or changes the product namespace.
Tool: yq
Evidence: terminal-output of a yq + diff harness that, for each controller's variant pair, prints the structural diff between the two scenario YAMLs and the count of diff hunks outside `product.set` + `cluster.preinstall[-1]` (raw_manifest tail) + `mechanisms` is 0

### VAL-INGRESS-022: Ingress controller pod is Ready before the variant assertion runs its HTTP probe
For each ingress controller variant (traefik, nginx-ingress, contour) before any in-cluster `curl` HTTP probe is issued, the controller pod's `status.conditions[type=Ready].status` is `True` AND its container's `readinessProbe` has succeeded (verifiable: `kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=<controller> -n <controller-ns> --timeout=120s` exits 0). Probes that run against a not-yet-ready controller MUST be retried or wait, not flake. Pass requires every variant to satisfy the wait before its HTTP assertion.
Tool: kubectl
Evidence: kubectl-output(`kubectl wait --for=condition=ready` exits 0), terminal-output(test runner log shows the wait happened before the curl)
