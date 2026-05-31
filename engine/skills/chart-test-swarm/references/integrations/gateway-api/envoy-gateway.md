# Envoy Gateway

## What

Envoy Gateway is the official Kubernetes Gateway API implementation built on
the Envoy proxy. It runs a control plane (the `gateway-helm` deployment) that
watches Gateway API resources — GatewayClass, Gateway, HTTPRoute, GRPCRoute,
TLSRoute — and dynamically programs Envoy proxy instances as the data plane.
The controller is packaged as an OCI Helm chart at
`oci://docker.io/envoyproxy/gateway-helm` and manages the full lifecycle:
CRD installation, controller deployment, and Envoy proxy provisioning.

The GatewayClass name is `envoy` and its controllerName is
`gateway.envoyproxy.io/gatewayclass-controller`. Match these exactly when
creating Gateway resources — a Gateway referencing any other `gatewayClassName`
will not be reconciled by Envoy Gateway.

For chart-test-swarm, Envoy Gateway is the primary Gateway API implementation
for Milestone 5. Every scenario exercises the full Gateway API flow: CRD
install, controller deploy, GatewayClass acceptance, Gateway programming, and
route admission.

## When

Use Envoy Gateway scenarios when the Helm chart under test:

- Needs to be reachable through a Gateway API HTTPRoute (HTTP traffic routed
  through the Envoy data plane).
- Exposes a gRPC service and needs a GRPCRoute to handle protocol-aware
  routing (HTTP/2, gRPC reflection).
- Requires layer-7 policy enforcement via Envoy Gateway's SecurityPolicy CRD
  (CORS, JWT authentication, rate limiting).
- Terminates TLS on the Gateway listener using a cert-manager-issued
  certificate (compose scenario with M3 cert-manager).
- Needs to coexist with Gateway API CRDs and a running Gateway API controller.

**Do not use** Envoy Gateway if:

- The chart merely needs a classic Ingress controller — use traefik or
  nginx-ingress primers (Milestone 4).
- The routing logic is layer-4 only (TCPRoute/TLSRoute) — Envoy Gateway
  supports these but the sample-product chart does not yet exercise them.
- You are testing a different Gateway API implementation (istio-gateway-api
  or contour-gateway-api) — each has its own primer.

## How

### Consumer chart wiring

The sample product chart exposes a `gatewayRoute` value block. Set these
values to enable the chart's HTTPRoute template:

```yaml
gatewayRoute:
  enabled: true
  parentRef:
    name: sample-gw
    sectionName: http
```

When `gatewayRoute.enabled` is `true`, the chart creates an HTTPRoute resource
referencing the named Gateway parent. The chart does **not** create GatewayClass
or Gateway resources itself — those are cluster-level objects managed by the
scenario's smoke-script assertion.

### Scenario pattern

Every Envoy Gateway scenario follows this pattern:

1. **Preinstall Gateway API CRDs** (raw_manifest) — applies the upstream
   `standard-install.yaml` from `kubernetes-sigs/gateway-api` to register
   GatewayClass, Gateway, HTTPRoute, GRPCRoute, and related CRDs.

2. **Preinstall Envoy Gateway controller** (helm) — installs the OCI chart
   `oci://docker.io/envoyproxy/gateway-helm` into `envoy-gateway-system`
   namespace. The chart bundles its own CRDs, but the explicit CRD preinstall
   ensures Gateway API CRDs are registered before the controller starts.

3. **Install the product chart** with `gatewayRoute.enabled: true`.

4. **Run a smoke-script** that:
   - Creates a GatewayClass named `envoy` with `controllerName:
     gateway.envoyproxy.io/gatewayclass-controller`.
   - Creates a Gateway in the product namespace.
   - Creates the route resource (HTTPRoute, GRPCRoute, etc.).
   - Waits for GatewayClass `Accepted=True`, Gateway `Programmed=True`,
     and route `Accepted=True`.
   - Probes the backend through the gateway's address or Envoy proxy pod IP.
   - Exits 0 (PASS) or non-zero (FAIL) with a diagnostic message.

