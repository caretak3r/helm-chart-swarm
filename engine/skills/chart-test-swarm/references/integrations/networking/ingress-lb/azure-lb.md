# azure-lb

**AUTHORED ONLY — not run from this repo.** The scenarios referenced here are
authored and validated via `kubectl --dry-run=client` and `yamllint` against a
local kind cluster. No `kubectl apply`, `helm install`, or `az` invocation
targets a real AKS cluster from this repository. Apply them yourself to your
own AKS cluster.

## What

Azure Load Balancer integration for AKS provisions Azure Load Balancers
(Standard SKU) from Kubernetes Service and Ingress resources. AKS uses the
Azure Cloud Provider (cloud-controller-manager) to create and manage Azure
Load Balancers automatically when a Service of type `LoadBalancer` is created,
and the Application Gateway Ingress Controller (AGIC) provisions an Azure
Application Gateway from Ingress resources.

Key capabilities:

- **Public Load Balancer** — AKS automatically creates an Azure Standard Load
  Balancer for Services of type `LoadBalancer`. The load balancer distributes
  inbound flows from the internet to backend pool VMs.
- **Internal Load Balancer** — an internal load balancer (ILB) is created when
  the Service annotation `service.beta.kubernetes.io/azure-load-balancer-internal`
  is set to `"true"`. ILBs are not exposed to the internet and are used for
  internal application communication within a VNet.
- **Application Gateway Ingress Controller (AGIC)** — provisions an Azure
  Application Gateway from a Kubernetes Ingress resource. AGIC supports
  path-based routing, TLS termination, cookie affinity, and WAF (Web
  Application Firewall) integration.

These capabilities are AKS-specific. They cannot be exercised on kind or
minikube because they depend on Azure infrastructure (VNets, Load Balancers,
Application Gateway, Azure AD). The scenarios authored for this integration
are **design-only** — they serve as reference implementations that a user
ships to their own AKS cluster.

## Target Kubernetes version

AKS 1.28+ (Standard Load Balancer is the default for AKS 1.20+; AGIC v1.8+
requires AKS 1.22+).

All scenario YAMLs authored under `networking/ingress-lb/` carry an annotation
`chart-test-swarm/target-k8s-version: aks-1.30` to pin the expected Kubernetes
API version.

## When

Use Azure Load Balancer scenarios when the Helm chart under test:

- Must be exposed through an Azure Standard Load Balancer with a public IP
  address for internet-facing workloads.
- Requires an internal load balancer for backend service communication within
  the VNet without exposing endpoints to the internet.
- Uses AGIC to provision an Azure Application Gateway with path-based
  routing, TLS termination via Azure Key Vault certificates, or WAF v2
  protection.
- Must prove that Service annotations
  (`service.beta.kubernetes.io/azure-*`) are correctly templated.

**Do not use** Azure LB scenarios if:

- You need to test TLS certificate lifecycle — use the `cert-manager` *local*
  scenarios instead. Azure LB scenarios assume certificates are provisioned
  via Azure Key Vault or managed by Application Gateway.
- You are testing a service mesh (Istio, Linkerd) — use the `service-mesh/`
  local scenarios.
- You are testing policy enforcement (Gatekeeper, Kyverno) — use the
  `policy/` local scenarios.

## How

This repo does **not** run Azure LB scenarios. They are authored as reference
implementations that you take to your own AKS cluster.

### Application pattern

Every Azure LB scenario follows this two-phase pattern:

**Phase 1 (validation in this repo):**

1. Write the scenario YAML with `cluster.provider: aks`.
2. Validate against `engine/templates/scenario.schema.json`.
3. Run `kubectl --dry-run=client -f` against every embedded manifest snippet.
4. Run `yamllint` on the primer and all scenario YAMLs.

**Phase 2 (you, on your own AKS cluster):**

1. Authenticate to Azure: `az login` and
   `az aks get-credentials --resource-group <rg> --name <cluster>`.
2. Ensure the AKS cluster has Standard Load Balancer or AGIC enabled.
3. Apply the scenario's preinstall items and product chart.
4. Review the emitted `reports/run-*/result.yaml` and artifact bundle.

### Consumer chart wiring

The sample product chart exposes value blocks for Azure LB integration.
Set these values for LB scenarios:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-resource-group: "<REPLACE_WITH_RG_NAME>"
    service.beta.kubernetes.io/azure-load-balancer-internal: "false"

# For AGIC Ingress
ingress:
  enabled: true
  className: azure/application-gateway
  annotations:
    appgw.ingress.kubernetes.io/ssl-redirect: "true"
    appgw.ingress.kubernetes.io/appgw-ssl-certificate: "<REPLACE_WITH_CERT_NAME>"
  hosts:
    - host: "<REPLACE_WITH_DOMAIN_NAME>"
      paths:
        - path: /
          pathType: Prefix
