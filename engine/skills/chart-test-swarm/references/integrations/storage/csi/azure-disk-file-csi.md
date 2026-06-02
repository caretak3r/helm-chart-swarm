# azure-disk-file-csi

**AUTHORED ONLY — not run from this repo.** The scenarios referenced here are
authored and validated via `kubectl --dry-run=client` and `yamllint` against a
local kind cluster. No `kubectl apply`, `helm install`, or `az` invocation
targets a real AKS cluster from this repository. Apply them yourself to your
own AKS cluster.

## What

The Azure Disk CSI and Azure File CSI drivers allow Kubernetes clusters running
on Azure (AKS) to provision, mount, and manage Azure managed disks and Azure
File shares as Kubernetes PersistentVolumes (PVs). They replace the in-tree
Azure volume plugins and support dynamic provisioning via `StorageClass`,
volume snapshots, volume cloning (Disk only), and volume resizing.

Key capabilities:

- **Azure Disk CSI Driver** — provisions Azure managed disks (Premium SSD,
  Standard SSD, Standard HDD, Ultra Disk) as block storage for Kubernetes
  pods. Supports dynamic provisioning, volume snapshots, volume cloning,
  and volume expansion. Best for databases, message queues, and workloads
  requiring low-latency block I/O.

- **Azure File CSI Driver** — provisions Azure File shares (Premium and
  Standard tiers) as shared file storage accessible via SMB/NFS protocols.
  Supports dynamic provisioning and volume expansion. Best for shared
  configuration files, CI/CD workspaces, and workloads requiring
  concurrent read/write access from multiple pods.

These capabilities are AKS-specific. They cannot be exercised on kind or
minikube because they depend on Azure infrastructure (managed disks, storage
accounts, VNets, Azure AD). The scenarios authored for this integration are
**design-only** — they serve as reference implementations that a user ships
to their own AKS cluster.

## Target Kubernetes version

AKS 1.28+ (Azure Disk CSI Driver v1.28+ and Azure File CSI Driver v1.28+
require Kubernetes 1.21+; snapshot support requires the `external-snapshotter`
CRDs).

All scenario YAML authored under `storage/csi/` carry an annotation
`chart-test-swarm/target-k8s-version: aks-1.30` to pin the expected Kubernetes
API version.

## When

Use Azure Disk/File CSI scenarios when the Helm chart under test:

- Requires persistent block storage backed by Azure managed disks (e.g.,
  databases, message queues) — use the Azure Disk CSI scenarios.
- Requires shared file storage accessible by multiple pods concurrently
  (e.g., shared configuration, CI/CD workspaces, web server document roots)
  — use the Azure File CSI scenarios.
- Must prove that `StorageClass` definitions and PVC templates are correctly
  configured for Azure CSI dynamic provisioning.
- Uses volume snapshots for backup workflows and needs to verify that
  `VolumeSnapshot` resources are reconciled by the Azure Disk CSI driver.

**Do not use** Azure CSI scenarios if:

- You need to test local-path or hostPath storage — use local kind scenarios
  with the `local-path-provisioner` instead.
- You are testing NFS storage not backed by Azure Files — NFS CSI is a
  separate integration not covered by this primer.
- You need Ultra Disk low-latency storage — Ultra Disk has specific VM
  series and availability zone requirements; this primer covers Premium SSD
  and Standard SSD only.

## How

This repo does **not** run Azure Disk/File CSI scenarios. They are authored
as reference implementations that you take to your own AKS cluster.

### Application pattern

Every Azure CSI scenario follows this two-phase pattern:

**Phase 1 (validation in this repo):**

1. Write the scenario YAML with `cluster.provider: aks`.
2. Validate against `engine/templates/scenario.schema.json`.
3. Run `kubectl --dry-run=client -f` against every embedded manifest snippet.
4. Run `yamllint` on the primer and all scenario YAMLs.

**Phase 2 (you, on your own AKS cluster):**

1. Authenticate to Azure: `az login` and
   `az aks get-credentials --resource-group <rg> --name <cluster>`.
2. Ensure the AKS cluster has the Azure Disk/File CSI drivers installed.
3. Apply the scenario's preinstall items and product chart.
4. Review the emitted `reports/run-*/result.yaml` and artifact bundle.

### Consumer chart wiring

