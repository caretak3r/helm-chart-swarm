# gcp-lb

**AUTHORED ONLY — not run from this repo.** The scenarios referenced here are
authored and validated via `kubectl --dry-run=client` and `yamllint` against a
local kind cluster. No `kubectl apply`, `helm install`, or `gcloud` invocation
targets a real GKE cluster from this repository. Apply them yourself to your
own GKE cluster.

## What

Google Cloud Load Balancer integration for GKE provisions Google Cloud load
balancers from Kubernetes Service, Ingress, and Gateway API resources. GKE
uses the GKE Ingress controller and the GKE Gateway Controller to create and
manage Google Cloud external and internal HTTP(S) load balancers, Network
Load Balancers, and TCP/UDP load balancers.

Key capabilities:

- **External HTTP(S) Load Balancer** — GKE's default Ingress controller
  creates a Google Cloud external HTTP(S) load balancer from a
  `networking.k8s.io/v1 Ingress` resource. Supports host/path routing,
  TLS termination via Google-managed certificates, and Cloud CDN integration.
- **Internal HTTP(S) Load Balancer** — created when the Ingress annotation
  `cloud.google.com/load-balancer-type: "Internal"` is set. Enables
  private, VPC-internal HTTP(S) load balancing for internal applications.
- **GKE Gateway Controller** — a managed Gateway API implementation that
  provisions Google Cloud load balancers from `Gateway` and `HTTPRoute`
  resources. Supports multiple GatewayClasses (global external, regional
  external, global external managed, regional internal).

These capabilities are GKE-specific. They cannot be exercised on kind or
minikube because they depend on GCP infrastructure (VPC, Cloud Load
Balancing, Cloud CDN, IAM). The scenarios authored for this integration are
**design-only** — they serve as reference implementations that a user ships
to their own GKE cluster.

## Target Kubernetes version

GKE 1.28+ (GKE Ingress controller available on all GKE versions; Gateway API
GA in GKE 1.29+; internal HTTP(S) LB via Ingress requires GKE 1.22+).

All scenario YAMLs authored under `networking/ingress-lb/` carry an annotation
`chart-test-swarm/target-k8s-version: gke-1.30` to pin the expected Kubernetes
API version.

## When

Use GCP Load Balancer scenarios when the Helm chart under test:

- Must be exposed through a Google Cloud external HTTP(S) load balancer with
  host-based routing, path-based routing, TLS termination via Google-managed
  or self-managed certificates, or Cloud CDN integration.
- Requires an internal HTTP(S) load balancer for VPC-internal application
  communication without exposing endpoints to the internet.
- Uses the Kubernetes Gateway API and expects GCP-native load balancer
  provisioning from `Gateway` and `HTTPRoute` resources.
- Must prove that Ingress annotations (`cloud.google.com/*`,
  `networking.gke.io/*`) are correctly templated.

**Do not use** GCP LB scenarios if:

- You need to test TLS certificate lifecycle — use the `cert-manager` *local*
  scenarios instead. GCP LB scenarios assume certificates are provisioned via
  Google-managed certificates or Certificate Manager.
- You are testing a service mesh (Istio, Linkerd) — use the `service-mesh/`
  local scenarios. Mesh scenarios on GKE interact with GCP LBs in complex
  ways beyond the current scope.
- You are testing policy enforcement (Gatekeeper, Kyverno) — use the
  `policy/` local scenarios.

## How

This repo does **not** run GCP LB scenarios. They are authored as reference
implementations that you take to your own GKE cluster.

### Application pattern

Every GCP LB scenario follows this two-phase pattern:

**Phase 1 (validation in this repo):**

1. Write the scenario YAML with `cluster.provider: gke`.
2. Validate against `engine/templates/scenario.schema.json`.
3. Run `kubectl --dry-run=client -f` against every embedded manifest snippet.
4. Run `yamllint` on the primer and all scenario YAMLs.

**Phase 2 (you, on your own GKE cluster):**