```

All values containing sensitive material carry `<REPLACE_WITH_...>` placeholders.
No real resource group names, certificate identifiers, or Azure tenant IDs are
stored in this repository.

## Credential prerequisites

Before applying any Azure LB scenario to your cluster, you must have the
following Azure credentials and identities in place.

### Azure authentication

```bash
# Authenticate as a user with AKS admin + Network Contributor permissions
az login

# Set the subscription
az account set --subscription "<REPLACE_WITH_SUBSCRIPTION_ID>"

# Verify access
az aks list --output table
```

### AKS cluster admin credentials

```bash
# Get kubeconfig for the AKS cluster
az aks get-credentials \
  --resource-group "<REPLACE_WITH_RG_NAME>" \
  --name "<REPLACE_WITH_CLUSTER_NAME>"

# Verify connection
kubectl get nodes
```

### Managed Identity for AGIC

If using the Application Gateway Ingress Controller, the AKS cluster's
managed identity must have Network Contributor rights on the Application
Gateway's resource group:

```bash
# Get the AKS cluster's managed identity principal ID
AKS_PRINCIPAL_ID=$(az aks show \
  --resource-group "<REPLACE_WITH_RG_NAME>" \
  --name "<REPLACE_WITH_CLUSTER_NAME>" \
  --query identityProfile.kubeletidentity.objectId -o tsv)

# Assign Network Contributor on the App Gateway resource group
az role assignment create \
  --assignee "$AKS_PRINCIPAL_ID" \
  --role "Network Contributor" \
  --scope "<REPLACE_WITH_APPGW_RG_RESOURCE_ID>"
```

### Azure Key Vault certificate (for AGIC TLS)

AGIC can reference TLS certificates stored in Azure Key Vault via the
`appgw.ingress.kubernetes.io/appgw-ssl-certificate` annotation. The Key
Vault must be accessible from the Application Gateway:

```bash
# Upload a certificate to Key Vault (or use an existing one)
az keyvault certificate create \
  --vault-name "<REPLACE_WITH_KV_NAME>" \
  -n "<REPLACE_WITH_CERT_NAME>" \
  -p "$(az keyvault certificate get-default-policy)"

# Note the certificate name for the Ingress annotation
```

Alternatively, use Azure-managed certificates via the
`appgw.ingress.kubernetes.io/appgw-ssl-certificate` annotation referencing
a certificate uploaded directly to the Application Gateway.

## Cluster prerequisites

Every Azure LB scenario expects the following cluster configuration.

### AKS version

**Minimum: AKS 1.28** (Standard Load Balancer default; AGIC v1.8+ support).

```bash
# Create a new AKS cluster matching scenario expectations
az aks create \
  --resource-group "<REPLACE_WITH_RG_NAME>" \
  --name chart-test-swarm-aks \
  --kubernetes-version 1.30.0 \
  --node-count 3 \
  --node-vm-size Standard_D2s_v5 \
  --load-balancer-sku standard \
  --network-plugin azure \
  --generate-ssh-keys
```

### Enable AGIC (Application Gateway Ingress Controller)

AGIC can be enabled during cluster creation or added to an existing cluster:

```bash
# Enable AGIC on an existing AKS cluster with a new Application Gateway
az aks addon enable \
  --resource-group "<REPLACE_WITH_RG_NAME>" \
  --name chart-test-swarm-aks \
  --addon ingress-appgw \
  --appgw-subnet-cidr "10.0.2.0/24"
```

Or install AGIC via Helm on an existing Application Gateway:

```bash
helm repo add application-gateway-kubernetes-ingress \
  https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/
helm repo update

helm install ingress-azure \
  application-gateway-kubernetes-ingress/ingress-azure \
  --set appgw.name="<REPLACE_WITH_APPGW_NAME>" \
  --set appgw.resourceGroup="<REPLACE_WITH_RG_NAME>" \
  --set appgw.subscriptionId="<REPLACE_WITH_SUBSCRIPTION_ID>" \
  --set armAuth.type=aadPodBinding \
  --set armAuth.identityResourceID="<REPLACE_WITH_IDENTITY_RESOURCE_ID>" \
  --set armAuth.identityClientID="<REPLACE_WITH_IDENTITY_CLIENT_ID>"
