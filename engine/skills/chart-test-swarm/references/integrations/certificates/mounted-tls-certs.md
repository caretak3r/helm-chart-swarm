# mounted-tls-certs

## What

Mounted TLS certificates is an integration pattern where TLS material (certificate
+ private key) is delivered to the product pod through a Kubernetes volume other
than a simple `Secret` volume. This covers three real-world delivery mechanisms:

1. **PersistentVolumeClaim (PVC)** — TLS material is pre-populated on a
   persistent volume by an external process (e.g. a certificate rotation job,
   an init container copying from a vault sidecar, or a manual operator action),
   and the product pod mounts the PVC.

2. **Projected volume** — Kubernetes' projected volume type combines multiple
   sources (Secrets, ConfigMaps, downward API, service account tokens) into a
   single directory tree. A TLS Secret is projected alongside other configuration
   sources into a unified mount point.

3. **CSI Secret Store** — The Secrets Store CSI Driver (`secrets-store.csi.k8s.io`)
   mounts secrets from external secret management systems (Azure Key Vault, AWS
   Secrets Manager, HashiCorp Vault, GCP Secret Manager) directly into pods as
   a CSI volume. A `SecretProviderClass` CRD defines which secrets to mount and
   how to format them.

For chart-test-swarm, the mounted-tls-certs integration validates that the sample
product chart can consume TLS certificates from each of these volume types, not
just from a direct Kubernetes Secret reference.

## When

Use mounted-tls-certs scenarios when the Helm chart under test:

- Mounts TLS certificates from a persistent volume rather than a Kubernetes
  Secret — common in environments where certificates are managed by an external
  PKI and delivered via shared storage (NFS, CSI, hostPath in development).
- Uses a projected volume to combine the TLS Secret with other projected sources
  (e.g., a ConfigMap for nginx config + a Secret for certs + a service account
  token all under `/etc/tls`).
- Integrates with the Secrets Store CSI Driver to pull certificates from a cloud
  provider's secret management service (Azure Key Vault, AWS Secrets Manager,
  GCP Secret Manager, HashiCorp Vault).
- Needs to validate that the chart's volume mount structure works independently
  of how the TLS material arrives — i.e., the chart only cares about file
  presence at a known path.

**Do not use** mounted-tls-certs if:

- The chart creates or manages its own TLS Secret via cert-manager (use the
  `cert-manager` primer).
- TLS material is delivered as a simple, pre-provisioned Kubernetes Secret
  (use the `manual-tls-secret` primer).
- The chart does not support configurable volume types or mount paths — these
  scenarios require the chart to expose `tls.volumeType` and `tls.mountPath`
  values.

## How

### Consumer chart wiring

The sample product chart exposes the following `tls` value block for volume
flexibility:

```yaml
tls:
  enabled: true
  secretName: my-tls-secret          # name of the Secret (unused for PVC and CSI)
  servicePort: 443
  mountPath: /etc/tls                # filesystem path where certs are mounted
  volumeType: secret                 # one of: secret, persistentVolumeClaim, projected, csi
  pvcClaimName: my-tls-pvc           # required when volumeType is persistentVolumeClaim
  secretProviderClass: my-spc        # required when volumeType is csi
```

When `tls.enabled` is `true`, the chart:

1. Creates a ConfigMap with an nginx server block listing on the TLS port.
2. Adds a `tls` volume to the pod — the volume source depends on `volumeType`:
   - `secret` (default): `secret.secretName` referencing the TLS Secret.
   - `persistentVolumeClaim`: `persistentVolumeClaim.claimName`.
   - `projected`: `projected.sources[]` including the named Secret.
   - `csi`: `csi.driver=secrets-store.csi.k8s.io` with `volumeAttributes.secretProviderClass`.
3. Mounts the `tls` volume at `mountPath` (default `/etc/tls`).
4. Configures nginx `ssl_certificate` and `ssl_certificate_key` to reference
   `<mountPath>/tls.crt` and `<mountPath>/tls.key`.
5. Runs an init container (`wait-for-tls`) that polls for the cert files before
   the nginx container starts.

### Scenario pattern

Each mounted-tls-certs scenario follows this pattern:

1. **Preinstall volume infrastructure** — create the PVC, populate it with certs,
   or create a TLS Secret, or install the CSI driver.
