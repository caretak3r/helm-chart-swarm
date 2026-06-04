## Area: Gateway API

Coverage: F5.1 envoy-gateway primer + variants, F5.2 istio-gateway-api primer + variants,
F5.3 contour-gateway-api primer + variants.

All cluster operations referenced below run on a cluster whose name matches
`^chart-test-swarm-[a-z0-9-]+$`. Scenario YAMLs live under
`examples/sample-product-chart/chart-test/scenarios/` and are validated against
`engine/templates/scenario.schema.json`. Each implementation's CRDs from
`kubernetes-sigs/gateway-api` (`gateway.networking.k8s.io/v1`) are installed via a
`raw_manifest` preinstall item (per F1.2) before the implementation's controller
chart is installed (per F1.2's envoy-gateway OCI URL fix:
`oci://docker.io/envoyproxy/gateway-helm`). HTTP probes target the gateway address
or the controller pod IP directly (kind has no LoadBalancer).

### Structural / artifact assertions (per integration)

### VAL-GW-001: envoy-gateway primer exists, uses OCI chart ref, and documents GatewayClass name
The primer at `engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md` exists, is non-empty, references the OCI chart `oci://docker.io/envoyproxy/gateway-helm` (F1.2 fix — the older `https://gateway.envoyproxy.io/helm-chart` URL is defunct), and notes the expected GatewayClass name (`envoy`) plus its `controllerName` (`gateway.envoyproxy.io/gatewayclass-controller`). It documents what + when + how.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md`), terminal-output of `grep -F 'oci://docker.io/envoyproxy/gateway-helm' engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md` returns ≥ 1 match, terminal-output of `grep -F 'gateway.envoyproxy.io/gatewayclass-controller' engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md` returns ≥ 1 match, terminal-output of `! grep -F 'gateway.envoyproxy.io/helm-chart' engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md` (i.e. the old URL is NOT present)

### VAL-GW-002: envoy-gateway scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/gateway-api-envoy-gateway-*.yaml`, covering httproute, grpcroute, and security-policy-attach variants. Each file's `cluster.preinstall` list includes a `raw_manifest` item delivering the Gateway API CRDs AND a helm item for the envoy-gateway OCI chart.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/gateway-api-envoy-gateway-*.yaml | wc -l` ≥ 3, terminal-output of `for f in examples/sample-product-chart/chart-test/scenarios/gateway-api-envoy-gateway-*.yaml; do yq '.cluster.preinstall[] | select(.kind == "raw_manifest")' "$f"; done` returns ≥ 1 raw_manifest item per scenario

### VAL-GW-003: istio-gateway-api primer exists and documents GatewayClass name
The primer at `engine/skills/chart-test-swarm/references/integrations/gateway-api/istio-gateway-api.md` exists, is non-empty, references the `istio/base` + `istio/istiod` Helm charts in the preinstall section, and notes the expected GatewayClass name (`istio`) along with its `controllerName` (`istio.io/gateway-controller`). It explains how Istio's Gateway-API mode differs from its classic ingress-gateway mode.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/gateway-api/istio-gateway-api.md`), terminal-output of `grep -E 'gatewayClassName:\s+istio' engine/skills/chart-test-swarm/references/integrations/gateway-api/istio-gateway-api.md` returns ≥ 1 match, terminal-output of `grep -F 'istio.io/gateway-controller' engine/skills/chart-test-swarm/references/integrations/gateway-api/istio-gateway-api.md` returns ≥ 1 match

### VAL-GW-004: istio-gateway-api scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/gateway-api-istio-gateway-api-*.yaml`, covering basic-gateway, multi-listener, and backend-tls-policy variants. Each scenario's `cluster.preinstall` installs `istio/base` + `istio/istiod` and includes a `raw_manifest` item for Gateway API CRDs.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/gateway-api-istio-gateway-api-*.yaml | wc -l` ≥ 3