The sample product chart exposes value blocks for Azure CSI storage. Set
these values for Azure Disk CSI scenarios:

```yaml
darkroom:
  enabled: true
  persistence:
    enabled: true
    storageClassName: "managed-premium"
    accessMode: "ReadWriteOnce"
    size: "10Gi"
```

Or for Azure File CSI scenarios:

```yaml
darkroom:
  enabled: true
  persistence:
    enabled: true
    storageClassName: "azurefile"
    accessMode: "ReadWriteMany"
    size: "10Gi"
```

All values containing sensitive material carry `<REPLACE_WITH_...>` placeholders.
No real resource group names, storage account keys, or Azure tenant IDs are
stored in this repository.

## Credential prerequisites

Before applying any Azure CSI scenario to your cluster, you must have the
following Azure credentials and identities in place.

### Azure authentication

```bash
# Authenticate as a user with AKS admin + Storage Account Contributor permissions
az login

# Set the subscription
az account set --subscription "<REPLACE_WITH_SUBSCRIPTION_ID>"

# Verify access
az aks list --output table
```

### AKS cluster credentials

```bash
# Get kubeconfig for the AKS cluster
az aks get-credentials \
  --resource-group "<REPLACE_WITH_RG_NAME>" \
  --name "<REPLACE_WITH_CLUSTER_NAME>"

# Verify connection
kubectl get nodes
```

### Managed Identity for CSI Drivers

AKS clusters created after January 2023 use managed identity by default.
The CSI drivers' managed identity must have the following roles on the
resource group containing the storage resources:

- **Storage Account Contributor** — for Azure File CSI to manage storage
  accounts and file shares.
- **Virtual Machine Contributor** — for Azure Disk CSI to attach/detach
  managed disks to VMs.
- **Managed Disk Operator** — for Azure Disk CSI to create/delete managed
  disks.

```bash
# Get the AKS cluster's managed identity principal ID
AKS_PRINCIPAL_ID=$(az aks show \
  --resource-group "<REPLACE_WITH_RG_NAME>" \
  --name "<REPLACE_WITH_CLUSTER_NAME>" \
  --query identityProfile.kubeletidentity.objectId -o tsv)

# Assign Storage Account Contributor on the node resource group
NODE_RG=$(az aks show \
  --resource-group "<REPLACE_WITH_RG_NAME>" \
  --name "<REPLACE_WITH_CLUSTER_NAME>" \
  --query nodeResourceGroup -o tsv)

az role assignment create \
  --assignee "$AKS_PRINCIPAL_ID" \
  --role "Storage Account Contributor" \
  --resource-group "$NODE_RG"

az role assignment create \
  --assignee "$AKS_PRINCIPAL_ID" \
  --role "Managed Disk Operator" \
  --resource-group "$NODE_RG"
```

### Bring-your-own-key (BYOK) encryption (optional)

If using customer-managed keys for disk encryption, the CSI driver's managed
identity needs `Key Vault Crypto Service Encryption User` on the key vault:

```bash
# Grant Key Vault access to the AKS managed identity
az keyvault set-policy \
  --name "<REPLACE_WITH_KV_NAME>" \
  --object-id "$AKS_PRINCIPAL_ID" \
  --key-permissions get wrapKey unwrapKey
```

## Cluster prerequisites

Every Azure CSI scenario expects the following cluster configuration.

### AKS version

**Minimum: AKS 1.28** (Azure Disk/File CSI v1.28+; snapshot support).

```bash
# Create a new AKS cluster matching scenario expectations
az aks create \
  --resource-group "<REPLACE_WITH_RG_NAME>" \
  --name chart-test-swarm-aks \
  --kubernetes-version 1.30.0 \
  --node-count 3 \
  --node-vm-size Standard_D2s_v5 \
  --network-plugin azure \
  --generate-ssh-keys
```

### Azure Disk CSI Driver

The Azure Disk CSI Driver is installed by default on AKS 1.21+ clusters
(created after January 2023). Verify it is running:

```bash
kubectl -n kube-system get pods -l app=csi-azuredisk-node
kubectl -n kube-system get pods -l app=csi-azuredisk-controller
```

If the driver is not installed, add it as a managed add-on:

```bash
az aks addon enable \
  --resource-group "<REPLACE_WITH_RG_NAME>" \
  --name chart-test-swarm-aks \
  --addon azure-disk-csi
```