## Cluster preinstall

### Gateway API CRDs (raw_manifest)

```yaml
kind: raw_manifest
path: chart-test/fixtures/gateway-api/gateway-api-crds.yaml
```

The manifest at this path must contain all standard Gateway API CRDs from
`kubernetes-sigs/gateway-api`. Reference the upstream release YAML, trimmed
to the CRD definitions only (namespace-scoped and cluster-scoped). The
`raw_manifest` preinstall applies these via `kubectl apply --server-side
--force-conflicts` (per `apply-scenario.sh` conventions).

### Envoy Gateway OCI helm chart

```yaml
kind: helm
chart: oci://docker.io/envoyproxy/gateway-helm
version: v1.1.2
release: envoy-gateway
namespace: envoy-gateway-system
values:
  config:
    envoyGateway:
      provider:
        type: Kubernetes
wait: pods-ready
wait_timeout: 5m
```

**Important:** The OCI chart path is `oci://docker.io/envoyproxy/gateway-helm`.
The older classic-repo Helm chart URL on `gateway.envoyproxy.io` is **defunct**
and must not appear in any scenario or primer. No `repo` block is needed for OCI
charts — Helm resolves them directly.

After this preinstall completes, the `gateway-helm` deployment pods must be
Ready in the `envoy-gateway-system` namespace. The controller will then begin
watching for GatewayClass resources.

### Cert-manager (cross-feature compose only)

```yaml
kind: helm
chart: jetstack/cert-manager
version: v1.14.0
release: cert-manager
namespace: cert-manager
repo:
  name: jetstack
  url: "https://charts.jetstack.io"
values:
  installCRDs: true
wait: pods-ready
wait_timeout: 3m
```

```yaml
kind: raw_manifest
path: chart-test/fixtures/certificates/selfsigned-clusterissuer.yaml
```

The cross-feature scenario (`gateway-api-envoy-gateway-cert-manager-tls`)
installs cert-manager alongside Envoy Gateway and uses a cert-manager
Certificate to provision a TLS Secret. The Gateway listener's
`tls.certificateRefs` points at this Secret.

## Variants

Four scenario variants are available under
`examples/sample-product-chart/chart-test/scenarios/`:

| Variant | File | Key behavior |
|---|---|---|
| httproute | `gateway-api-envoy-gateway-httproute.yaml` | GatewayClass `envoy` Accepted=True; Gateway Programmed=True; HTTPRoute Accepted=True; HTTP curl returns 200 |
| grpcroute | `gateway-api-envoy-gateway-grpcroute.yaml` | GRPCRoute Accepted=True; in-cluster grpcurl reflection probe lists ≥ 1 service |
| security-policy-attach | `gateway-api-envoy-gateway-security-policy-attach.yaml` | SecurityPolicy targetRef binds HTTPRoute/Gateway with Accepted=True; CORS header on preflight |
| cert-manager-tls | `gateway-api-envoy-gateway-cert-manager-tls.yaml` | Gateway listener tls.certificateRefs points to cert-manager Secret; HTTPS curl returns 200 with expected cert |

The httproute variant is the baseline (fastest to run). The cert-manager-tls
variant is the cross-feature compose scenario spanning M5 (gateway-api) and
M3 (certificates).

## Assertions

Every Envoy Gateway scenario uses three assertion types:

| Type | Purpose |
|---|---|
| `helm-status-deployed` | Confirm both the envoy-gateway helm release and the product chart release are deployed |
| `pods-ready` | Confirm all pods in product, envoy-gateway-system, and (when applicable) cert-manager namespaces are Ready |
| `smoke-script` | Create Gateway API resources, wait for admission/programming, probe the backend |

The smoke-script assertions live under
`examples/sample-product-chart/chart-test/assertions/` and are referenced by
`path` from the scenario. Each script receives `RELEASE`, `NAMESPACE`,
`KUBECONFIG`, `KUBE_CONTEXT`, and `PROJECT_DIR` via the environment.

## Known gotchas