2. **Install the product chart** with `tls.volumeType` set to the target type and
   the supporting values (`pvcClaimName`, `secretProviderClass`, etc.).
3. **Run a smoke-script** that:
   - Verifies the volume source type in the pod spec.
   - Verifies the mount path matches `tls.mountPath`.
   - Waits for the pod to become Ready.
   - Verifies cert files are accessible at the mount path.
   - Probes HTTPS from inside the cluster.
   - Exits 0 (PASS) or non-zero (FAIL).

## Cluster preinstall

### PVC Mount

The PVC scenario requires a PersistentVolumeClaim and a Job that writes TLS
certificates into the PVC before the chart is installed:

```yaml
# Create the PVC
kind: raw_manifest
path: chart-test/fixtures/certificates/mounted-tls/mounted-tls-pvc.yaml
namespace: sample

# Populate the PVC with TLS certs
kind: raw_manifest
path: chart-test/fixtures/certificates/mounted-tls/mounted-tls-populate-job.yaml
namespace: sample
```

The populate Job uses an `alpine/openssl` init container to generate a self-signed
certificate directly into the PVC. After the Job completes, the PVC contains
`tls.crt` and `tls.key` at its root.

### Projected Volume

The projected volume scenario uses a pre-provisioned TLS Secret that gets projected
into the pod:

```yaml
kind: raw_manifest
path: chart-test/fixtures/certificates/mounted-tls/mounted-tls-projected-secret.yaml
namespace: sample
```

The chart's projected volume source references this Secret and maps the
`tls.crt` and `tls.key` keys to the same filenames at the mount point.

### CSI Secret Store

The CSI scenario validates the CSI deployment infrastructure pattern:

1. Installs the Secrets Store CSI Driver via Helm.
2. Creates a stub `SecretProviderClass` resource.
3. Deploys the chart with a pre-provisioned TLS Secret (separate from the CSI
   volume path) so the pod starts successfully on kind.
4. Verifies in the smoke script: CSI daemonset running, `SecretProviderClass`
   exists, pod is healthy with TLS certs, and HTTPS endpoint responds.

```yaml
# Install the CSI driver
kind: helm
chart: secrets-store-csi-driver/secrets-store-csi-driver
version: 1.4.8
release: csi-secrets-store
namespace: kube-system
repo:
  name: secrets-store-csi-driver
  url: "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
values:
  syncSecret:
    enabled: true
  enableSecretRotation: false
wait: pods-ready
wait_timeout: 5m

# Create the SecretProviderClass stub
kind: raw_manifest
path: chart-test/fixtures/certificates/mounted-tls/mounted-tls-csi-secretproviderclass.yaml
namespace: sample

# Pre-provision a TLS secret (so the pod can start on kind)
kind: raw_manifest
path: chart-test/fixtures/certificates/mounted-tls/mounted-tls-csi-tls-secret.yaml
namespace: sample
```

**Note on CSI on kind:** Full CSI volume-mount verification (`csi.driver=secrets-store.csi.k8s.io`
in the pod spec, cert files populated by the CSI provider) requires a real CSI
provider plugin (e.g., AWS Secrets Manager, GCP Secret Manager, Azure Key Vault,
or HashiCorp Vault) which is not available on kind clusters. The scenario
verifies CSI infrastructure deployment (driver + SPC) and documents that full
volume-mount verification is a SKIP on kind. For complete CSI testing, run this
scenario on a cluster with a supported provider plugin installed.

## Variants

Three scenario variants are available under
`examples/sample-product-chart/chart-test/scenarios/`:

| Variant | File | Volume type | Key behavior |
|---|---|---|---|
| pvc-mount | `certificates-mounted-tls-certs-pvc-mount.yaml` | `persistentVolumeClaim` | PVC populated by a Job; chart mounts PVC as TLS volume; `stat /etc/tls/tls.crt` succeeds; HTTPS 200 |
| projected-volume | `certificates-mounted-tls-certs-projected-volume.yaml` | `projected` | TLS Secret projected into pod alongside other sources; pod spec shows `projected.sources[].secret`; HTTPS 200 |
| csi-secret-store | `certificates-mounted-tls-certs-csi-secret-store.yaml` | `secret` (CSI infra verified separately) | CSI driver installed; `SecretProviderClass` created; pod runs with pre-provisioned TLS secret; full CSI volume-mount verification documented as SKIP on kind |

