# aws-ebs-csi

**AUTHORED ONLY — not run from this repo.** The scenarios referenced here are
authored and validated via `kubectl --dry-run=client` and `yamllint` against a
local kind cluster. No `kubectl apply`, `helm install`, or `aws` invocation
targets a real EKS cluster from this repository. Apply them yourself to your
own EKS cluster.

## What

The AWS EBS CSI (Container Storage Interface) Driver allows Kubernetes clusters
running on AWS to provision, attach, mount, and manage Amazon Elastic Block
Store (EBS) volumes as Kubernetes PersistentVolumes (PVs). It replaces the
in-tree AWS EBS volume plugin and supports dynamic provisioning via
`StorageClass`, volume snapshots, volume cloning, and volume resizing.

Key capabilities:

- **Dynamic provisioning** — automatically creates EBS volumes from
  `PersistentVolumeClaim` (PVC) resources via `StorageClass` definitions.
  Volumes are provisioned in the same AWS region and availability zone as
  the node running the pod.
- **Volume snapshots** — creates EBS snapshots from `VolumeSnapshot`
  resources, enabling backup and disaster recovery workflows.
- **Volume cloning** — creates a new EBS volume from an existing PVC using
  `dataSource` referencing another PVC.
- **Volume expansion** — increases the size of an EBS volume by editing the
  PVC's `resources.requests.storage` field (requires `allowVolumeExpansion: true`
  on the `StorageClass`).

These capabilities are EKS-specific. They cannot be exercised on kind or
minikube because they depend on AWS infrastructure (EBS, EC2, IAM). The
scenarios authored for this integration are **design-only** — they serve as
reference implementations that a user ships to their own EKS cluster.

## Target Kubernetes version

EKS 1.28+ (AWS EBS CSI Driver v1.26+ requires Kubernetes 1.23+; snapshot
support requires the `external-snapshotter` sidecar and CRDs).

All scenario YAMLs authored under `storage/csi/` carry an annotation
`chart-test-swarm/target-k8s-version: eks-1.30` to pin the expected Kubernetes
API version.

## When

Use AWS EBS CSI scenarios when the Helm chart under test:

- Requires persistent storage backed by AWS EBS volumes (e.g., databases,
  message queues, file-based caches).
- Must prove that `StorageClass` definitions and PVC templates are correctly
  configured for EBS CSI dynamic provisioning.
- Uses volume snapshots for backup workflows and needs to verify that
  `VolumeSnapshot` and `VolumeSnapshotContent` resources are reconciled.
- Requires volume resizing (expanding PVC capacity) and must verify the
  EBS CSI driver supports `allowVolumeExpansion`.

**Do not use** AWS EBS CSI scenarios if:

- You need to test local-path or hostPath storage — use local kind scenarios
  with the `local-path-provisioner` instead.
- You are testing a service mesh (Istio, Linkerd) — use the `service-mesh/`
  local scenarios.
- You are testing NFS or EFS storage — EFS CSI is a separate integration
  not covered by this primer.

## How

This repo does **not** run AWS EBS CSI scenarios. They are authored as
reference implementations that you take to your own EKS cluster.

### Application pattern

Every AWS EBS CSI scenario follows this two-phase pattern:

**Phase 1 (validation in this repo):**

1. Write the scenario YAML with `cluster.provider: eks`.
2. Validate against `engine/templates/scenario.schema.json`.
3. Run `kubectl --dry-run=client -f` against every embedded manifest snippet.
4. Run `yamllint` on the primer and all scenario YAMLs.

**Phase 2 (you, on your own EKS cluster):**

1. Authenticate to AWS: `aws configure` and
   `aws eks update-kubeconfig --region <region> --name <cluster>`.
2. Install the AWS EBS CSI Driver via the EKS managed add-on or Helm.
3. Apply the scenario's preinstall items and product chart.
4. Review the emitted `reports/run-*/result.yaml` and artifact bundle.

### Consumer chart wiring

The sample product chart exposes value blocks for EBS CSI storage. Set these
values for EBS CSI scenarios:

```yaml
darkroom:
  enabled: true
  persistence:
    enabled: true
    storageClassName: "ebs-sc"
    accessMode: "ReadWriteOnce"
    size: "10Gi"
```

All values containing sensitive material carry `<REPLACE_WITH_...>` placeholders.
No real AWS account IDs, ARNs, or access keys are stored in this repository.

## Credential prerequisites

Before applying any AWS EBS CSI scenario to your cluster, you must have the
following AWS credentials and IAM bindings in place.

### AWS authentication

```bash
# Configure AWS credentials (requires IAM user with EKS + EC2 admin permissions)
aws configure

# Or assume a role (recommended for CI/CD)
aws sts assume-role \
  --role-arn "arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME>" \
  --role-session-name "chart-test-swarm-aws-ebs-csi"

# Verify access
aws eks list-clusters --region <REGION>
```