- **GatewayClass must be named `envoy`** — The envoy-gateway controller only
  reconciles GatewayClasses whose `spec.controllerName` equals
  `gateway.envoyproxy.io/gatewayclass-controller`. The GatewayClass `metadata.name`
  should be `envoy` by convention.

- **Envoy Gateway takes up to 3m to provision the data plane** — After creating
  a Gateway, the controller provisions an Envoy Proxy deployment and service.
  Use `kubectl wait gateway/<name> --for=condition=Programmed --timeout=5m`.

- **Gateway address on kind** — Envoy Gateway creates a LoadBalancer Service
  for the Envoy proxy. On kind clusters without MetalLB, the Service external IP
  stays in `<pending>`. Use the Envoy proxy pod IP or Service ClusterIP directly
  instead.

- **GRPCRoute requires a gRPC backend** — The chart's standard nginx pod does
  not speak gRPC. The grpcroute variant deploys a separate gRPC reflection
  server via a `raw_manifest` fixture and creates a GRPCRoute pointing at it.

- **SecurityPolicy is an Envoy Gateway CRD** — The `SecurityPolicy` resource is
  in `gateway.envoyproxy.io/v1alpha1`. It is installed by the envoy-gateway
  Helm chart (not by the Gateway API standard CRDs).

- **Old Helm chart URL is defunct** — The classic Helm chart repo on
  `gateway.envoyproxy.io` is no longer maintained. The only valid source is the
  OCI registry: `oci://docker.io/envoyproxy/gateway-helm`.

- **CRD ownership conflicts** — Both the Gateway API standard-install.yaml and
  the envoy-gateway Helm chart may define overlapping CRDs. The
  `apply-scenario.sh` script uses `--server-side --force-conflicts` to safely
  reconcile them.

- **Scope component for gRPC** — The chart's `scope` component (enabled via
  `scope.enabled: true`) can serve as a second backend for multi-route tests,
  but it is an nginx container (not gRPC). Deploy a dedicated gRPC service for
  GRPCRoute tests.

- **Envoy proxy port mapping** — The envoy data-plane container listens on port
  10080 (not 80). The LoadBalancer Service created by envoy-gateway maps Service
  port 80 → container port 10080. Always probe via the Service ClusterIP (found
  in `envoy-gateway-system` namespace with label
  `gateway.envoyproxy.io/owning-gateway-name=<gw-name>`), not via pod IP.

- **SecurityPolicy status nesting** — SecurityPolicy Accepted conditions are
  nested under `status.ancestors[0].conditions`, not at top-level
  `status.conditions`. Use jsonpath
  `{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}`.

- **Staged apply for SecurityPolicy** — Apply GatewayClass + Gateway first and
  wait for listener `Programmed=True`, then apply HTTPRoute + SecurityPolicy.
  Applying all four resources in a single `kubectl apply` may cause the envoy
  controller to skip listener status population (status updater bypass).

- **Retry probes (data-plane warm-up)** — After the Gateway listener reports
  `Programmed=True` and the HTTPRoute/GRPCRoute reports `Accepted=True`, the
  envoy data-plane may need up to 30s before it actually accepts traffic. Use
  a retry loop (e.g., 20 attempts × 6s = 2m) when probing via curl/grpcurl.

- **gRPC backend image** — Use `docker.io/moul/grpcbin:latest` which provides
  gRPC reflection on port 9000. The GCR image
  (`gcr.io/k8s-staging-gateway-api/echo-basic`) used in upstream documentation
  may not be pullable from all environments.

## References

- [Envoy Gateway documentation](https://gateway.envoyproxy.io/)
- [Envoy Gateway OCI Helm chart](https://github.com/envoyproxy/gateway/pkgs/container/gateway-helm)
- [Gateway API specification](https://gateway-api.sigs.k8s.io/)
- [Gateway API CRDs (upstream)](https://github.com/kubernetes-sigs/gateway-api/releases)
- [GRPCRoute documentation](https://gateway-api.sigs.k8s.io/guides/grpc-routing/)
- [SecurityPolicy reference](https://gateway.envoyproxy.io/docs/tasks/security/)