## Assertions

Every mounted-tls-certs scenario uses three assertion types:

| Type | Purpose |
|---|---|
| `helm-status-deployed` | Confirm the chart release is deployed |
| `pods-ready` | Confirm all pods in the product namespace are Ready |
| `smoke-script` | Verify volume source type, mount path, cert file accessibility, HTTPS serving |

The smoke-script assertions live under
`examples/sample-product-chart/chart-test/assertions/` and are referenced by
`path` from the scenario. Each script receives `RELEASE`, `NAMESPACE`,
`KUBECONFIG`, `KUBE_CONTEXT`, and `PROJECT_DIR` via the environment.

- `mounted-tls-pvc-mount.sh` — validates PVC binding, persistentVolumeClaim volume
  source, mount path match, cert file stat, and HTTPS serving.
- `mounted-tls-projected-volume.sh` — validates projected volume with secret source,
  mount path match, cert file stat, and HTTPS serving.
- `mounted-tls-csi-secret-store.sh` — validates CSI driver daemonset,
  SecretProviderClass existence, pod health, TLS cert file accessibility,
  and HTTPS serving. Documents full CSI volume-mount verification as a
  SKIP on kind (no real provider plugin available).

## Known gotchas

- **Volume type must match preinstall**: The chart's `tls.volumeType` value must
  match the preinstall infrastructure. Setting `volumeType: persistentVolumeClaim`
  without first creating a PVC will cause the pod to fail scheduling.
- **PVC needs a provisioner**: On kind clusters, the standard `hostPath`
  provisioner is used for PVCs. The PVC must use `storage: 10Mi` and
  `accessModes: [ReadWriteOnce]`. No special StorageClass is needed.
- **Populate Job must complete before chart install**: The scenario preinstall
  order ensures the Job completes before the chart is installed. If the Job
  fails, the PVC will be empty and the pod's init container will wait
  indefinitely for cert files.
- **Projected volume permissions**: Projected volumes mount with default
  permissions (0644 for files, 0755 for directories by default). If the nginx
  process runs as a non-root user, set `defaultMode` in the projected volume
  spec.
- **CSI driver requires host mounts**: The `secrets-store-csi-driver` mounts
  host paths into its DaemonSet pods. On kind, this works with the default
  security context. On more restrictive clusters (OpenShift, PodSecurityPolicy),
  additional `securityContext` configuration may be needed.
- **CSI stub provider**: The scenario's `SecretProviderClass` uses `provider: fake`
  — a non-functional stub. The scenario verifies CSI infrastructure deployment
  (driver daemonset + SPC resource) but uses a pre-provisioned TLS Secret for the
  actual pod volume, since CSI volume mounts cannot complete without a real
  provider plugin. Real CSI testing requires installing a provider-specific
  plugin (e.g., `azure-secrets-store` for Azure Key Vault) and changing
  `tls.volumeType` to `csi`.
- **Mount path in nginx config**: The chart's nginx ConfigMap references
  `ssl_certificate` and `ssl_certificate_key` paths relative to `tls.mountPath`.
  If you change `tls.mountPath`, ensure the file names `tls.crt` and `tls.key`
  are correct — the chart assumes these exact filenames regardless of mount path.
- **htpasswd/secretName for non-secret volumes**: When `volumeType` is not
  `secret`, the `tls.secretName` field is unused for the volume source but may
  still be required by the chart for other purposes (e.g., labeling). Set it to a
  descriptive placeholder.

## References

- [Kubernetes Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Kubernetes Projected Volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
- [Secrets Store CSI Driver](https://secrets-store-csi-driver.sigs.k8s.io/)
- [SecretProviderClass CRD](https://secrets-store-csi-driver.sigs.k8s.io/concepts.html#secretproviderclass)
- [Azure Key Vault Provider for Secrets Store CSI Driver](https://azure.github.io/secrets-store-csi-driver-provider-azure/)
- [AWS Secrets Manager Provider for Secrets Store CSI Driver](https://github.com/aws/secrets-store-csi-driver-provider-aws)
