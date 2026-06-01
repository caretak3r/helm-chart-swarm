# aks

**AUTHORED ONLY — not run from this repo.** The scenarios referenced here are
authored and validated via `kubectl --dry-run=client` and `kubeval` against a
local kind cluster. No `kubectl apply`, `helm install`, or `az` invocation
targets a real AKS cluster from this repository. Apply them yourself to your
own AKS cluster.

## What

Azure Kubernetes Service (AKS) is Microsoft Azure's managed Kubernetes service.
AKS provides a control plane operated by Azure, integrated with Azure AD,
Virtual Networks, Azure Monitor, and Azure Policy. For chart-test-swarm, the
AKS primer documents the Azure-specific integrations that a Helm chart may
depend on when deployed to AKS — in particular how the chart can authenticate
to Azure services, route ingress through Azure Application Gateway, leverage
the managed App Routing addon for simple public exposure, and enforce
compliance via Azure Policy.

The four Azure features covered by this primer are:

- **Workload Identity** — federates a Kubernetes ServiceAccount with an Azure
  AD application (or user-assigned managed identity) using OIDC so pods can
  authenticate to Azure services (Key Vault, Storage, SQL Database, Service
  Bus) without embedding client secrets or certificates in the cluster.
- **AGIC (Application Gateway Ingress Controller)** — an ingress controller
  that configures an Azure Application Gateway (L7 load balancer with WAF,
  SSL termination, URL-based routing, and cookie-based session affinity)
  from Kubernetes Ingress resources. AGIC runs as a pod inside AKS and
  updates the Application Gateway configuration via ARM.
- **App Routing addon** — a managed AKS addon that deploys an nginx-based
  ingress controller with an integrated Azure DNS zone manager. Enabling
  the addon provisions a public Azure DNS zone and automatically creates
  DNS records for Ingress hosts. Simpler than AGIC for basic HTTP routing.
- **Azure Policy** — extends Azure Policy's compliance and governance
  capabilities into AKS via Gatekeeper v3. Azure Policy definitions
  (built-in or custom) are evaluated against cluster resources, surfacing
  compliance state in the Azure Portal alongside VM and storage policies.

These features are AKS-specific. They cannot be exercised on kind or
minikube because they depend on Azure infrastructure (Application Gateway,
Azure AD, Azure DNS, ARM). The scenarios authored for this integration are
**design-only** — they serve as reference implementations that a user ships
to their own AKS cluster.

## Target Kubernetes version

AKS 1.30+ (AKS release tracker: GA since September 2024).

- Workload Identity for AKS is GA in 1.30 and replaces the deprecated
  aad-pod-identity (preview) component. Federated identity credentials
  are configured via Azure AD (not via cluster-internal `AzureIdentity`
  CRDs).
- AGIC v1.7+ supports AKS 1.27+ and requires `contributor` RBAC on the
  Application Gateway resource. AGIC uses AKS Pod Identity or Workload
  Identity for ARM authentication.
- App Routing addon is GA on AKS 1.27+ and provisions `ingress-nginx`
  with the external-dns sidecar for Azure DNS integration.
- Azure Policy for AKS requires `Microsoft.PolicyInsights` resource
  provider registered and the `azure-policy` pod addon installed in
  `kube-system`. Built-in policies cover 20+ AKS-specific compliance
  scenarios.

All scenario YAMLs authored under `cloud-native/` carry an annotation
`chart-test-swarm/target-k8s-version: aks-1.30` to pin the expected
Kubernetes API version.

## When

Use AKS cloud-native scenarios when the Helm chart under test:

- Depends on Azure AD Workload Identity for service-to-service
  authentication (e.g. accessing Azure Key Vault secrets, Storage blob
  containers, or SQL Database). Workload Identity is the GA-recommended
  path — no client secrets in Kubernetes Secrets.
- Must be exposed through Azure Application Gateway (AGIC) with WAF,
  SSL termination via Azure Key Vault-stored certificates, and
  cookie-based affinity. Use AGIC when you need L7 features beyond
  basic HTTP routing — WAF policy, path-based routing to multiple
  backends, or private (internal) Application Gateway.
- Needs a simple public HTTP/HTTPS ingress with automatic DNS record
  creation. Use the App Routing addon when you want Azure to manage
  the nginx ingress controller and Azure DNS zone on your behalf.
