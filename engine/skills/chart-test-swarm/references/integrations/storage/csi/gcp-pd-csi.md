# gcp-pd-csi

**AUTHORED ONLY — not run from this repo.** The scenarios referenced here are
authored and validated via `kubectl --dry-run=client` and `yamllint` against a
local kind cluster. No `kubectl apply`, `helm install`, or `gcloud` invocation
targets a real GKE cluster from this repository. Apply them yourself to your
own GKE cluster.

## What

The GCP Persistent Disk (PD) CSI Driver allows Kubernetes clusters running on
Google Cloud (GKE) to provision, attach, mount, and manage Google Cloud
Persistent Disks (PD) as Kubernetes PersistentVolumes (PVs). It replaces the
in-tree GCE PD volume plugin and supports dynamic provisioning via
`StorageClass`, volume snapshots, volume cloning, volume resizing, and
multi-attach (regional PDs).

Key capabilities:

- **Dynamic provisioning** — automatically creates Persistent Disks from
  `PersistentVolumeClaim` (PVC) resources via `StorageClass` definitions.
  Supports zonal PDs (single zone) and regional PDs (multi-zone replication).
- **Volume snapshots** — creates PD snapshots from `VolumeSnapshot`
  resources using the `external-snapshotter` sidecar, enabling backup and
  disaster recovery workflows.
- **Volume cloning** — creates a new PD from an existing PVC using
  `dataSource` referencing another PVC.
- **Volume expansion** — increases the size of a PD by editing the PVC's
  `resources.requests.storage` field (requires `allowVolumeExpansion: true`
  on the `StorageClass`).
- **Multi-attach with regional PDs** — regional Persistent Disks replicate
  data across two zones in a region, enabling faster failover and
  cross-zone read access.

These capabilities are GKE-specific. They cannot be exercised on kind or
minikube because they depend on GCP infrastructure (Persistent Disks, Compute
Engine, IAM). The scenarios authored for this integration are **design-only**
— they serve as reference implementations that a user ships to their own GKE
cluster.

## Target Kubernetes version

GKE 1.28+ (GKE PD CSI Driver is GA; snapshot support requires the
`external-snapshotter` CRDs; regional PD support on all GKE versions).

All scenario YAML authored under `storage/csi/` carry an annotation
`chart-test-swarm/target-k8s-version: gke-1.30` to pin the expected Kubernetes
API version.

## When

Use GCP PD CSI scenarios when the Helm chart under test:

- Requires persistent storage backed by Google Cloud Persistent Disks (e.g.,
  databases, message queues, file-based caches).
- Must prove that `StorageClass` definitions and PVC templates are correctly
  configured for PD CSI dynamic provisioning.
- Uses volume snapshots for backup workflows and needs to verify that
  `VolumeSnapshot` resources are reconciled.
- Requires regional Persistent Disks for cross-zone redundancy and faster
  failover in regional GKE clusters.
- Must verify volume expansion (resizing PVC capacity) works with the PD
  CSI driver.

**Do not use** GCP PD CSI scenarios if:

- You need to test local-path or hostPath storage — use local kind scenarios
  with the `local-path-provisioner` instead.
- You are testing a service mesh (Istio, Linkerd) — use the `service-mesh/`
  local scenarios.
- You need GCP Filestore (NFS) storage — Filestore CSI is a separate
  integration not covered by this primer.

## How

This repo does **not** run GCP PD CSI scenarios. They are authored as
reference implementations that you take to your own GKE cluster.

### Application pattern

Every GCP PD CSI scenario follows this two-phase pattern:

**Phase 1 (validation in this repo):**

1. Write the scenario YAML with `cluster.provider: gke`.
2. Validate against `engine/templates/scenario.schema.json`.
3. Run `kubectl --dry-run=client -f` against every embedded manifest snippet.
4. Run `yamllint` on the primer and all scenario YAMLs.

**Phase 2 (you, on your own GKE cluster):**

1. Authenticate to GCP: `gcloud auth login` and
   `gcloud container clusters get-credentials <cluster> --region <region>`.
2. Ensure the GKE cluster has the PD CSI driver enabled.
3. Apply the scenario's preinstall items and product chart.
4. Review the emitted `reports/run-*/result.yaml` and artifact bundle.

### Consumer chart wiring

The sample product chart exposes value blocks for GCP PD CSI storage. Set
these values for PD CSI scenarios:

```yaml
darkroom:
  enabled: true
  persistence:
    enabled: true
    storageClassName: "pd-ssd"
    accessMode: "ReadWriteOnce"
    size: "10Gi"
```

Or for regional PD scenarios:

```yaml
darkroom:
  enabled: true
  persistence:
    enabled: true
    storageClassName: "pd-regional-ssd"
    accessMode: "ReadWriteOnce"
    size: "10Gi"
```

All values containing sensitive material carry `<REPLACE_WITH_...>` placeholders.
No real project IDs, zone names, or disk names are stored in this repository.

## Credential prerequisites