### VAL-GW-005: contour-gateway-api primer exists and documents GatewayClass name
The primer at `engine/skills/chart-test-swarm/references/integrations/gateway-api/contour-gateway-api.md` exists, is non-empty, references the Contour Helm chart with Gateway-API provisioner enabled, and notes the expected GatewayClass name (`contour`) along with its `controllerName` (`projectcontour.io/gateway-controller`). It explains how Contour's Gateway-API mode differs from its HTTPProxy mode (covered by VAL-INGRESS-005).
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/gateway-api/contour-gateway-api.md`), terminal-output of `grep -E 'gatewayClassName:\s+contour' engine/skills/chart-test-swarm/references/integrations/gateway-api/contour-gateway-api.md` returns ≥ 1 match, terminal-output of `grep -F 'projectcontour.io/gateway-controller' engine/skills/chart-test-swarm/references/integrations/gateway-api/contour-gateway-api.md` returns ≥ 1 match

### VAL-GW-006: contour-gateway-api scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/gateway-api-contour-gateway-api-*.yaml`, covering basic, response-header-modifier, and route-precedence variants.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/gateway-api-contour-gateway-api-*.yaml | wc -l` ≥ 3

### Variant execution assertions (envoy-gateway)

### VAL-GW-007: envoy-gateway-httproute scenario admits Gateway and routes HTTP
Running `bash engine/scripts/run-scenario.sh examples/sample-product-chart/chart-test/scenarios/gateway-api-envoy-gateway-httproute.yaml` against a `chart-test-swarm-<test-id>` kind cluster results in `status: PASS`. The cluster shows: GatewayClass `envoy` with `Accepted: True`; a Gateway with `Programmed: True`; an HTTPRoute with `parents[0].conditions[type=Accepted].status == True`; HTTP curl to the gateway address returns `HTTP/1.1 200` from the product backend.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-gateway-api-envoy-gateway-httproute-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get gatewayclass envoy -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'` == `True`), kubectl-output(`kubectl get gateway -n sample -o jsonpath='{.items[0].status.conditions[?(@.type=="Programmed")].status}'` == `True`), curl-response(headers: `HTTP/1.1 200`)