- Must comply with organizational governance policies enforced through
  Azure Policy (e.g. "all namespaces must carry a cost-center label",
  "container images must come from approved Azure Container Registry
  instances"). Azure Policy moves compliance enforcement outside the
  cluster — the Gatekeeper-based pod syncs policy definitions from
  Azure.
- Must prove that the chart's workload identity annotations
  (`azure.workload.identity/client-id`) are correctly templated and
  that the projected service account token can exchange for an Azure
  AD access token.

**Do not use** AKS scenarios if:

- You need to test TLS certificate lifecycle — use the `cert-manager`
  *local* scenarios instead. AKS scenarios assume cert-manager is
  already provisioned or that certificates come from Azure Key Vault.
- You are testing a service mesh (Istio, Linkerd) — use the
  `service-mesh/` local scenarios. AKS supports the Istio addon and
  Open Service Mesh (deprecated), but mesh scenarios on AKS add the
  additional dimension of Azure CNI interaction, which is beyond the
  current scenario scope.
- You are testing policy enforcement on a non-Azure cluster — use the
  `policy/` local Gatekeeper or Kyverno scenarios. Azure Policy uses
  Gatekeeper under the hood but the policy sync mechanism is
  Azure-specific.

## How

This repo does **not** run AKS scenarios. They are authored as reference
implementations that you take to your own AKS cluster.

### Application pattern

Every AKS cloud-native scenario follows this two-phase pattern:

**Phase 1 (validation in this repo):**

1. Write the scenario YAML with `cluster.provider: aks`.
2. Validate against `engine/templates/scenario.schema.json`.
3. Run `kubectl --dry-run=client -f` against every embedded manifest
   snippet.
4. Run `kubeval --strict --kubernetes-version 1.30.0` against every
   `raw_manifest` preinstall path.
5. Run `helm lint` on the product chart and `helm template` on any
   helm-values snippet.
6. Run `yamllint` on the primer and all scenario YAMLs.

**Phase 2 (you, on your own AKS cluster):**

1. Authenticate to Azure: `az login` and
   `az aks get-credentials --resource-group <rg> --name <cluster>`.
2. Set up Azure AD prerequisites (app registration, federated identity
   credential, Key Vault access policy if needed).
3. Run `bash engine/scripts/run-scenario.sh <scenario.yaml>` with the
   environment variable `CLUSTER_NAME=chart-test-swarm-aks-<id>` and
   `PROVIDER=aks`.
4. Review the emitted `reports/run-*/result.yaml` and artifact bundle.

### Consumer chart wiring

The sample product chart (`examples/sample-product-chart/chart/`) exposes
value blocks for AKS-specific features. Set these values for AKS scenarios:

```yaml
# Workload Identity — annotate the ServiceAccount
aks:
  workloadIdentity:
    enabled: true
    clientId: "<REPLACE_WITH_AZURE_CLIENT_ID>"

  # AGIC — use Application Gateway as the ingress controller
  agic:
    enabled: true
    appgwName: "<REPLACE_WITH_APPGW_NAME>"
    appgwResourceGroup: "<REPLACE_WITH_APPGW_RG>"
    appgwSubnetCidr: "<REPLACE_WITH_APPGW_SUBNET>"

  # App Routing addon — managed nginx + Azure DNS
  appRouting:
    enabled: true
    dnsZoneResourceGroup: "<REPLACE_WITH_DNS_RG>"

  # Azure Policy — Gatekeeper ConstraintTemplate
  azurePolicy:
    enabled: true
    policyDefinitionId: "<REPLACE_WITH_POLICY_DEF_ID>"
```

All values containing sensitive material carry `<REPLACE_WITH_...>`
placeholders. No real Azure AD client IDs, subscription IDs, or Application
Gateway names are stored in this repository.

## Credential prerequisites

Before applying any AKS scenario to your cluster, you must have the
following Azure credentials and service principals in place.

### Azure authentication

```bash
# Login to Azure (requires Contributor on the subscription)
az login

# Set the subscription
az account set --subscription "<REPLACE_WITH_SUBSCRIPTION_ID>"

# Verify AKS access
az aks list --resource-group <REPLACE_WITH_RESOURCE_GROUP> -o table
```

### Workload Identity federated credential

Each Kubernetes ServiceAccount that uses Workload Identity must have an
Azure AD application registration with a federated identity credential
scoped to the ServiceAccount:

```bash
# Variables
APPLICATION_NAME="chart-test-swarm-aks-app"
SERVICE_ACCOUNT_NAMESPACE="<REPLACE_WITH_NAMESPACE>"
SERVICE_ACCOUNT_NAME="chart-test-swarm-aks-sa"
AKS_OIDC_ISSUER_URL="$(az aks show \
  --resource-group <REPLACE_WITH_RESOURCE_GROUP> \
  --name <REPLACE_WITH_CLUSTER_NAME> \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)"

# Create the app registration
APP_OBJECT_ID=$(az ad app create \
  --display-name "$APPLICATION_NAME" \
  --query id -o tsv)

# Create a service principal for the app
az ad sp create --id "$APP_OBJECT_ID"

# Create the federated credential (requries the app owner role)
az ad app federated-credential create \
  --id "$APP_OBJECT_ID" \
  --federated-credential \
  name="chart-test-swarm-aks-fc" \
  issuer="$AKS_OIDC_ISSUER_URL" \
  subject="system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}" \
  audience="api://AzureADTokenExchange"

# Get the client ID to use in the ServiceAccount annotation
APP_CLIENT_ID=$(az ad app show --id "$APP_OBJECT_ID" --query appId -o tsv)
echo "Client ID for ServiceAccount annotation: $APP_CLIENT_ID"
```

Confirm the binding is active:

```bash
az ad app federated-credential list --id "$APP_OBJECT_ID" -o table
kubectl -n <REPLACE_WITH_NAMESPACE> describe sa chart-test-swarm-aks-sa
```

### AGIC identity and permissions

AGIC requires an identity (managed identity or Workload Identity) with
the `Contributor` role on the Application Gateway resource.

**Option A — AKS managed identity (for AGIC as an addon):**

```bash
# Enable the ingress-appgw addon during cluster creation
az aks create \
  --resource-group <REPLACE_WITH_RESOURCE_GROUP> \
  --name <REPLACE_WITH_CLUSTER_NAME> \
  --enable-managed-identity \
  --enable-addons ingress-appgw \
  --appgw-name <REPLACE_WITH_APPGW_NAME> \
  --appgw-subnet-cidr "<REPLACE_WITH_APPGW_SUBNET>" \
  --node-count 3
```

**Option B — Helm-based AGIC with Workload Identity:**

```bash
# Create a user-assigned managed identity
az identity create \
  --resource-group <REPLACE_WITH_RESOURCE_GROUP> \
  --name chart-test-swarm-agic-identity

# Grant Contributor on the Application Gateway
IDENTITY_PRINCIPAL_ID=$(az identity show \
  --resource-group <REPLACE_WITH_RESOURCE_GROUP> \
  --name chart-test-swarm-agic-identity \
  --query principalId -o tsv)

APPGW_ID=$(az network application-gateway show \
  --resource-group <REPLACE_WITH_RESOURCE_GROUP> \
  --name <REPLACE_WITH_APPGW_NAME> \
  --query id -o tsv)

az role assignment create \
  --assignee "$IDENTITY_PRINCIPAL_ID" \
  --role "Contributor" \
  --scope "$APPGW_ID"

# Grant Reader on the resource group (to list Application Gateways)
az role assignment create \
  --assignee "$IDENTITY_PRINCIPAL_ID" \
  --role "Reader" \
  --scope "$(az group show --name <REPLACE_WITH_RESOURCE_GROUP> --query id -o tsv)"
```

### App Routing addon prerequisites

The App Routing addon requires a public Azure DNS zone. If you do not
already have one, create it before enabling the addon:

```bash
# Create a public DNS zone
az network dns zone create \
  --resource-group <REPLACE_WITH_RESOURCE_GROUP> \
  --name "<REPLACE_WITH_DOMAIN_NAME>"

# Enable the addon (referencing the DNS zone resource group)
az aks update \
  --resource-group <REPLACE_WITH_RESOURCE_GROUP> \
  --name <REPLACE_WITH_CLUSTER_NAME> \
  --enable-addons web_application_routing \
  --dns-zone-resource-id "$(az network dns zone show \
    --resource-group <REPLACE_WITH_DNS_RG> \
    --name <REPLACE_WITH_DOMAIN_NAME> \
    --query id -o tsv)"
```

### Azure Policy prerequisites

The `Microsoft.PolicyInsights` resource provider must be registered:

```bash
az provider register --namespace Microsoft.PolicyInsights
```

Enable the `azure-policy` addon on the AKS cluster:

```bash
az aks enable-addons \
  --addons azure-policy \
  --resource-group <REPLACE_WITH_RESOURCE_GROUP> \
  --name <REPLACE_WITH_CLUSTER_NAME>
```

Verify the Gatekeeper pods are running:

```bash
kubectl -n gatekeeper-system get pods
# Expected: gatekeeper-audit-*, gatekeeper-controller-*
```

## Cluster prerequisites

Every AKS scenario in this primer expects the following cluster
configuration.

### AKS version

**Minimum: AKS 1.30**.

```bash
# Create a new AKS cluster matching scenario expectations
az aks create \
  --resource-group <REPLACE_WITH_RESOURCE_GROUP> \
  --name chart-test-swarm-aks \
  --kubernetes-version "1.30" \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --node-count 3 \
  --node-vm-size Standard_D4s_v5 \
  --network-plugin azure \
  --network-policy calico
```

### Required add-ons and controllers

| Component | Required for | Installation |
|---|---|---|
| OIDC issuer + Workload Identity | All Workload Identity scenarios | `--enable-oidc-issuer --enable-workload-identity` at cluster creation |
| AGIC | AGIC Ingress scenario | `--enable-addons ingress-appgw` OR helm chart |
| App Routing addon | App Routing scenario | `--enable-addons web_application_routing` |
| Azure Policy addon | Azure Policy scenario | `az aks enable-addons --addons azure-policy` |
| Azure CNI | All scenarios | Default for AKS; required for NetworkPolicy |
| Azure Key Vault CSI Driver | Optional: TLS scenarios | `az aks enable-addons --addons azure-keyvault-secrets-provider` |
| Azure Monitor | Optional: observability | `--enable-addons monitoring` |

### Network mode

All AKS scenarios assume **Azure CNI (advanced networking)**. This provides:

- Pod IPs routable on the Azure Virtual Network
- NetworkPolicy enforcement via Calico
- Application Gateway-to-Pod connectivity (AGIC requires Pod IP
  visibility on the VNet)

For the App Routing scenario, the AKS-managed nginx ingress controller
receives a public IP via an Azure Load Balancer. For the AGIC scenario,
traffic flows through the Application Gateway's frontend IP to the AKS
node pool, and AGIC routes to Pod IPs directly.

**Verify:**

```bash
az aks show \
  --resource-group <REPLACE_WITH_RESOURCE_GROUP> \
  --name <REPLACE_WITH_CLUSTER_NAME> \
  --query "networkProfile.networkPlugin" -o tsv
# Must return: azure
```

### Resource group layout

AKS scenarios expect the following Azure resource topology:

```
┌─────────────────────────────────────────────┐
│ Resource Group: <REPLACE_WITH_RESOURCE_GROUP>│
├─────────────────────────────────────────────┤
│  AKS cluster (chart-test-swarm-aks)         │
│  ├─ node pool (3 × Standard_D4s_v5)         │
│  ├─ OIDC issuer                             │
│  └─ AKS-managed VNet                        │
│                                             │
│  Application Gateway (optional, for AGIC)   │
│  ├─ frontend IP (public)                    │
│  ├─ WAF policy                              │
│  └─ backend pool → AKS node pool            │
│                                             │
│  Public IP (App Routing addon)              │
│  └─ Azure Load Balancer → nginx ingress     │
│                                             │
│  Azure DNS zone (App Routing addon)         │
│  └─ CNAME records → nginx ingress public IP │
└─────────────────────────────────────────────┘
```

## Variants

Four scenario variants are authored under
`examples/sample-product-chart/chart-test/scenarios/cloud-native/`. All use
`cluster.provider: aks` and carry the `AUTHORED ONLY` banner.

| Variant | File | Azure feature | What it exercises |
|---|---|---|---|
| workload-identity | `aks-workload-identity.yaml` | Workload Identity | SA annotated with `azure.workload.identity/client-id`; pod mounts projected token; smoke-script calls Azure Key Vault |
| agic | `aks-agic.yaml` | AGIC | Ingress with `appgw.ingress.kubernetes.io` annotations; smoke-script curls App Gateway frontend IP |
| app-routing | `aks-app-routing.yaml` | App Routing addon | Ingress with auto-provisioned Azure DNS record; smoke-script resolves DNS and curls |
| azure-policy | `aks-azure-policy.yaml` | Azure Policy | Gatekeeper ConstraintTemplate + Constraint; smoke-script verifies policy compliance via dry-run |

Each variant file carries the `AUTHORED ONLY` notice as a YAML comment at
the top of the file. The full scenario paths are:

- `examples/sample-product-chart/chart-test/scenarios/cloud-native/aks-workload-identity.yaml`
- `examples/sample-product-chart/chart-test/scenarios/cloud-native/aks-agic.yaml`
- `examples/sample-product-chart/chart-test/scenarios/cloud-native/aks-app-routing.yaml`
- `examples/sample-product-chart/chart-test/scenarios/cloud-native/aks-azure-policy.yaml`

### workload-identity

This variant verifies that a Kubernetes ServiceAccount annotated with
`azure.workload.identity/client-id` successfully obtains an Azure AD
access token and uses it to authenticate to an Azure service.

**Key preinstall items:**

```yaml
# ServiceAccount with workload identity annotation
kind: raw_manifest
path: chart-test/fixtures/cloud-native/aks/workload-identity-sa.yaml
```

The fixture contains:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: chart-test-swarm-aks-sa
  namespace: <REPLACE_WITH_NAMESPACE>
  annotations:
    azure.workload.identity/client-id: "<REPLACE_WITH_AZURE_CLIENT_ID>"
```

**Smoke-script behavior:** The assertion uses `az login --federated-token`
(via the OIDC token mounted at `/var/run/secrets/azure/tokens/azure-identity-token`)
to authenticate, then calls `az keyvault secret list --vault-name <VAULT>`
to list secrets. Verifies the response is a JSON array with no error. Does
NOT embed Azure AD client secrets — relies entirely on the federated
credential.

### agic

This variant verifies that AGIC (Application Gateway Ingress Controller)
routes HTTP traffic through an Azure Application Gateway to the product
chart.

**Key preinstall items:**

```yaml
# AGIC — installed via Helm in cluster.preinstall
kind: helm
repo:
  name: application-gateway-kubernetes-ingress
  url: https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/
chart: ingress-azure
version: "1.7.0"
release: ingress-azure
namespace: kube-system
values:
  appgw:
    name: <REPLACE_WITH_APPGW_NAME>
    resourceGroup: <REPLACE_WITH_APPGW_RG>
    subscriptionId: <REPLACE_WITH_SUBSCRIPTION_ID>
    usePrivateIP: false
  armAuth:
    type: workloadIdentity
    identityClientID: <REPLACE_WITH_AGIC_CLIENT_ID>
  kubernetes:
    watchNamespace: <REPLACE_WITH_NAMESPACE>
```

**Product chart ingress configuration:**

```yaml
ingress:
  enabled: true
  className: azure-application-gateway
  annotations:
    appgw.ingress.kubernetes.io/ssl-redirect: "true"
  hosts:
    - host: "<REPLACE_WITH_HOSTNAME>"
      paths:
        - path: /
          pathType: Prefix
```

**Smoke-script behavior:** Retrieves the Application Gateway frontend
public IP, then performs an HTTP GET against `http://<APPGW_IP>/` with
the correct `Host:` header. Expects HTTP 200 and the product chart's
known response body.

### app-routing

This variant verifies that the AKS App Routing addon provisions an
nginx ingress controller with Azure DNS integration, and that HTTP
traffic reaches the product chart.

**Key preinstall items:** None — the App Routing addon is enabled at
the cluster level (`az aks update --enable-addons web_application_routing`).
No additional Helm chart is installed by the scenario.

**Product chart values:**

```yaml
ingress:
  enabled: true
  className: webapprouting.kubernetes.azure.com
  hosts:
    - host: "<REPLACE_WITH_HOSTNAME>"
      paths:
        - path: /
          pathType: Prefix
```

The `ingressClassName: webapprouting.kubernetes.azure.com` targets
the AKS-managed nginx ingress controller. Azure DNS automatically
creates an A record (or CNAME) pointing the hostname to the ingress
controller's public IP.

**Smoke-script behavior:**

1. Retrieves the ingress controller's external IP.
2. Resolves the configured hostname via DNS.
3. Curls `http://<HOSTNAME>/` and expects HTTP 200.
4. Verifies that the DNS A record is present in the Azure DNS zone
   by querying `az network dns record-set a list`.

### azure-policy

This variant verifies that Azure Policy for AKS enforces compliance by
rejecting resources that violate a deployed ConstraintTemplate.

**Key preinstall items:**

```yaml
# Azure Policy ConstraintTemplate + Constraint
kind: raw_manifest
path: chart-test/fixtures/cloud-native/aks/azure-policy-constraint.yaml
```

The fixture contains a Gatekeeper `ConstraintTemplate` and `Constraint`
that requires specific labels on Namespace resources. This template
mirrors what Azure Policy syncs into the cluster.

**Smoke-script behavior:**

1. Attempts `kubectl create namespace test-noncompliant` (missing
   the required label) — EXPECTS rejection by the Gatekeeper
   admission webhook.
2. Creates `namespace test-compliant` with the required label set —
   EXPECTS success.
3. Verifies that `kubectl get constraint` shows the constraint in
   `enforcementAction: deny` mode.

## Assertions

| Type | What it verifies |
|---|---|
| `helm-status-deployed` | Product chart installed successfully |
| `pods-ready` | All product pods Ready |
| `smoke-script` | Per-variant behavior (see variant descriptions) |

Assertion scripts live under
`examples/sample-product-chart/chart-test/assertions/cloud-native/aks/` and
are referenced by relative path from the scenario YAML. Each smoke-script
receives `RELEASE`, `NAMESPACE`, `KUBECONFIG`, `KUBE_CONTEXT`, `PROJECT_DIR`,
`AZURE_SUBSCRIPTION_ID`, and `AZURE_RESOURCE_GROUP` via the environment.

**Important:** These assertions are NOT run from this repository. The
smoke-scripts contain calls to `az keyvault`, `az network`, and other
Azure CLI operations that require real Azure credentials and live AKS
clusters. They are authored for reference and validated structurally
(dry-run, kubeval, yamllint) but never executed in CI or local test runs.

## Known gotchas

- **Workload Identity token freshness**: The projected service account
  token used by Azure AD Workload Identity is valid for 24 hours by
  default. The Azure Identity SDK (v1.4+) auto-refreshes the token
  before expiry, but long-running pods using a custom HTTP client must
  implement token refresh. Verify with:

  ```bash
  kubectl exec <pod> -- cat /var/run/secrets/azure/tokens/azure-identity-token | cut -d. -f2 | base64 -d | jq .exp
  ```

- **Workload Identity requires AKS OIDC issuer**: The OIDC issuer must be
  enabled at cluster creation (`--enable-oidc-issuer`). You CANNOT enable
  it on an existing cluster. If your cluster predates the OIDC issuer GA,
  you must recreate it.

  ```bash
  az aks show --resource-group <rg> --name <cluster> \
    --query "oidcIssuerProfile.issuerUrl" -o tsv
  # If empty, the cluster does not have OIDC issuer enabled.
  ```

- **AGIC requires Application Gateway v2 SKU**: AGIC does not work with
  Application Gateway v1 (Standard/WAF). The application gateway must
  be created with `--sku WAF_v2` or `--sku Standard_v2`.

  ```bash
  az network application-gateway show \
    --resource-group <rg> --name <appgw> \
    --query "sku.tier" -o tsv
  # Must return: WAF_v2 or Standard_v2
  ```

- **AGIC and existing Application Gateway configuration**: AGIC assumes
  it OWNS the Application Gateway configuration. If the Application
  Gateway already has manually-created listeners, backend pools, or
  rules, AGIC will DELETE them on the next reconciliation loop. Do not
  share an Application Gateway between AGIC and manual configuration.

- **AGIC IngressClass name**: On AKS, the ingress class used by AGIC is
  `azure/application-gateway`, NOT the standard `ingressClassName` field
  on `networking.k8s.io/v1` Ingress. Instead, the annotation
  `kubernetes.io/ingress.class: azure/application-gateway` is used.

- **App Routing addon provisions its own DNS zone**: If you do not
  specify `--dns-zone-resource-id`, the addon creates a new public Azure
  DNS zone in the node resource group (MC_*). This zone is tied to the
  AKS cluster lifecycle — deleting the cluster also deletes the zone.

- **App Routing addon is mutually exclusive with AGIC**: Both addons
  deploy an ingress controller. If both are enabled, they will compete
  for Ingress resources. Choose one per cluster — use App Routing for
  simple nginx-based HTTP routing, and AGIC when you need Application
  Gateway's WAF and L7 features.

- **Azure Policy sync latency**: After assigning an Azure Policy
  definition to the AKS cluster, the Gatekeeper pods in
  `gatekeeper-system` sync every 15 minutes by default. Policy changes
  can take up to 15 minutes to take effect. The smoke-script waits up
  to 20 minutes for the constraint to appear. For immediate testing,
  apply the ConstraintTemplate and Constraint directly via
  `kubectl` (as this scenario does) rather than waiting for Azure
  Policy sync.

- **Azure Policy uses Gatekeeper v3, not OPA**: Azure Policy for AKS
  is built on Gatekeeper v3 with the `templates.gatekeeper.sh/v1` API
  version and Rego language. It is NOT the same as the standalone OPA
  Gatekeeper project (even though the API surface is similar). Custom
  policy definitions must use the `Microsoft.PolicyInsights/policyDefinitions`
  ARM resource, not raw Gatekeeper ConstraintTemplates, when deployed
  through Azure Policy.

- **`hostNetwork` and Azure CNI**: Pods using `hostNetwork: true` bypass
  the Azure CNI and use the node's network namespace directly. This can
  cause port conflicts with AKS system pods (`kube-proxy`,
  `azure-cni-monitor`). The product chart's pods must NOT use
  `hostNetwork: true` for any AKS scenario.

- **Subscription-level RBAC for AGIC**: The AGIC identity needs
  `Contributor` on the Application Gateway scope AND `Reader` on the
  resource group that contains the AKS cluster. Without `Reader` on the
  resource group, AGIC cannot list the Application Gateways it is
  allowed to manage. The `helm install` will appear to succeed but the
  controller logs will show:

  ```
  ERROR: Failed to get Application Gateway <name> in resource group <rg>
  ```

- **Workload Identity annotation is immutable per ServiceAccount**:
  After creating a ServiceAccount with a specific `azure.workload.identity/client-id`,
  changing the annotation does NOT update the OIDC token audience for
  existing Pods. Pods must be recreated to pick up the new annotation:

  ```bash
  kubectl rollout restart deployment/<name> -n <namespace>
  ```

## References

- [AKS documentation](https://learn.microsoft.com/en-us/azure/aks/)
- [Workload Identity for AKS](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [Deploy and configure workload identity](https://learn.microsoft.com/en-us/azure/aks/workload-identity-deploy-cluster)
- [AGIC — Application Gateway Ingress Controller](https://azure.github.io/application-gateway-kubernetes-ingress/)
- [AGIC installation (Helm)](https://azure.github.io/application-gateway-kubernetes-ingress/helm/)
- [App Routing addon](https://learn.microsoft.com/en-us/azure/aks/app-routing)
- [Azure Policy for AKS](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/policy-for-kubernetes)
- [Azure Policy built-in definitions for AKS](https://learn.microsoft.com/en-us/azure/aks/policy-reference)
- [Azure AD federated identity credentials](https://learn.microsoft.com/en-us/azure/active-directory/develop/workload-identity-federation-create-trust)
- [AKS network concepts](https://learn.microsoft.com/en-us/azure/aks/concepts-network)
- [Azure CNI configuration](https://learn.microsoft.com/en-us/azure/aks/configure-azure-cni)
- [Azure Application Gateway documentation](https://learn.microsoft.com/en-us/azure/application-gateway/)
- [AKS best practices](https://learn.microsoft.com/en-us/azure/aks/best-practices)