Or install via Helm:

```bash
helm repo add azuredisk-csi-driver https://kubernetes-sigs.github.io/azuredisk-csi-driver
helm repo update

helm install azuredisk-csi-driver azuredisk-csi-driver/azuredisk-csi-driver \
  --namespace kube-system
```

### Azure File CSI Driver

The Azure File CSI Driver is installed by default on AKS 1.21+ clusters.
Verify it is running:

```bash
kubectl -n kube-system get pods -l app=csi-azurefile-node
kubectl -n kube-system get pods -l app=csi-azurefile-controller
```

If the driver is not installed:

```bash
az aks addon enable \
  --resource-group "<REPLACE_WITH_RG_NAME>" \
  --name chart-test-swarm-aks \
  --addon azure-file-csi
```

Or install via Helm:

```bash
helm repo add azurefile-csi-driver https://kubernetes-sigs.github.io/azurefile-csi-driver
helm repo update

helm install azurefile-csi-driver azurefile-csi-driver/azurefile-csi-driver \
  --namespace kube-system
```

### Install snapshot CRDs and controller

Volume snapshot scenarios require the `external-snapshotter` CRDs and
controller:

```bash
# Install snapshot CRDs
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-8.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-8.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-8.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml

# Install the snapshot controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-8.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-8.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

### Required add-ons

| Component | Required for | Installation |
|---|---|---|
| Azure Disk CSI Driver | Disk scenarios | Default on AKS 1.21+ or `az aks addon enable --addon azure-disk-csi` |
| Azure File CSI Driver | File scenarios | Default on AKS 1.21+ or `az aks addon enable --addon azure-file-csi` |
| Managed Identity | All CSI scenarios | Default on AKS 1.22+ |
| Snapshot CRDs + controller | Snapshot scenarios | `kubectl apply -f ...` (see above) |
| Azure CNI | All scenarios | Default when `--network-plugin azure` |

### Default StorageClasses

AKS creates default StorageClasses for Azure Disk and Azure File. Verify
they exist:

```bash
kubectl get storageclass
# Expected: managed-premium, managed-standard, azurefile, azurefile-premium
```

If custom StorageClasses are needed:

```yaml
# Azure Disk - Premium SSD with WaitForFirstConsumer
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-premium-wait
provisioner: disk.csi.azure.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  storageaccounttype: Premium_LRS
  kind: Managed
allowVolumeExpansion: true
```

```yaml
# Azure File - Standard with NFS
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-nfs
provisioner: file.csi.azure.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  protocol: nfs
  skuName: Premium_LRS
allowVolumeExpansion: true
```

## Variants

Three scenario variants are authored under
`examples/sample-product-chart/chart-test/scenarios/`. All use
`cluster.provider: aks`, carry `category: storage`, `integration:
azure-disk-file-csi`, and the `AUTHORED ONLY` banner.

| Variant | File | What it exercises |
|---|---|---|
| disk-dynamic | `storage-azure-disk-csi-dynamic.yaml` | PVC → Azure managed disk provisioning; pod mounts block volume |
| file-shared | `storage-azure-file-csi-shared.yaml` | PVC → Azure File share; multiple pods mount same share (RWX) |
| disk-snapshot | `storage-azure-disk-csi-snapshot.yaml` | VolumeSnapshot → managed disk snapshot; restore from snapshot |

### disk-dynamic

This variant verifies that the Azure Disk CSI Driver dynamically provisions
a managed disk from a PVC using the `managed-premium` StorageClass.

**Product chart values:**

```yaml
darkroom:
  enabled: true
  persistence:
    enabled: true
    storageClassName: "managed-premium"
    accessMode: "ReadWriteOnce"
    size: "10Gi"
```

**Smoke-script behavior:** Verifies the PVC is bound, the pod is running and
has mounted the Azure disk at the expected path, and data can be written and
read from the mounted volume.

### file-shared

This variant verifies that the Azure File CSI Driver dynamically provisions
an Azure File share from a PVC, and that multiple pods can mount the same
share concurrently with `ReadWriteMany` access mode.

**Product chart values:**

```yaml
darkroom:
  enabled: true
  persistence:
    enabled: true
    storageClassName: "azurefile"
    accessMode: "ReadWriteMany"
    size: "10Gi"