### IRSA for the EBS CSI Driver

The EBS CSI Driver uses IRSA (IAM Roles for Service Accounts) to authenticate
with the AWS API for EBS volume management. Create the IAM policy and service
account:

```bash
# Create the IAM policy for the EBS CSI Driver
cat <<'EOF' > ebs-csi-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:AttachVolume",
        "ec2:CreateSnapshot",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:DeleteSnapshot",
        "ec2:DeleteTags",
        "ec2:DeleteVolume",
        "ec2:DescribeSnapshots",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DescribeInstances",
        "ec2:DetachVolume"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name AWSEBSCSIDriverIAMPolicy \
  --policy-document file://ebs-csi-policy.json

# Create the IRSA service account for the EBS CSI Driver
eksctl create iamserviceaccount \
  --cluster <CLUSTER_NAME> \
  --namespace kube-system \
  --name ebs-csi-controller-sa \
  --attach-policy-arn "arn:aws:iam::<ACCOUNT_ID>:policy/AWSEBSCSIDriverIAMPolicy" \
  --region <REGION> \
  --approve
```

Confirm the binding is active:

```bash
kubectl -n kube-system describe sa ebs-csi-controller-sa
# Should show annotation: eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/...
```

### KMS key for encrypted volumes (optional)

If using encrypted EBS volumes, the EBS CSI Driver's IAM role needs
`kms:Decrypt` and `kms:GenerateDataKeyWithoutPlaintext` permissions on the
KMS key:

```bash
# Create a KMS key for EBS encryption
aws kms create-key --description "EBS CSI volume encryption key" --region <REGION>

# Add KMS permissions to the EBS CSI driver policy
aws iam put-role-policy \
  --role-name <EBS_CSI_IAM_ROLE_NAME> \
  --policy-name EBS-CSIKMSPolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "kms:Decrypt",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:CreateGrant"
        ],
        "Resource": "<REPLACE_WITH_KMS_KEY_ARN>"
      }
    ]
  }'
```

## Cluster prerequisites

Every AWS EBS CSI scenario expects the following cluster configuration.

### EKS version

**Minimum: EKS 1.28** (EBS CSI Driver v1.26+; snapshot support).

```bash
# Create a new EKS cluster matching scenario expectations
eksctl create cluster \
  --name chart-test-swarm-eks \
  --region us-west-2 \
  --version 1.30 \
  --nodegroup-name standard-workers \
  --node-type t3.medium \
  --nodes 3 \
  --nodes-min 1 \
  --nodes-max 6 \
  --with-oidc \
  --managed
```

### Install the AWS EBS CSI Driver

Install via the EKS managed add-on (recommended):

```bash
# Install the EBS CSI Driver as a managed add-on
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster <CLUSTER_NAME> \
  --service-account-role-arn "arn:aws:iam::<ACCOUNT_ID>:role/<EBS_CSI_ROLE_NAME>" \
  --force
```

Or install via Helm:

```bash
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=ebs-csi-controller-sa
```

### Install snapshot CRDs and controller

Volume snapshot scenarios require the `external-snapshotter` CRDs and controller:

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
| AWS EBS CSI Driver v1.26+ | All EBS CSI scenarios | `eksctl create addon --name aws-ebs-csi-driver` or Helm |
| IRSA OIDC provider | All EBS CSI scenarios | `eksctl utils associate-iam-oidc-provider` |
| Snapshot CRDs + controller | Snapshot scenarios | `kubectl apply -f ...` (see above) |
| CoreDNS + kube-proxy | All scenarios | Included in EKS managed add-ons |

### StorageClass for EBS

Create a `StorageClass` for dynamic provisioning:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-sc
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  encrypted: "true"
allowVolumeExpansion: true
```

## Variants

Three scenario variants are authored under
`examples/sample-product-chart/chart-test/scenarios/`. All use
`cluster.provider: eks`, carry `category: storage`, `integration: aws-ebs-csi`,
and the `AUTHORED ONLY` banner.

| Variant | File | What it exercises |
|---|---|---|
| dynamic-provision | `storage-aws-ebs-csi-dynamic.yaml` | PVC → EBS volume provisioning; pod mounts volume |
| snapshot | `storage-aws-ebs-csi-snapshot.yaml` | VolumeSnapshot → EBS snapshot creation; restore from snapshot |
| resize | `storage-aws-ebs-csi-resize.yaml` | PVC expansion → EBS volume resize; pod remounts expanded volume |

### dynamic-provision

This variant verifies that the EBS CSI Driver dynamically provisions an EBS
volume from a PVC using a `StorageClass` with `volumeBindingMode: WaitForFirstConsumer`.

**Product chart values:**

```yaml
darkroom:
  enabled: true
  persistence:
    enabled: true
    storageClassName: "ebs-sc"
    accessMode: "ReadWriteOnce"
    size: "10Gi"