Before applying any GCP PD CSI scenario to your cluster, you must have the
following GCP credentials and IAM bindings in place.

### gcloud authentication

```bash
# Authenticate as a user with GKE admin + Compute Storage Admin permissions
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

### IAM roles for PD CSI

The GKE node service account needs the following roles for PD CSI
operations:

- **Compute Storage Admin** (`roles/compute.storageAdmin`) — for creating,
  deleting, and managing Persistent Disks.
- **Compute Viewer** (`roles/compute.viewer`) — for listing zones and
  disk availability.

The default GKE node service account
(`<PROJECT_NUMBER>-compute@developer.gserviceaccount.com`) has
`roles/editor`, which includes these permissions. If using a custom
service account:

```bash
# Grant required roles to the GKE node service account
gcloud projects add-iam-policy-binding <YOUR_GCP_PROJECT_ID> \
  --member "serviceAccount:<SA_EMAIL>" \
  --role "roles/compute.storageAdmin"

gcloud projects add-iam-policy-binding <YOUR_GCP_PROJECT_ID> \
  --member "serviceAccount:<SA_EMAIL>" \
  --role "roles/compute.viewer"
```

### CMEK (Customer-Managed Encryption Key) permissions (optional)

If using customer-managed encryption keys for Persistent Disks, the GKE
node service account needs `Cloud KMS CryptoKey Encrypter/Decrypter` on
the key:

```bash
# Grant KMS access to the GKE node service account
gcloud kms keys add-iam-policy-binding <KEY_NAME> \
  --keyring <KEYRING_NAME> \
  --location <LOCATION> \
  --member "serviceAccount:<SA_EMAIL>" \
  --role "roles/cloudkms.cryptoKeyEncrypterDecrypter"
```

## Cluster prerequisites

Every GCP PD CSI scenario expects the following cluster configuration.

### GKE version

**Minimum: GKE 1.28** (PD CSI Driver GA; snapshot support; regional PDs).

```bash
# Create a new GKE cluster matching scenario expectations
gcloud container clusters create chart-test-swarm-gke \
  --region us-central1 \
  --cluster-version "1.30" \
  --release-channel regular \
  --num-nodes 3 \
  --machine-type e2-standard-4 \
  --addons GcpFilestoreCsiDriver
```

### GCE PD CSI Driver

The GCE PD CSI Driver is enabled by default on GKE 1.25+ clusters using
the `pd-csi` gke-driver. Verify it is running:

```bash
kubectl -n kube-system get pods -l app=gcp-compute-persistent-disk-csi-driver
```

If the driver is not installed, enable it via the GKE add-on:

```bash
gcloud container clusters update <CLUSTER_NAME> \
  --region <REGION> \
  --update-addons=GcePersistentDiskCsiDriver=ENABLED
```

Or install via Helm:

```bash
helm repo add gcp-pd-csi-driver https://kubernetes-sigs.github.io/gcp-compute-persistent-disk-csi-driver
helm repo update

helm install gcp-pd-csi-driver gcp-pd-csi-driver/gcp-compute-persistent-disk-csi-driver \
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
| GCE PD CSI Driver | All PD CSI scenarios | Default on GKE 1.25+ or `gcloud container clusters update --update-addons=GcePersistentDiskCsiDriver=ENABLED` |
| Snapshot CRDs + controller | Snapshot scenarios | `kubectl apply -f ...` (see above) |
| VPC-native networking | All scenarios | Default on GKE 1.27+ |

### StorageClasses for Persistent Disk

GKE provides default StorageClasses. Verify they exist:

```bash
kubectl get storageclass
# Expected: standard (pd-standard), pd-ssd, pd-balanced
```

If custom StorageClasses are needed:

```yaml
# Zonal PD-SSD with WaitForFirstConsumer
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: pd-ssd-wait
provisioner: pd.csi.storage.gke.io
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: pd-ssd
  replication-type: none
allowVolumeExpansion: true
```

```yaml
# Regional PD-SSD for cross-zone redundancy
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: pd-regional-ssd
provisioner: pd.csi.storage.gke.io
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: pd-ssd
  replication-type: regional-pd
allowVolumeExpansion: true
```

## Variants

Three scenario variants are authored under
`examples/sample-product-chart/chart-test/scenarios/`. All use
`cluster.provider: gke`, carry `category: storage`, `integration: gcp-pd-csi`,
and the `AUTHORED ONLY` banner.

| Variant | File | What it exercises |
|---|---|---|
| dynamic-provision | `storage-gcp-pd-csi-dynamic.yaml` | PVC → PD provisioning; pod mounts zonal volume |
| snapshot | `storage-gcp-pd-csi-snapshot.yaml` | VolumeSnapshot → PD snapshot; restore from snapshot |
| regional-pd | `storage-gcp-pd-csi-regional.yaml` | PVC → regional PD; cross-zone redundancy; pod survives zone failure |

### dynamic-provision

This variant verifies that the GCE PD CSI Driver dynamically provisions a
Persistent Disk from a PVC using the `pd-ssd` StorageClass with
`volumeBindingMode: WaitForFirstConsumer`.

