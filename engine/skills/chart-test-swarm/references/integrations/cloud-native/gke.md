# gke

**AUTHORED ONLY — not run from this repo.** The scenarios referenced here are
authored and validated via `kubectl --dry-run=client` and `kubeval` against a
local kind cluster. No `kubectl apply`, `helm install`, or `gcloud` invocation
targets a real GKE cluster from this repository. Apply them yourself to your
own GKE cluster.

## What

Google Kubernetes Engine (GKE) is Google Cloud's managed Kubernetes service.
GKE provides a control plane operated by Google, integrated with GCP IAM,
networking, logging, and monitoring. For chart-test-swarm, the GKE primer
documents the GCP-specific integrations that a Helm chart may depend on when
deployed to GKE — in particular how the chart can authenticate to GCP services,
secure ingress traffic, leverage the Gateway API, and operate across zones in a
regional cluster.

The four GCP features covered by this primer are:

- **Workload Identity** — maps a Kubernetes ServiceAccount to a GCP IAM service
  account so pods can call GCP APIs (Cloud Storage, Pub/Sub, Secret Manager)
  without exporting service-account keys.
- **Identity-Aware Proxy (IAP)** — places GCP's managed authentication layer in
  front of a GKE-hosted application, enforcing Google Identity-based access
  before traffic reaches the cluster.
- **GKE Gateway Controller** — a managed implementation of the Kubernetes
  Gateway API that provisions Google Cloud Load Balancers (HTTP(S) + TCP/UDP)
  from Gateway and HTTPRoute resources defined inside the cluster.
- **Regional cluster networking** — spreads the control plane and (optionally)
  node pools across multiple zones within a GCP region, using VPC-native alias
  IP ranges for Pod and Service networking.

These features are GKE-specific. They cannot be exercised on kind or minikube
because they depend on GCP infrastructure (IAM, Cloud Load Balancing, GFE,
VPC). The scenarios authored for this integration are **design-only** — they
serve as reference implementations that a user ships to their own GKE cluster.

## Target Kubernetes version

GKE 1.30+ (GKE release channel: Regular, 2024 H2).

- Workload Identity for GKE is enabled by default on GKE 1.30 clusters
  created with `--workload-pool` (GKE metadata server available at `169.254.169.254`).