1. Authenticate to GCP: `gcloud auth login` and
   `gcloud container clusters get-credentials <cluster> --region <region>`.
2. Ensure the GKE cluster has HTTP(S) Load Balancing enabled.
3. Apply the scenario's preinstall items and product chart.
4. Review the emitted `reports/run-*/result.yaml` and artifact bundle.

### Consumer chart wiring

The sample product chart exposes value blocks for GCP LB integration.
Set these values for LB scenarios:

```yaml
ingress:
  enabled: true
  className: "gce"
  annotations:
    kubernetes.io/ingress.class: "gce"
    kubernetes.io/ingress.global-static-ip-name: "<REPLACE_WITH_STATIC_IP_NAME>"
    networking.gke.io/managed-certificates: "<REPLACE_WITH_CERT_NAME>"
  hosts:
    - host: "<REPLACE_WITH_DOMAIN_NAME>"
      paths:
        - path: /
          pathType: Prefix
```

All values containing sensitive material carry `<REPLACE_WITH_...>` placeholders.
No real project IDs, certificate names, or static IP names are stored in this
repository.

## Credential prerequisites

Before applying any GCP LB scenario to your cluster, you must have the
following GCP credentials and IAM bindings in place.

### gcloud authentication

```bash
# Authenticate as a user with GKE admin + Network Admin permissions
gcloud auth login

# Set the project
gcloud config set project <YOUR_GCP_PROJECT_ID>

# Verify access
gcloud container clusters list
```

### GKE cluster credentials

```bash
# Get kubeconfig for the GKE cluster
gcloud container clusters get-credentials <CLUSTER_NAME> \
  --region <REGION>

# Verify connection
kubectl get nodes
```

### IAM roles for Load Balancer management

The GKE service account (or the user/service account used by the Ingress
controller) needs the following roles:

- **Compute Network Admin** (`roles/compute.networkAdmin`) — for creating
  forwarding rules, backend services, and health checks.
- **Compute Security Admin** (`roles/compute.securityAdmin`) — for creating
  firewall rules needed by the load balancer.
- **Compute Load Balancer Admin** (`roles/compute.loadBalancerAdmin`) — for
  creating and managing load balancer resources.

The GKE node service account is typically
`<PROJECT_NUMBER>-compute@developer.gserviceaccount.com` and has the
`roles/editor` role by default, which includes these permissions. If using
a custom service account, grant the roles explicitly:

```bash
# Grant required roles to the GKE node service account
gcloud projects add-iam-policy-binding <YOUR_GCP_PROJECT_ID> \
  --member "serviceAccount:<PROJECT_NUMBER>-compute@developer.gserviceaccount.com" \
  --role "roles/compute.loadBalancerAdmin"

gcloud projects add-iam-policy-binding <YOUR_GCP_PROJECT_ID> \
  --member "serviceAccount:<PROJECT_NUMBER>-compute@developer.gserviceaccount.com" \
  --role "roles/compute.networkAdmin"
```

### Google-managed certificate

For external HTTP(S) LB scenarios with TLS, create a Google-managed
certificate:

```bash
# Create a ManagedCertificate resource
cat <<EOF | kubectl apply -f -
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: <REPLACE_WITH_CERT_NAME>
spec:
  domains:
    - <REPLACE_WITH_DOMAIN_NAME>
EOF

# Verify certificate provisioning (may take 10-15 minutes)
kubectl get managedcertificate <REPLACE_WITH_CERT_NAME>
```

### Static IP address (optional)

Reserve a static IP for the Ingress to use:

```bash
# Reserve a global static IP
gcloud compute addresses create <REPLACE_WITH_STATIC_IP_NAME> \
  --global

# Note the IP address
gcloud compute addresses describe <REPLACE_WITH_STATIC_IP_NAME> \
  --global --format "value(address)"
```

## Cluster prerequisites

Every GCP LB scenario expects the following cluster configuration.

### GKE version

**Minimum: GKE 1.28** (external HTTP(S) LB available on all versions;
Gateway API GA in 1.29+; internal HTTP(S) LB via Ingress requires 1.22+).