**Product chart values:**

```yaml
darkroom:
  enabled: true
  persistence:
    enabled: true
    storageClassName: "pd-ssd"
    accessMode: "ReadWriteOnce"
    size: "10Gi"
```

**Smoke-script behavior:** Verifies the PVC is bound, the pod is running and
has mounted the PD at the expected path, and data can be written and read
from the mounted volume.

### snapshot

This variant verifies that the GCE PD CSI Driver creates a PD snapshot from
a `VolumeSnapshot` resource and that a new PVC can be provisioned from the
snapshot.

**Additional preinstall items:**

```yaml
# VolumeSnapshotClass for GCE PD CSI
kind: raw_manifest
path: chart-test/fixtures/storage/gcp-pd-csi/volumesnapshotclass.yaml
```

The fixture contains:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: pd-snapclass
driver: pd.csi.storage.gke.io
deletionPolicy: Delete
```

**Smoke-script behavior:** Creates a `VolumeSnapshot` from an existing PVC,
waits for `readyToUse: true`, provisions a new PVC from the snapshot, and
verifies the restored data matches the original.

### regional-pd

This variant verifies that the GCE PD CSI Driver provisions a regional
Persistent Disk from a PVC using a StorageClass with
`replication-type: regional-pd`, and that the volume is accessible from
nodes in multiple zones.

**Product chart values:**

```yaml
darkroom:
  enabled: true
  persistence:
    enabled: true
    storageClassName: "pd-regional-ssd"
    accessMode: "ReadWriteOnce"
    size: "10Gi"
```

**Smoke-script behavior:** Verifies the PVC is bound to a regional PD
(references two zones), the pod is running and can mount the volume,
and the disk is replicated across zones. Optionally verifies that the pod
can be rescheduled to a node in a different zone within the region while
maintaining access to the volume.

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

- **Zonal PDs are zone-bound**: A zonal Persistent Disk is created in a
  specific availability zone. A pod can only mount a zonal PD that is in the
  same zone as the node it runs on. Use `volumeBindingMode: WaitForFirstConsumer`
  in the `StorageClass` to ensure the disk is provisioned in the same zone as
  the pod's node.

- **Regional PDs cost 2x zonal PDs**: A regional PD replicates data across
  two zones, doubling the storage cost. Use regional PDs only when
  cross-zone redundancy is required.

- **Regional PDs support `ReadWriteOnce` only**: Regional PDs can be
  attached to nodes in any zone within the region, but they still support
  only the `ReadWriteOnce` access mode. They do NOT support `ReadWriteMany`
  — use GCP Filestore for shared file access.

- **PD attach/detach takes 10-30 seconds**: When a pod is rescheduled to a
  different node, the PD must be detached from the old node and attached to
  the new node. During this time, the pod will be in `ContainerCreating`
  state. This is normal behavior.

- **Volume expansion requires pod restart for filesystem resize**: After
  expanding a PVC, the PD CSI driver resizes the disk at the GCP level.
  The pod must be restarted for the filesystem to reflect the new size.
  The PD CSI driver supports online filesystem expansion on GKE 1.25+.

- **Snapshot restore creates a new disk in the same zone**: A PVC
  provisioned from a `VolumeSnapshot` is created in the same zone as the
  original disk. If the restoring pod is scheduled on a node in a different
  zone, the PVC will remain pending. Use `WaitForFirstConsumer` and
  regional PDs for cross-zone flexibility.

- **CMEK-encrypted disks require KMS permissions**: If the `StorageClass`
  uses a customer-managed encryption key, the GKE node service account must
  have `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key. The default
  Google-managed encryption does not require explicit KMS permissions.

- **pd-balanced is the recommended default**: The `pd-balanced` disk type
  (balanced PD) offers a good balance of performance and cost for most
  workloads. Use `pd-ssd` for latency-sensitive workloads and `pd-standard`
  for bulk/throughput-optimized workloads.

- **GKE default StorageClass is `pd-balanced`**: On GKE 1.26+, the default
  StorageClass uses `pd-balanced` instead of `pd-standard`. Verify with:

  ```bash
  kubectl get storageclass standard -o yaml | grep type
  ```

## References

- [GCE PD CSI Driver documentation](https://kubernetes-sigs.github.io/gcp-compute-persistent-disk-csi-driver/)
- [GKE Persistent Disk CSI driver](https://cloud.google.com/kubernetes-engine/docs/concepts/persistent-volumes)
- [GKE storage classes](https://cloud.google.com/kubernetes-engine/docs/concepts/storage-classes)
- [Dynamic provisioning](https://cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/preexisting-pd)
- [Regional Persistent Disks](https://cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/regional-pd)
- [Volume snapshots](https://cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/volume-snapshots)
- [Volume expansion](https://cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/volume-expansion)
- [Persistent Disk performance](https://cloud.google.com/compute/docs/disks/performance)
- [GKE storage best practices](https://cloud.google.com/kubernetes-engine/docs/best-practices/storage)