```

**Smoke-script behavior:** Verifies the PVC is bound, the pod is running and
has mounted the volume at the expected path, and data can be written and
read from the mounted volume.

### snapshot

This variant verifies that the EBS CSI Driver creates an EBS snapshot from
a `VolumeSnapshot` resource and that a new PVC can be provisioned from the
snapshot.

**Additional preinstall items:**

```yaml
# VolumeSnapshotClass for EBS CSI
kind: raw_manifest
path: chart-test/fixtures/storage/aws-ebs-csi/volumesnapshotclass.yaml
```

The fixture contains:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ebs-snapclass
driver: ebs.csi.aws.com
deletionPolicy: Delete
```

**Smoke-script behavior:** Creates a `VolumeSnapshot` from an existing PVC,
waits for `readyToUse: true`, provisions a new PVC from the snapshot, and
verifies the restored data matches the original.

### resize

This variant verifies that the EBS CSI Driver supports volume expansion
when the `StorageClass` has `allowVolumeExpansion: true`.

**Product chart values:**

```yaml
darkroom:
  enabled: true
  persistence:
    enabled: true
    storageClassName: "ebs-sc"
    accessMode: "ReadWriteOnce"
    size: "10Gi"
```

**Smoke-script behavior:** Patches the PVC to increase `resources.requests.storage`
from 10Gi to 20Gi, waits for the volume to be resized, verifies the pod's
filesystem reflects the new size, and confirms the PVC status shows the
updated capacity.

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

- **EBS volumes are zone-bound**: An EBS volume is created in a specific
  availability zone. A pod can only mount a volume that is in the same zone
  as the node it runs on. Use `volumeBindingMode: WaitForFirstConsumer` in
  the `StorageClass` to ensure the volume is provisioned in the same zone
  as the pod's node.

- **EBS volume attach/detach takes 5-10 seconds**: When a pod is scheduled
  to a new node, the EBS volume must be detached from the old node and
  attached to the new node. During this time, the pod will be in
  `ContainerCreating` state. This is normal behavior.

- **Volume expansion requires pod restart for filesystem resize**: After
  expanding a PVC, the EBS CSI driver resizes the volume at the AWS level.
  However, the filesystem inside the pod does not automatically expand.
  The pod must be restarted (or the `fsResize` option must be enabled in
  the CSI driver) for the filesystem to reflect the new size. The EBS CSI
  driver v1.26+ supports automatic filesystem expansion.

- **Snapshot restore creates a new volume in the same zone**: A PVC
  provisioned from a `VolumeSnapshot` is created in the same AZ as the
  original volume. If the restoring pod is scheduled on a node in a
  different AZ, the PVC will remain pending. Use
  `volumeBindingMode: WaitForFirstConsumer` and ensure the snapshot restore
  workflow accounts for zone matching.

- **IRSA credential propagation requires pod restart**: After creating or
  modifying the IRSA service account for the EBS CSI driver, existing
  controller pods must be restarted for the new IAM role to take effect.

- **gp3 volume type is recommended over gp2**: The `gp3` volume type offers
  higher baseline performance (3000 IOPS, 125 MiB/s throughput) at a lower
  cost than `gp2`. Use `parameters.type: gp3` in the `StorageClass`.

- **EBS CSI Driver node selection**: The EBS CSI DaemonSet (node driver)
  must run on every worker node. If using custom node labels or taints,
  ensure the DaemonSet tolerations and node selector are compatible.

- **Encrypted volumes require KMS permissions**: If the `StorageClass` has
  `encrypted: "true"`, the EBS CSI driver's IAM role must have `kms:Decrypt`
  and `kms:GenerateDataKeyWithoutPlaintext` permissions on the KMS key used
  for encryption. The default AWS managed key (`aws/ebs`) does not require
  explicit KMS permissions.

## References

- [AWS EBS CSI Driver documentation](https://kubernetes-sigs.github.io/aws-ebs-csi-driver/)
- [EKS EBS CSI Driver installation](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [EBS CSI Driver IAM policy](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi-iam-policy.html)
- [Dynamic provisioning](https://kubernetes-sigs.github.io/aws-ebs-csi-driver/usage/dynamic-provisioning/)
- [Volume snapshots](https://kubernetes-sigs.github.io/aws-ebs-csi-driver/usage/volume-snapshot/)
- [Volume expansion](https://kubernetes-sigs.github.io/aws-ebs-csi-driver/usage/volume-expansion/)
- [EBS volume types](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-volume-types.html)
- [EKS storage best practices](https://aws.github.io/aws-eks-best-practices/storage/)