```bash
# Create a new GKE cluster matching scenario expectations
gcloud container clusters create chart-test-swarm-gke \
  --region us-central1 \
  --cluster-version "1.30" \
  --release-channel regular \
  --num-nodes 3 \
  --machine-type e2-standard-4 \
  --addons=HttpLoadBalancing
```

### Required add-ons

| Add-on | Required for | Enabled by default? |
|---|---|---|
| HTTP(S) Load Balancing | All external LB scenarios | Yes |
| GKE Gateway Controller | Gateway API scenarios | Yes, on 1.27+ Standard clusters |
| Network Policy | Internal LB scenarios (optional) | No — enable with `--enable-network-policy` |
| VPC-native (alias IP) networking | All LB scenarios | Yes, default on 1.27+ |

### VPC-native networking

All GCP LB scenarios assume **VPC-native (alias IP) networking**. This is the
default for GKE 1.27+ clusters and is required for:

- Internal HTTP(S) load balancers (requires alias IP ranges for Pod networking)
- GKE Gateway Controller (uses Pod endpoints by IP for backend services)
- Container-native load balancing (sends traffic directly to Pods instead
  of node IPs)

Verify your cluster uses VPC-native mode:

```bash
gcloud container clusters describe <CLUSTER_NAME> --region <REGION> \
  --format "value(ipAllocationPolicy.useIpAliases)"
# Must return: True
```

### Enable Gateway API (for gateway-api variant)

```bash
# Enable Gateway API on the GKE cluster
gcloud container clusters update <CLUSTER_NAME> \
  --region <REGION> \
  --gateway-api=standard

# Verify GatewayClasses are available
kubectl get gatewayclasses.gateway.networking.k8s.io
# Should list: gke-l7-global-external-managed, gke-l7-regional-external-managed, etc.
```

## Variants

Three scenario variants are authored under
`examples/sample-product-chart/chart-test/scenarios/`. All use
`cluster.provider: gke`, carry `category: networking`, `integration: gcp-lb`,
and the `AUTHORED ONLY` banner.

| Variant | File | What it exercises |
|---|---|---|
| external-lb | `networking-gcp-lb-external.yaml` | Ingress → external HTTP(S) LB; Google-managed cert; Cloud CDN |
| internal-lb | `networking-gcp-lb-internal.yaml` | Ingress with internal annotation → internal HTTP(S) LB |
| gateway-api | `networking-gcp-lb-gateway-api.yaml` | Gateway + HTTPRoute → managed LB via Gateway API |

### external-lb

This variant verifies that GKE provisions an external HTTP(S) load balancer
from a Kubernetes Ingress resource with a Google-managed certificate.

**Product chart values:**

```yaml
ingress:
  enabled: true
  className: "gce"
  annotations:
    networking.gke.io/managed-certificates: "<REPLACE_WITH_CERT_NAME>"
    kubernetes.io/ingress.global-static-ip-name: "<REPLACE_WITH_STATIC_IP_NAME>"
  hosts:
    - host: "<REPLACE_WITH_DOMAIN_NAME>"
      paths:
        - path: /
          pathType: Prefix
```

**Smoke-script behavior:** Retrieves the external IP from the Ingress status
(`kubectl get ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`),
then performs an HTTPS GET. Expects HTTP 200 with a valid TLS certificate.

### internal-lb

This variant verifies that GKE provisions an internal HTTP(S) load balancer
when the Ingress has the internal annotation.

**Product chart values:**

```yaml
ingress:
  enabled: true
  className: "gce-internal"
  annotations:
    cloud.google.com/load-balancer-type: "Internal"
    networking.gke.io/internal-ips: "<REPLACE_WITH_INTERNAL_IP>"
```

**Smoke-script behavior:** Verifies the internal LB IP is a private VNet
address. Performs an HTTP GET from within the VPC (via a debug pod).
Expects HTTP 200.

### gateway-api