```

**Smoke-script behavior:** Deploys a second pod that mounts the same PVC,
writes data from the first pod, reads it from the second pod, and verifies
the data is consistent across both pods.

### disk-snapshot

This variant verifies that the Azure Disk CSI Driver creates a managed disk
snapshot from a `VolumeSnapshot` resource and that a new PVC can be provisioned
from the snapshot.

**Additional preinstall items:**

```yaml
# VolumeSnapshotClass for Azure Disk CSI
kind: raw_manifest
path: chart-test/fixtures/storage/azure-disk-file-csi/volumesnapshotclass.yaml
```

The fixture contains:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: azure-disk-snapclass
driver: disk.csi.azure.com
deletionPolicy: Delete
```

**Smoke-script behavior:** Creates a `VolumeSnapshot` from an existing PVC,
waits for `readyToUse: true`, provisions a new PVC from the snapshot, and
verifies the restored data matches the original.

## Assertions

| Type | What it verifies |
|---|---|
| `helm-status-deployed` | Product chart installed successfully |
| `pods-ready` | All product pods Ready with mounted volumes |
| `smoke-script` | Per-variant behavior (see variant descriptions) |

**Important:** These assertions are NOT run from this repository. They are
authored for reference and validated structurally (dry-run, yamllint) but never
executed in CI or local test runs.

## Known gotchas

- **Azure disks are zone-bound**: A managed disk is created in a specific
  availability zone. A pod can only mount a disk that is in the same zone as
  the node it runs on. Use `volumeBindingMode: WaitForFirstConsumer` in the
  `StorageClass` to ensure the disk is provisioned in the same zone as the
  pod's node.

- **Azure disk attach/detach is slow**: Attaching a managed disk to a VM can
  take 30-60 seconds. During pod scheduling, if the disk needs to be detached
  from one node and attached to another, the pod will be in
  `ContainerCreating` state for up to 5 minutes.

- **Azure File share size limits**: Standard tier Azure File shares have a
  maximum size of 5 TiB (100 GiB by default). Premium tier shares have a
  maximum size of 100 TiB. The `size` in the PVC must not exceed the
  share's provisioned quota.

- **Azure File SMB vs NFS**: Azure File shares can be accessed via SMB
  (default) or NFS protocol. SMB requires storage account keys in a
  Kubernetes Secret (auto-created by the CSI driver). NFS requires the
  storage account to have `protocol: nfs` and the VNet/subnet to allow
  NFS traffic (port 2049).

- **Premium SSD vs Ultra Disk**: Premium SSD disks offer predictable
  low-latency performance for most workloads. Ultra Disk offers sub-millisecond
  latency and configurable IOPS/throughput but requires specific VM series
  (ESv3, DSv3, FSv3) and availability zone support.

- **Volume expansion for Azure File requires CSI driver v1.18+**: The
  Azure File CSI driver v1.18+ supports online volume expansion. For
  earlier versions, the share must be unmounted before expanding.

- **Managed identity propagation delay**: After assigning a managed identity
  to the AKS cluster, Azure AD propagation may take up to 10 minutes. If
  the CSI driver fails with authorization errors, wait and retry.

- **Azure CNI IP exhaustion**: With Azure CNI, each pod gets an IP from the
  subnet. Plan subnet size for nodes + pods (e.g., /22 for a 30-node cluster
  with 30 pods per node).

## References

- [Azure Disk CSI Driver documentation](https://kubernetes-sigs.github.io/azuredisk-csi-driver/)
- [Azure File CSI Driver documentation](https://kubernetes-sigs.github.io/azurefile-csi-driver/)
- [AKS CSI driver installation](https://learn.microsoft.com/azure/aks/csi-storage-drivers)
- [AKS storage concepts](https://learn.microsoft.com/azure/aks/concepts-storage)
- [Azure managed disks](https://learn.microsoft.com/azure/virtual-machines/managed-disks-overview)
- [Azure Files documentation](https://learn.microsoft.com/azure/storage/files/storage-files-introduction)
- [AKS persistent storage best practices](https://learn.microsoft.com/azure/aks/developer-storage-best-practices)
- [Volume snapshots on AKS](https://learn.microsoft.com/azure/aks/azure-disk-csi#volume-snapshots)
