# manual-tls-secret

## What

Manual TLS Secret provisioning is the simplest TLS integration path: a
pre-existing `kubernetes.io/tls` Secret is created in the product namespace
**before** the product chart is installed, and the chart mounts it as a
volume. This pattern represents the case where a consumer already has a TLS
certificate — issued by an external CA, a corporate PKI, or a custom workflow
— and needs to inject it into the Helm chart without relying on an in-cluster
certificate issuer like cert-manager.

For chart-test-swarm, the manual-tls-secret integration validates that the
sample product chart correctly consumes a pre-provisioned TLS Secret when one
is delivered via `raw_manifest` preinstall. The chart does not create,
manage, or renew the Secret; it only mounts it.

## When

Use manual-tls-secret scenarios when:

- The Helm chart under test accepts a `tls.secretName` value and mounts a
  Secret of type `kubernetes.io/tls` into pods.
- You want to validate that the chart can serve HTTPS using an externally
  provided certificate, without depending on cert-manager or any other
  in-cluster issuer.
- You need to exercise specific certificate characteristics (e.g., ECDSA
  keys, multiple Subject Alternative Names) that cert-manager scenarios
  already cover but that differ in delivery mechanism.
- The consumer's real-world workflow ships certificates via Kubernetes
  Secrets rather than `Certificate` CRDs.

**Do not use** manual-tls-secret if:

- The chart is expected to create or manage its own TLS Secret (that is the
  cert-manager pattern).
- You need automatic certificate renewal or lifecycle management.
- The certificate material is delivered via PVC mount, projected volume,
  or CSI driver — use `mounted-tls-certs` for those patterns.

## How

### Consumer chart wiring

The sample product chart accepts the same `tls` value block as the
cert-manager scenarios. The key difference is that the TLS Secret is
**pre-provisioned** by a `raw_manifest` preinstall item, not by a
cert-manager `Certificate` resource.

```yaml
tls:
  enabled: true
  secretName: manual-tls-basic   # matches the pre-provisioned Secret name
  servicePort: 443
```

When `tls.enabled` is `true`, the chart:

1. Creates a ConfigMap with an nginx server block listening on the TLS port.
2. Adds a `tls` volume sourced from the named Secret (with `optional: true`).
3. Mounts the nginx TLS config and the Secret into the pod.
4. Exposes an additional `https` port on the Service.

### Scenario pattern

Every manual-tls-secret scenario follows this pattern:

1. **Preinstall the TLS Secret** (raw_manifest) — a `kind: Secret` with
   `type: kubernetes.io/tls`, containing base64-encoded `tls.crt` and
   `tls.key` data. The Secret manifest lives under
   `chart-test/fixtures/certificates/manual-tls/`.
2. **Install the product chart** with `tls.enabled: true` and the matching
   `tls.secretName`.
3. **Run a smoke-script** that:
   - Verifies the Secret exists with the expected keys.
   - Verifies the certificate properties (SAN count, key algorithm, etc.).
   - Waits for the product pod to become Ready.
   - Queries the product pod over HTTPS.
   - Exits 0 (PASS) or non-zero (FAIL).

### Certificate generation

The certificates used by these scenarios are generated via `openssl` and
stored as PEM files under `chart-test/fixtures/certificates/manual-tls/`.
The Kubernetes Secret manifests are produced from those PEM files using
`kubectl create secret tls --dry-run=client -o yaml`. This ensures that:

- The source PEM files are available for inspection and verification.
- The Secret manifests contain the exact base64 content needed by Kubernetes.
- No inline base64 blobs appear in the scenario YAMLs themselves — the
  raw_manifest `path` field references the fixture.

## Cluster preinstall

The manual-tls-secret scenarios have no Helm-based preinstall dependencies.
The only preinstall step is a `raw_manifest` that applies a pre-built TLS
Secret:

```yaml
kind: raw_manifest
path: chart-test/fixtures/certificates/manual-tls/manual-tls-basic-secret.yaml
namespace: sample
```