This variant verifies that the GKE Gateway Controller provisions a Google
Cloud load balancer from a Gateway + HTTPRoute pair.

**Product chart values:**

```yaml
gatewayRoute:
  enabled: true
  parentGateway:
    name: chart-test-swarm-gcp-gateway
    namespace: "<REPLACE_WITH_NAMESPACE>"
```

**Smoke-script behavior:** Waits for the Gateway to have an assigned IP
(`kubectl get gateway -o jsonpath='{.status.addresses[0].value}'`),
then performs an HTTP GET. Expects HTTP 200.

## Assertions

| Type | What it verifies |
|---|---|
| `helm-status-deployed` | Product chart installed successfully |
| `pods-ready` | All product pods Ready |
| `smoke-script` | Per-variant behavior (see variant descriptions) |
| `service-reachable` | LB IP resolves and returns HTTP 200 |

**Important:** These assertions are NOT run from this repository. They are
authored for reference and validated structurally (dry-run, yamllint) but never
executed in CI or local test runs.

## Known gotchas

- **Google-managed certificate provisioning takes 10-15 minutes**: After
  creating a `ManagedCertificate` resource, Google must verify domain
  ownership and provision the certificate. The Ingress will show a
  provisioning error until the certificate is ready. Use the
  `kubernetes.io/ingress.allow-http: "true"` annotation to allow HTTP
  traffic while the certificate is being provisioned.

- **Container-native load balancing requires VPC-native clusters**: The
  external HTTP(S) LB sends traffic directly to Pod IPs (container-native
  load balancing) on VPC-native clusters. On routes-based clusters, traffic
  goes through node IPs instead, which adds an extra network hop.

- **Internal HTTP(S) LB requires `cloud.google.com/load-balancer-type: "Internal"`**:
  Without this annotation, GKE will create an external LB. The annotation
  must be present at Ingress creation time — adding it later has no effect.

- **GKE Ingress controller creates firewall rules automatically**: The
  Ingress controller creates VPC firewall rules for health checks and
  frontend traffic. If you have restrictive firewall policies, the
  controller-created rules may conflict. Verify with:

  ```bash
  gcloud compute firewall-rules list \
    --filter="network:<VPC_NAME> AND name~^k8s-"
  ```

- **Gateway `allowedRoutes.namespaces.from: Same`**: This restricts routes
  to the same namespace as the Gateway. If your HTTPRoute is in a different
  namespace, use `from: All` and add a `ReferenceGrant`.

- **Gateway provisioning latency**: A GKE Gateway creates a Google Cloud
  HTTP(S) Load Balancer, which takes 3-7 minutes to provision on first
  creation. Subsequent updates are faster (~60s).

- **Static IP reservation must be global for external LB**: The
  `kubernetes.io/ingress.global-static-ip-name` annotation references a
  *global* static IP. Regional static IPs cannot be used with the global
  external HTTP(S) LB.

- **Health check paths must return 200**: GKE's external LB health checker
  expects a 200 response from the health check path. 301/302 redirects are
  treated as unhealthy. Ensure your application's health endpoint returns
  a direct 200 response.

## References

- [GKE Ingress documentation](https://cloud.google.com/kubernetes-engine/docs/concepts/ingress)
- [GKE Ingress for external HTTP(S) LB](https://cloud.google.com/kubernetes-engine/docs/how-to/load-balance-ingress)
- [GKE internal HTTP(S) LB](https://cloud.google.com/kubernetes-engine/docs/how-to/internal-ingress)
- [GKE Gateway Controller](https://cloud.google.com/kubernetes-engine/docs/concepts/gateway-api)
- [Google-managed certificates](https://cloud.google.com/kubernetes-engine/docs/how-to/managed-certs)
- [Container-native load balancing](https://cloud.google.com/kubernetes-engine/docs/concepts/container-native-load-balancing)
- [GKE network concepts](https://cloud.google.com/kubernetes-engine/docs/concepts/network-overview)
- [Ingress features](https://cloud.google.com/kubernetes-engine/docs/concepts/ingress-features)