```

### Required add-ons

| Component | Required for | Installation |
|---|---|---|
| Standard Load Balancer | All LB scenarios | Default on AKS 1.20+ |
| AGIC (Application Gateway Ingress Controller) | AGIC/Ingress scenarios | `az aks addon enable --addon ingress-appgw` or Helm |
| Azure CNI | IP-based load balancing | Default when `--network-plugin azure` |
| Managed Identity | AGIC authentication | Default on AKS 1.22+ |
| Azure Key Vault provider | AGIC TLS from Key Vault | `az aks addon enable --addon azure-keyvault-secrets-provider` |

### VNet networking

All Azure LB scenarios assume **Azure CNI** networking with a dedicated VNet.
Key requirements:

- A subnet with sufficient IP addresses for nodes and pods
- An Application Gateway subnet (for AGIC scenarios) — must be dedicated,
  minimum /24 size
- Network security group allowing inbound traffic on the load balancer
  frontend ports

## Variants

Three scenario variants are authored under
`examples/sample-product-chart/chart-test/scenarios/`. All use
`cluster.provider: aks`, carry `category: networking`, `integration: azure-lb`,
and the `AUTHORED ONLY` banner.

| Variant | File | What it exercises |
|---|---|---|
| public-lb | `networking-azure-lb-public.yaml` | Service type LoadBalancer → Azure Standard LB; public IP |
| internal-lb | `networking-azure-lb-internal.yaml` | Service type LoadBalancer with internal annotation → ILB |
| agic-ingress | `networking-azure-lb-agic.yaml` | Ingress → Application Gateway; TLS; path-based routing |

### public-lb

This variant verifies that AKS provisions a public Azure Standard Load Balancer
from a Service of type LoadBalancer.

**Product chart values:**

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-resource-group: "<REPLACE_WITH_RG_NAME>"
```

**Smoke-script behavior:** Retrieves the public IP from the Service status
(`kubectl get svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`),
then performs an HTTP GET. Expects HTTP 200.

### internal-lb

This variant verifies that AKS provisions an internal load balancer (ILB)
when the Service has the internal annotation.

**Product chart values:**

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
```

**Smoke-script behavior:** Verifies the ILB IP is a private VNet address.
Performs an HTTP GET from within the VNet (via a debug pod). Expects HTTP 200.

### agic-ingress

This variant verifies that the Application Gateway Ingress Controller
provisions an Azure Application Gateway from a Kubernetes Ingress resource.

**Product chart values:**

```yaml
ingress:
  enabled: true
  className: azure/application-gateway
  annotations:
    appgw.ingress.kubernetes.io/ssl-redirect: "true"
    appgw.ingress.kubernetes.io/appgw-ssl-certificate: "<REPLACE_WITH_CERT_NAME>"
```

**Smoke-script behavior:** Retrieves the Application Gateway public IP from
the Ingress status, then performs an HTTPS GET. Expects HTTP 200 and
validates the TLS certificate.

## Assertions

| Type | What it verifies |
|---|---|
| `helm-status-deployed` | Product chart installed successfully |
| `pods-ready` | All product pods Ready |
| `smoke-script` | Per-variant behavior (see variant descriptions) |
| `service-reachable` | LB/AppGW IP resolves and returns HTTP 200 |

**Important:** These assertions are NOT run from this repository. They are
authored for reference and validated structurally (dry-run, yamllint) but never
executed in CI or local test runs.

## Known gotchas

- **Standard SKU Load Balancer is mandatory**: AKS clusters created with the
  Basic SKU load balancer cannot be upgraded to Standard. Create a new cluster
  with `--load-balancer-sku standard`.

- **AGIC requires a dedicated subnet**: The Application Gateway must be
  deployed in its own subnet (minimum /24). This subnet cannot be shared with
  AKS nodes.

- **Internal LB requires VNet peering for cross-VNet access**: If you need to
  reach an ILB from another VNet, the VNets must be peered. The ILB is only
  accessible within its own VNet.

- **AGIC provisioning latency**: An Application Gateway takes 3-5 minutes to
  provision on first creation. Subsequent Ingress updates are faster (~60s)
  because the gateway already exists.

- **AGIC does not support all Ingress features**: AGIC does not support
  `whitelist-source-range` annotation, default backend (catch-all), or
  `ingress.class` values other than `azure/application-gateway`.

- **Managed identity propagation delay**: After assigning a managed identity
  to the AKS cluster, Azure AD propagation may take up to 10 minutes. If
  AGIC fails with authorization errors, wait and retry.

- **Azure CNI IP exhaustion**: With Azure CNI, each pod gets an IP from the
  subnet. Plan subnet size for nodes + pods (e.g., /22 for a 30-node cluster
  with 30 pods per node).

- **App Gateway WAF v2 requires dedicated deployment**: If you need WAF
  capabilities, deploy an Application Gateway v2 with WAF enabled. AGIC
  will use it as the backend. WAF rules are configured on the App Gateway,
  not via Ingress annotations.

## References

- [AKS Load Balancer documentation](https://learn.microsoft.com/azure/aks/load-balancer-standard)
- [Application Gateway Ingress Controller](https://learn.microsoft.com/azure/application-gateway/ingress-controller-overview)
- [AGIC Helm installation](https://github.com/Azure/application-gateway-kubernetes-ingress)
- [AKS internal load balancer](https://learn.microsoft.com/azure/aks/internal-lb)
- [AKS network concepts](https://learn.microsoft.com/azure/aks/concepts-network)
- [Azure Standard Load Balancer](https://learn.microsoft.com/azure/load-balancer/load-balancer-overview)
- [AGIC annotations reference](https://github.com/Azure/application-gateway-kubernetes-ingress/blob/master/docs/annotations.md)