### VAL-GW-008: envoy-gateway-grpcroute scenario admits GRPCRoute and a gRPC reflection probe succeeds
Running `gateway-api-envoy-gateway-grpcroute.yaml` via `run-scenario.sh` results in `status: PASS`. A `GRPCRoute` resource is admitted (`status.parents[0].conditions[type=Accepted].status == True`). An in-cluster `grpcurl -plaintext <gateway-address>:80 list` (or any gRPC reflection probe against the product chart's gRPC backend) returns at least one service entry without TLS error.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-gateway-api-envoy-gateway-grpcroute-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get grpcroute -n sample -o jsonpath='{.items[0].status.parents[0].conditions[?(@.type=="Accepted")].status}'` == `True`), terminal-output of `kubectl exec -n sample <probe-pod> -- grpcurl -plaintext <gw>:80 list` returns ≥ 1 service line

### VAL-GW-009: envoy-gateway-security-policy-attach scenario enforces the attached SecurityPolicy
Running `gateway-api-envoy-gateway-security-policy-attach.yaml` via `run-scenario.sh` results in `status: PASS`. A `SecurityPolicy` (Envoy Gateway CRD `gateway.envoyproxy.io/v1alpha1`) is created with a `targetRef` pointing at the HTTPRoute (or Gateway). The policy's effect is observable: e.g. a CORS policy returns the configured `access-control-allow-origin` header on a preflight `OPTIONS` request; a JWT policy rejects unauthenticated requests with `HTTP/1.1 401`. Without the policy, the same probe behaves differently.
Tool: curl
Evidence: file(`reports/run-*/scenario-gateway-api-envoy-gateway-security-policy-attach-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get securitypolicy.gateway.envoyproxy.io -n sample -o jsonpath='{.items[0].status.conditions[?(@.type=="Accepted")].status}'` == `True`), curl-response(headers contain the policy's expected effect — e.g. `access-control-allow-origin: *` OR `HTTP/1.1 401` for unauthenticated request)

### Variant execution assertions (istio-gateway-api)

### VAL-GW-010: istio-gateway-api-basic scenario admits Istio-managed Gateway and routes HTTP
Running `gateway-api-istio-gateway-api-basic.yaml` via `run-scenario.sh` results in `status: PASS`. GatewayClass `istio` is `Accepted: True`; the Gateway resource gets `Programmed: True` (Istio auto-provisions the data-plane Deployment + Service in the Gateway's namespace); HTTPRoute is `Accepted: True`; in-cluster curl with the appropriate `Host:` header returns `HTTP/1.1 200`.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-gateway-api-istio-gateway-api-basic-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'` == `True`), kubectl-output(`kubectl get deploy -n sample -l gateway.networking.k8s.io/gateway-name`) returns ≥ 1 auto-provisioned Deployment, curl-response(headers: `HTTP/1.1 200`)

### VAL-GW-011: istio-gateway-api-multi-listener scenario serves HTTP and HTTPS on the same Gateway
Running `gateway-api-istio-gateway-api-multi-listener.yaml` via `run-scenario.sh` results in `status: PASS`. The Gateway declares ≥ 2 listeners (e.g. `name: http port: 80 protocol: HTTP` and `name: https port: 443 protocol: HTTPS`); both listeners report `conditions[type=Programmed].status == True` per `status.listeners[]`. An HTTP curl to port 80 returns `200`; an HTTPS curl to port 443 (with `--insecure` or the issuer CA) also returns `200`.
Tool: curl
Evidence: file(`reports/run-*/scenario-gateway-api-istio-gateway-api-multi-listener-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get gateway -n sample -o jsonpath='{.items[0].status.listeners[*].name}'`) lists ≥ 2 listener names, curl-response on port 80: `HTTP/1.1 200`, curl-response on port 443: `HTTP/1.1 200`

### VAL-GW-012: istio-gateway-api-backend-tls-policy scenario terminates TLS to the backend per BackendTLSPolicy
Running `gateway-api-istio-gateway-api-backend-tls-policy.yaml` via `run-scenario.sh` results in `status: PASS`. A `BackendTLSPolicy` (Gateway API `v1alpha3`) targeting the product Service is `Accepted: True`. The HTTPRoute's path-prefix probe goes through the gateway and the gateway initiates a TLS handshake to the upstream backend Service (verifiable via Istio access logs, OR by configuring the backend to require TLS and observing the request succeed only when the policy is in place).
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-gateway-api-istio-gateway-api-backend-tls-policy-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get backendtlspolicy.gateway.networking.k8s.io -n sample -o jsonpath='{.items[0].status.ancestors[0].conditions[?(@.type=="Accepted")].status}'` == `True`), curl-response(headers: `HTTP/1.1 200` through the gateway; backend access log shows TLS handshake)

### Variant execution assertions (contour-gateway-api)

### VAL-GW-013: contour-gateway-api-basic scenario admits Contour-managed Gateway and routes HTTP
Running `gateway-api-contour-gateway-api-basic.yaml` via `run-scenario.sh` results in `status: PASS`. GatewayClass `contour` is `Accepted: True`; the Gateway is `Programmed: True`; the HTTPRoute is `Accepted: True`; in-cluster curl returns `HTTP/1.1 200`. The data plane Envoy pod is managed by Contour's `Gateway`-mode provisioner.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-gateway-api-contour-gateway-api-basic-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get gatewayclass contour -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'` == `True`), curl-response(headers: `HTTP/1.1 200`)

### VAL-GW-014: contour-gateway-api-response-header-modifier scenario applies the declared header filter
Running `gateway-api-contour-gateway-api-response-header-modifier.yaml` via `run-scenario.sh` results in `status: PASS`. The HTTPRoute's `rules[0].filters[]` includes a `type: ResponseHeaderModifier` entry adding a header (e.g. `X-Powered-By: chart-test-swarm`). A curl through the gateway returns the response with that header set. Without the filter, the same response does not include the header.
Tool: curl
Evidence: file(`reports/run-*/scenario-gateway-api-contour-gateway-api-response-header-modifier-*/result.yaml`) with `status: PASS`, curl-response(headers include `x-powered-by: chart-test-swarm` exactly as configured in the filter)

### VAL-GW-015: contour-gateway-api-route-precedence scenario resolves overlapping routes per the spec's precedence rules
Running `gateway-api-contour-gateway-api-route-precedence.yaml` via `run-scenario.sh` results in `status: PASS`. Two HTTPRoutes exist for the same host with overlapping path prefixes (e.g. `/api` and `/api/v2`); the more specific route (`/api/v2`) wins for matching requests and the less specific (`/api`) wins for non-overlapping paths. The probe verifies BOTH paths route to distinct backends (e.g. via a response header identifying which route handled the request).
Tool: curl
Evidence: file(`reports/run-*/scenario-gateway-api-contour-gateway-api-route-precedence-*/result.yaml`) with `status: PASS`, curl-response on `/api/v2/foo`: header `x-route: v2`; curl-response on `/api/foo`: header `x-route: v1`

### Area-wide structural assertions

### VAL-GW-016: All gateway-api scenario YAMLs install Gateway API CRDs via raw_manifest preinstall
Every scenario file under `examples/sample-product-chart/chart-test/scenarios/gateway-api-*.yaml` includes at least one `cluster.preinstall[]` item with `kind: raw_manifest` whose `path` resolves to a manifest that includes `gateway.networking.k8s.io` CRDs (or a documented URL to the upstream `standard-install.yaml`). No scenario relies on CRDs being pre-installed out-of-band.
Tool: yq
Evidence: terminal-output of `for f in examples/sample-product-chart/chart-test/scenarios/gateway-api-*.yaml; do count=$(yq '[.cluster.preinstall[] | select(.kind == "raw_manifest")] | length' "$f"); echo "$f: $count"; done` reports `count >= 1` for every file

### VAL-GW-017: Scenarios use the correct GatewayClass name for their implementation
For each scenario, the GatewayClass referenced in the embedded Gateway manifest (or in a documented post-install step) matches the implementation's primer-declared name: `envoy` for envoy-gateway scenarios, `istio` for istio-gateway-api scenarios, `contour` for contour-gateway-api scenarios. No scenario uses a mismatched GatewayClass (e.g. an `envoy-gateway-*` scenario must NOT reference `gatewayClassName: contour`).
Tool: yq
Evidence: terminal-output of a grep harness that, for each scenario family, extracts the `gatewayClassName` value(s) from the inline manifest (in `raw_manifest` content or fixture file) and confirms it matches the implementation prefix — e.g. for `gateway-api-envoy-gateway-*.yaml`, `grep -rh 'gatewayClassName:' <referenced fixtures>` only ever returns `envoy`

### VAL-GW-018: All gateway-api scenario YAMLs pass jsonschema validation
Every scenario file under `examples/sample-product-chart/chart-test/scenarios/gateway-api-*.yaml` validates cleanly against `engine/templates/scenario.schema.json`. (The schema's relaxed `preinstall_item` per F1.2 must accept `kind: raw_manifest` items.)
Tool: bash
Evidence: terminal-output of `for f in examples/sample-product-chart/chart-test/scenarios/gateway-api-*.yaml; do uv run --directory engine/testgrid python -m testgrid validate-scenario "$f" && echo OK $f || echo FAIL $f; done` shows `OK` for every file and exit code 0 overall

### VAL-GW-019: helm lint passes for the sample-product-chart
`helm lint examples/sample-product-chart/chart` exits 0 with no `[ERROR]` lines. The chart is the only chart referenced by the gateway-api-area scenarios via `product.chart`.
Tool: helm-lint
Evidence: terminal-output of `helm lint examples/sample-product-chart/chart` shows `1 chart(s) linted, 0 chart(s) failed` and exit code 0

### VAL-GW-020: Gateway API CRD version is captured in the artifacts/ bundle
For every gateway-api scenario run that PASSes, the produced `reports/run-*/scenario-*/artifacts/manifests/` directory contains at least one file whose content shows `apiVersion: gateway.networking.k8s.io/v1` (or `v1beta1` if the scenario declares it) AND `artifacts/versions.json` includes a new key `gateway_api_crds` reflecting the installed CRD version (e.g., `v1.0.0`, `v1.1.0`). Pass requires both the manifest evidence and the version stamp.
Tool: bash
Evidence: file(reports/run-*/scenario-*/artifacts/manifests/*.yaml), command-output(`yq '.apiVersion'`), command-output(`jq '.gateway_api_crds' artifacts/versions.json`)