- GKE Gateway Controller is GA in 1.29+ and supports all Gateway API resources
  (`GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `ReferenceGrant`).
- IAP for GKE requires GKE 1.24+ and is supported on all currently-available
  release channels.
- Regional clusters are available on all GKE versions; VPC-native networking
  is the default since 1.27.

All scenario YAMLs authored under `cloud-native/` carry an annotation
`chart-test-swarm/target-k8s-version: gke-1.30` to pin the expected Kubernetes
API version.

## When

Use GKE cloud-native scenarios when the Helm chart under test:

- Depends on GCP IAM for service-to-service authentication (e.g. accessing
  Cloud Storage buckets, Pub/Sub topics, or Secret Manager secrets). Workload
  Identity is the preferred path — no service-account key files in Secrets.
- Must be exposed through GCP's Identity-Aware Proxy so that only authenticated
  users (Google Workspace, Cloud Identity, or external identities) can reach
  the application. This is common for internal tools, admin dashboards, and
  pre-production environments.
- Leverages the Kubernetes Gateway API and expects a GCP-native load balancer
  (Global external HTTP(S) LB, regional internal LB, or cross-project LB).
- Runs on a regional GKE cluster and needs to verify that Pods are scheduled
  across multiple zones, that Services route to Pods in all zones, and that
  inter-zone network latency is within acceptable bounds.
- Must prove that the chart's IAM binding annotations (`iam.gke.io/gcp-service-account`)
  are correctly templated and that the GKE metadata server returns the expected
  access token.

**Do not use** GKE scenarios if:

- You need to test TLS certificate lifecycle — use the `cert-manager` *local*
  scenarios instead. GKE scenarios assume cert-manager is already provisioned
  or that certificates are provisioned via GCP Certificate Manager.
- You are testing a service mesh (Istio, Linkerd) — use the `service-mesh/`
  local scenarios. Mesh scenarios on GKE add the additional dimension of
  GCP load balancer interaction, which is beyond the current scenario scope.
- You are testing policy enforcement (Gatekeeper, Kyverno) — use the `policy/`
  local scenarios. GKE Policy Controller (the managed variant) is not in scope.

## How

This repo does **not** run GKE scenarios. They are authored as reference
implementations that you take to your own GKE cluster.

### Application pattern

Every GKE cloud-native scenario follows this two-phase pattern:

**Phase 1 (validation in this repo):**

1. Write the scenario YAML with `cluster.provider: gke`.
2. Validate against `engine/templates/scenario.schema.json`.
3. Run `kubectl --dry-run=client -f` against every embedded manifest snippet.
4. Run `kubeval --strict --kubernetes-version 1.30.0` against every
   `raw_manifest` preinstall path.
5. Run `helm lint` on the product chart and `helm template` on any
   helm-values snippet.
6. Run `yamllint` on the primer and all scenario YAMLs.

**Phase 2 (you, on your own GKE cluster):**

1. Authenticate to GCP: `gcloud auth login` and
   `gcloud container clusters get-credentials <cluster> --region <region>`.
2. Set up IAM prerequisites (Workload Identity binding, IAP OAuth consent).
3. Run `bash engine/scripts/run-scenario.sh <scenario.yaml>` with the
   environment variable `CLUSTER_NAME=chart-test-swarm-gke-<id>` and
   `PROVIDER=gke`.
4. Review the emitted `reports/run-*/result.yaml` and artifact bundle.

### Consumer chart wiring

The sample product chart (`examples/sample-product-chart/chart/`) exposes value
blocks for GKE-specific features. Set these values for GKE scenarios:

```yaml
# Workload Identity — annotate the ServiceAccount
gke:
  workloadIdentity:
    enabled: true
    gcpServiceAccount: "<REPLACE_WITH_GCP_SA_EMAIL>"

  # IAP — enable IAP-compatible BackendConfig
  iap:
    enabled: true
    oauthClientId: "<REPLACE_WITH_OAUTH_CLIENT_ID>"
    oauthClientSecret: "<REPLACE_WITH_OAUTH_CLIENT_SECRET>"

  # Gateway API — delegate to GKE Gateway Controller
  gatewayController:
    enabled: true
    gatewayClassName: "gke-l7-global-external-managed"
```

All values containing sensitive material carry `<REPLACE_WITH_...>` placeholders.
No real project IDs, service-account emails, or OAuth secrets are stored in this
repository.

## Credential prerequisites

Before applying any GKE scenario to your cluster, you must have the following
GCP credentials and IAM bindings in place.

### gcloud authentication

```bash
# Authenticate as a user with GKE admin + IAM admin permissions
gcloud auth login

# Set the project
gcloud config set project <YOUR_GCP_PROJECT_ID>

# Verify access
gcloud container clusters list
```

### Workload Identity IAM bindings

The Kubernetes ServiceAccount that runs the product chart's pods must be bound
to a GCP IAM service account. This binding is **not** created by the scenario —
you must create it before applying:

```bash
# Create the GCP service account (if it doesn't exist)
gcloud iam service-accounts create chart-test-swarm-gke-sa \
  --display-name "chart-test-swarm GKE Workload Identity"

# Grant the GCP service account the necessary roles
gcloud projects add-iam-policy-binding <YOUR_GCP_PROJECT_ID> \
  --member "serviceAccount:chart-test-swarm-gke-sa@<YOUR_GCP_PROJECT_ID>.iam.gserviceaccount.com" \
  --role "roles/storage.objectViewer"

# Bind the Kubernetes SA to the GCP SA
gcloud iam service-accounts add-iam-policy-binding \
  chart-test-swarm-gke-sa@<YOUR_GCP_PROJECT_ID>.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:<YOUR_GCP_PROJECT_ID>.svc.id.goog[<NAMESPACE>/<KSA_NAME>]"
```

Confirm the binding is active:

```bash
gcloud iam service-accounts get-iam-policy \
  chart-test-swarm-gke-sa@<YOUR_GCP_PROJECT_ID>.iam.gserviceaccount.com
```

### IAP OAuth consent screen

IAP requires an OAuth 2.0 client ID configured in the GCP project:

1. Go to **APIs & Services** → **OAuth consent screen** in the GCP Console.
2. Configure the consent screen (Internal for Google Workspace orgs, External
   for consumer identities).
3. Go to **APIs & Services** → **Credentials** and create an OAuth 2.0 Client ID
   of type **Web application**.
4. Note the Client ID and Client Secret — provide these as values in the
   scenario YAML (using `<REPLACE_WITH_...>` placeholders).

### GKE Gateway Controller prerequisites

The GKE Gateway Controller is enabled by default on GKE 1.27+ clusters using
the Standard creation mode. Verify it is available:

```bash
kubectl get gatewayclasses.gateway.networking.k8s.io
# Should list: gke-l7-global-external-managed, gke-l7-regional-external-managed,
#              gke-l7-gxlb, gke-l7-rilb

# Verify the controller is running
kubectl -n gke-gmp-system get pods -l app=gke-gateway-controller
```

If your cluster was created before GKE 1.27 or with gateway controller disabled,
enable it via:

```bash
gcloud container clusters update <CLUSTER_NAME> \
  --region <REGION> \
  --gateway-api=standard
```

## Cluster prerequisites

Every GKE scenario in this primer expects the following cluster configuration.

### GKE version

**Minimum: GKE 1.30** (release channel: Regular).

```bash
# Create a new GKE cluster matching scenario expectations
gcloud container clusters create chart-test-swarm-gke \
  --region us-central1 \
  --cluster-version "1.30" \
  --release-channel regular \
  --workload-pool "<YOUR_GCP_PROJECT_ID>.svc.id.goog" \
  --gateway-api standard \
  --num-nodes 3 \
  --machine-type e2-standard-4
```

### Required add-ons

| Add-on | Required for | Enabled by default? |
|---|---|---|
| Workload Identity (GKE metadata server) | Workload Identity scenarios | Yes, when `--workload-pool` is set |
| GKE Gateway Controller | Gateway API scenarios | Yes, on 1.27+ Standard clusters |
| HTTP Load Balancing | IAP, Gateway scenarios | Yes |
| Cloud Operations (logging + monitoring) | Observability (all scenarios) | Yes |
| Network Policy | Regional networking scenarios | No — enable with `--enable-network-policy` |

### VPC-native networking

All GKE scenarios assume **VPC-native (alias IP) networking**. This is the
default for GKE 1.27+ clusters and is required for:

- Workload Identity (the GKE metadata server uses Pod IPs to identify callers)
- Regional cluster networking (Pod IPs must be routable across zones)
- GKE Gateway Controller (the controller creates L7 ILB configurations that
  reference Pod endpoints by IP).

Verify your cluster uses VPC-native mode:

```bash
gcloud container clusters describe <CLUSTER_NAME> --region <REGION> \
  --format "value(ipAllocationPolicy.useIpAliases)"
# Must return: True
```

### Network mode for regional scenarios

Regional GKE scenarios expect:

- **3 nodes minimum** (one per zone in the region, e.g. `us-central1-a`,
  `us-central1-b`, `us-central1-c`)
- **Node auto-repair and auto-upgrade enabled** (default on GKE)
- **Pod anti-affinity rules** in the product chart so that replicas spread
  across zones

No scenario exercises multi-cluster or multi-region topologies — the scope is
a single regional GKE cluster.

## Variants

Four scenario variants are authored under
`examples/sample-product-chart/chart-test/scenarios/`. All use
`cluster.provider: gke` and carry the `AUTHORED ONLY` banner.

| Variant | File | GCP feature | What it exercises |
|---|---|---|---|
| workload-identity | `cloud-native-gke-workload-identity.yaml` | Workload Identity | SA annotated with `iam.gke.io/gcp-service-account`; pod mounts projected token; smoke-script calls GCP Storage API |
| iap | `cloud-native-gke-iap.yaml` | IAP | BackendConfig with IAP enabled; Ingress references it; smoke-script verifies IAP redirect (HTTP 302) |
| gateway-controller | `cloud-native-gke-gateway-controller.yaml` | GKE Gateway Controller | Gateway + HTTPRoute; smoke-script queries provisioned L7 LB; verifies healthy backend |
| regional-networking | `cloud-native-gke-regional-networking.yaml` | Regional cluster networking | Pod spread across zones; smoke-script verifies ≥ 2 zones and inter-zone Service reachability |

Each variant file carries the `AUTHORED ONLY` notice as a YAML comment at the
top of the file. The full scenario paths are:

- `examples/sample-product-chart/chart-test/scenarios/cloud-native-gke-workload-identity.yaml`
- `examples/sample-product-chart/chart-test/scenarios/cloud-native-gke-iap.yaml`
- `examples/sample-product-chart/chart-test/scenarios/cloud-native-gke-gateway-controller.yaml`
- `examples/sample-product-chart/chart-test/scenarios/cloud-native-gke-regional-networking.yaml`

### workload-identity

This variant verifies that a Kubernetes ServiceAccount annotated with
`iam.gke.io/gcp-service-account` successfully obtains a GCP access token from
the GKE metadata server and uses it to call a GCP API.

**Key preinstall items:**

```yaml
# GCP IAM policy binding (MUST be applied on the actual GKE cluster)
kind: raw_manifest
path: chart-test/fixtures/cloud-native/gke/workload-identity-binding.yaml
```

The fixture contains:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: chart-test-swarm-gke-sa
  namespace: <REPLACE_WITH_NAMESPACE>
  annotations:
    iam.gke.io/gcp-service-account: "<REPLACE_WITH_GCP_SA_EMAIL>"
```

**Smoke-script behavior:** The assertion curl-calls the GKE metadata server
at `http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token`
with the header `Metadata-Flavor: Google`, extracts the access token, and uses
it to list buckets in Cloud Storage (`curl -H "Authorization: Bearer $TOKEN"
https://storage.googleapis.com/storage/v1/b?project=<PROJECT>`).

### iap

This variant verifies that IAP is correctly configured as the authentication
layer for the product chart's Ingress.

**Key preinstall items:**

```yaml
# BackendConfig enabling IAP
kind: raw_manifest
path: chart-test/fixtures/cloud-native/gke/iap-backendconfig.yaml
```

The fixture contains:

```yaml
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: chart-test-swarm-iap-config
spec:
  iap:
    enabled: true
    oauthclientCredentials:
      secretName: chart-test-swarm-iap-secret
```

**Smoke-script behavior:** Curls the Ingress external IP. Expects an HTTP 302
redirect to `accounts.google.com` (the IAP authentication flow). Then follows
the redirect chain to confirm the IAP cookie is set. Does **not** attempt to
complete a full OAuth login — that requires a real browser session.

### gateway-controller

This variant verifies that the GKE Gateway Controller provisions a Google Cloud
Load Balancer from a `Gateway` + `HTTPRoute` pair.

**Key preinstall items:**

```yaml
# GKE Gateway + HTTPRoute
kind: raw_manifest
path: chart-test/fixtures/cloud-native/gke/gateway-httproute.yaml
```

The fixture contains:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: chart-test-swarm-gke-gateway
spec:
  gatewayClassName: gke-l7-global-external-managed
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: chart-test-swarm-gke-httproute
spec:
  parentRefs:
    - name: chart-test-swarm-gke-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: <REPLACE_WITH_SERVICE_NAME>
          port: 80
```

**Smoke-script behavior:** Waits for the Gateway to have an assigned IP
(`kubectl get gateway -o jsonpath='{.status.addresses[0].value}'`), then
performs an HTTP GET against `http://<GATEWAY_IP>/`. Expects HTTP 200 and
the product chart's known response body.

### regional-networking

This variant verifies that Pods are spread across multiple zones in a
regional GKE cluster and that inter-zone Service routing works.

**Smoke-script behavior:**

1. Lists Pod nodes and extracts their zone labels
   (`topology.kubernetes.io/zone`).
2. Asserts that at least 2 distinct zones are present.
3. Port-forwards to one Pod in zone A and curls a Pod IP in zone B through
   the ClusterIP Service, verifying that the Service routes across zones.
4. Captures and reports per-hop latency (optional benchmark mode).

No additional preinstall items are required beyond the standard GKE cluster
configuration described in the Cluster prerequisites section.

## Assertions

| Type | What it verifies |
|---|---|
| `helm-status-deployed` | Product chart installed successfully |
| `pods-ready` | All product pods Ready (with zone spread verification for regional scenario) |
| `smoke-script` | Per-variant behavior (see variant descriptions) |

Assertion scripts live under
`examples/sample-product-chart/chart-test/assertions/cloud-native/gke/` and are
referenced by relative path from the scenario YAML. Each smoke-script receives
`RELEASE`, `NAMESPACE`, `KUBECONFIG`, `KUBE_CONTEXT`, `PROJECT_DIR`, and
`GCP_PROJECT_ID` via the environment.

**Important:** These assertions are NOT run from this repository. The
smoke-scripts contain calls to `gcloud`, `curl` against `metadata.google.internal`,
and other GCP-specific operations that ONLY work inside a GKE cluster. They are
authored for reference and validated structurally (dry-run, kubeval, yamllint)
but never executed in CI or local test runs.

## Known gotchas

- **Workload Identity propagation delay**: After annotating a ServiceAccount
  with `iam.gke.io/gcp-service-account`, the GKE metadata server may take
  up to 30 seconds to reflect the binding. The smoke-script retries with
  exponential backoff (1s, 2s, 4s, 8s) before declaring failure.

- **IAP BackendConfig applies per-ServicePort**: The BackendConfig resource
  is referenced from the Service via the `cloud.google.com/backend-config`
  annotation with a JSON map of port names to BackendConfig names. If your
  Service exposes multiple ports, ensure the BackendConfig is attached to
  the correct port.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: chart-test-swarm-iap-svc
  annotations:
    cloud.google.com/backend-config: '{"http": "chart-test-swarm-iap-config"}'
```

- **Gateway provisioning latency**: A GKE Gateway creates a Google Cloud
  HTTP(S) Load Balancer, which takes 3–7 minutes to provision on first
  creation. The smoke-script polls `status.addresses` with a timeout of
  10 minutes. Subsequent updates (e.g., adding an HTTPRoute) are faster
  (~60 seconds) because the LB already exists.

- **Gateway `allowedRoutes.namespaces.from: Same`**: This restricts routes
  to the same namespace as the Gateway. If your HTTPRoute is in a different
  namespace, use `from: All` and add a `ReferenceGrant` in the HTTPRoute's
  namespace.

- **Regional cluster zone skew**: In a regional GKE cluster, the control
  plane runs in all three zones, but node pools may be zonal (one zone) or
  regional (spanning all zones). The regional-networking scenario expects
  a regional node pool. With zonal node pools in a regional cluster, you will
  only see pods in one zone — the assertion will fail. Verify with:

  ```bash
  gcloud container node-pools describe default-pool \
    --cluster <CLUSTER_NAME> --region <REGION> \
    --format "value(config.locations)"
  ```

- **VPC-native is irreversible after cluster creation**: If your cluster was
  created without VPC-native networking (routes-based), you cannot convert it
  to VPC-native. You must recreate the cluster. This is why the GKE cluster
  creation command in the Cluster prerequisites section includes (implicitly)
  VPC-native defaults.

- **GKE metadata server is per-node, not per-cluster**: The Workload Identity
  metadata server runs at `169.254.169.254` on every node. If you use
  `hostNetwork: true` pods, they will NOT reach the metadata server because
  `hostNetwork` bypasses the GKE-managed IP tables rules. The product chart's
  pods must NOT use `hostNetwork: true` for Workload Identity scenarios.

- **IAP and GKE Gateway Controller are mutually exclusive for the same host**:
  IAP attaches to a BackendConfig referenced by an Ingress. The GKE Gateway
  Controller creates a different type of load balancer. Do not attempt to
  layer IAP on top of a Gateway — use one or the other per hostname.

- **IAM bindings use workload identity federation, not service account keys**:
  The smoke-scripts explicitly do NOT use JSON key files. If your GCP project
  has the `iam.disableServiceAccountKeyCreation` org policy, these scenarios
  are fully compatible because they rely exclusively on workload identity
  federation.

## References

- [GKE documentation](https://cloud.google.com/kubernetes-engine/docs)
- [Workload Identity for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [Enabling IAP for GKE](https://cloud.google.com/iap/docs/enabling-kubernetes-howto)
- [GKE Gateway Controller](https://cloud.google.com/kubernetes-engine/docs/concepts/gateway-api)
- [Gateway API specification](https://gateway-api.sigs.k8s.io/)
- [Regional clusters](https://cloud.google.com/kubernetes-engine/docs/concepts/regional-clusters)
- [VPC-native clusters](https://cloud.google.com/kubernetes-engine/docs/concepts/alias-ips)
- [BackendConfig for GKE Ingress](https://cloud.google.com/kubernetes-engine/docs/how-to/backendconfig)
- [GKE IAM roles reference](https://cloud.google.com/kubernetes-engine/docs/how-to/iam)