The Secret manifest at that path contains:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: manual-tls-basic
  namespace: sample
type: kubernetes.io/tls
data:
  tls.crt: <base64-encoded PEM certificate>
  tls.key: <base64-encoded PEM private key>
```

There is no `ClusterIssuer`, no `Certificate` CRD, and no cert-manager
dependency. The Secret is applied directly to the Kubernetes API server
before the product chart is installed.

## Variants

Three scenario variants are available under
`examples/sample-product-chart/chart-test/scenarios/`:

| Variant | File | Key type | SANs | What it proves |
|---|---|---|---|---|
| basic | `certificates-manual-tls-secret-basic.yaml` | RSA 2048 | 1 (sample.sample.svc) | Pre-provisioned TLS Secret is consumed correctly; HTTPS serves; Secret type is `kubernetes.io/tls` |
| multiple-sans | `certificates-manual-tls-secret-multiple-sans.yaml` | RSA 2048 | 3 (sample.sample.svc, api.sample.sample.svc, admin.sample.sample.svc) | Certificate with multiple Subject Alternative Names is served correctly; all SANs present in peer cert |
| ecdsa | `certificates-manual-tls-secret-ecdsa.yaml` | ECDSA P-256 | 1 (sample.sample.svc) | ECDSA key pair (id-ecPublicKey) is used for TLS; nginx serves HTTPS using the ECDSA key; pods Ready |

## Assertions

Every manual-tls-secret scenario uses three assertion types:

| Type | Purpose |
|---|---|
| `helm-status-deployed` | Confirm the chart release is deployed |
| `pods-ready` | Confirm all pods in the product namespace are Ready |
| `smoke-script` | Verify Secret type/keys, certificate properties, HTTPS serving |

The smoke-script assertions live under
`examples/sample-product-chart/chart-test/assertions/` and are referenced by
`path` from the scenario. Each script receives `RELEASE`, `NAMESPACE`,
`KUBECONFIG`, `KUBE_CONTEXT`, and `PROJECT_DIR` via the environment.

- `manual-tls-basic.sh` — validates Secret type is `kubernetes.io/tls`,
  `tls.crt` and `tls.key` are valid PEM, and HTTPS returns 200.
- `manual-tls-multiple-sans.sh` — validates the certificate has >= 2 DNS
  SAN entries and HTTPS returns 200.
- `manual-tls-ecdsa.sh` — validates the certificate public key algorithm is
  `id-ecPublicKey` (P-256 or P-384 curve) and HTTPS returns 200.

## Known gotchas

- **Secret must exist before pod start**: The Deployment references the TLS
  Secret with `optional: true` so the pod can be scheduled before the Secret
  exists. However, chart-test-swarm's `raw_manifest` preinstall applies the
  Secret before the chart install, so this is rarely an issue. The chart's
  `wait-for-tls` initContainer also polls for the files on disk before the
  nginx container starts.
- **Certificate validity**: The test certificates are generated with a
  365-day validity period and are self-signed by a test CA. They are intended
  for local kind cluster testing only and are not trusted by any public CA.
- **No certificate renewal**: Unlike cert-manager scenarios, these scenarios
  do not exercise certificate lifecycle management. The Secret is static and
  never rotated during the test run.
- **Namespace in Secret manifest**: The Secret manifest YAMLs include
  `metadata.namespace`. The scenario's preinstall item may also specify a
  `namespace` field. Ensure these match; if they diverge, `kubectl apply`
  may produce a warning or error depending on the kubectl version.
- **Private key material**: The PEM private key files under
  `fixtures/certificates/manual-tls/*.key` are test-only ephemeral keys
  generated for local kind cluster testing. They are committed to the
  repository for reproducibility. No production keys or credentials are
  stored here.

## References

- [Kubernetes TLS Secrets](https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets)
- [OpenSSL documentation](https://www.openssl.org/docs/)
- [ECDSA in Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/#external-ca-mode)
