# cert-manager

## What

cert-manager is a Kubernetes addon that automates the management and issuance of TLS
certificates from various issuing sources. It runs as a set of controllers in the
`cert-manager` namespace and watches `Certificate` custom resources, ensuring they
are valid, up-to-date, and renewed before expiry. cert-manager also exposes
`Issuer` / `ClusterIssuer` resources that define how certificates are obtained —
via self-signed CAs, ACME (Let's Encrypt), Vault, Venafi, or external issuers.

For chart-test-swarm, cert-manager is the **primary TLS lifecycle integration**.
Any scenario that needs a TLS certificate issued inside the cluster should use
cert-manager rather than shipping static self-signed material.

## When

Use cert-manager scenarios when the Helm chart under test:

- Exposes a TLS listener and needs a real (or self-signed) certificate for the
  in-cluster Service FQDN.
- Ships its own `Certificate` resources and needs to verify they are issued
  successfully.
- References a `Secret` of type `kubernetes.io/tls` whose name is configurable
  via values, and the scenario must prove the chart can consume a cert-manager
  issued secret.
- Requires CA material for mTLS or client-certificate authentication (the
  cert-manager `Certificate` resource emits `ca.crt` alongside `tls.crt` and
  `tls.key`).

**Do not use** cert-manager if:

- The chart merely tolerates cert-manager CRDs (coexistence) — that is already
  covered by the `with-cert-manager` scenario, which is a lightweight
  coexistence check.
- You are testing TLS material delivered externally (e.g. manually created
  Secrets, mounted certificates from a PVC) — use `manual-tls-secret` or
  `mounted-tls-certs` primers instead.

## How

### Consumer chart wiring

The sample product chart exposes a `tls` value block. Set these values to
enable TLS:

```yaml
tls:
  enabled: true
  secretName: sample-tls          # matches the Certificate spec.secretName
  servicePort: 443
```

When `tls.enabled` is `true`, the chart:

1. Creates a ConfigMap (`<release>-nginx-tls`) with an nginx server block
   listening on the TLS port.
2. Adds a `tls` volume sourced from the named Secret (with `optional: true` so
   the pod can start before the Secret exists).
3. Mounts the nginx TLS config over `/etc/nginx/conf.d`.
4. Exposes an additional `https` port on the Service.

The chart does **not** create `Certificate` or `Issuer` resources itself —
scenarios drive that via `smoke-script` assertions that run after the chart is
installed.

### Scenario pattern

Every cert-manager scenario follows this pattern:

1. **Preinstall cert-manager** (helm) — see the Cluster preinstall section below.
2. **Preinstall a ClusterIssuer** (raw_manifest) — the issuer definition.
3. **Install the product chart** with `tls.enabled: true`.
4. **Run a smoke-script** that:
   - Creates a `Certificate` CR referencing the preinstalled issuer.
   - Waits for `Certificate` condition `Ready=True`.
   - Waits for the product pod to be Ready (the Secret now exists so
     the pod starts).
   - Queries the product pod over HTTPS using `--cacert` from the issued
     Secret's `ca.crt` data key.
   - Exits 0 (PASS) or non-zero (FAIL) with a diagnostic message.

## Cluster preinstall

### cert-manager helm chart

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

The `installCRDs: true` flag is **required** — without it, the `Certificate`
and `Issuer` CRDs are not registered and `kubectl apply` of those resources
will fail.

After this preinstall completes, `cert-manager`, `cert-manager-cainjector`,
and `cert-manager-webhook` pods must be Ready in the `cert-manager` namespace.

### ClusterIssuer (self-signed)

```yaml
kind: raw_manifest
path: chart-test/fixtures/certificates/selfsigned-clusterissuer.yaml
```

The fixture at that path contains:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: chart-test-swarm-selfsigned
spec:
  selfSigned: {}
```

This ClusterIssuer is used by the self-signed-ca and wildcard scenarios.
The lets-encrypt-staging scenario uses a separate ClusterIssuer pointing
at the Let's Encrypt staging ACME endpoint.

## Variants

Four scenario variants are available under
`examples/sample-product-chart/chart-test/scenarios/`:

| Variant | File | Issuer | Key behavior |
|---|---|---|---|
| self-signed-ca | `certificates-cert-manager-self-signed-ca.yaml` | `ClusterIssuer` selfSigned | Issues a `Certificate` for `<release>.<ns>.svc`; verifies HTTPS curl with `--cacert`; SAN matches host |
| lets-encrypt-staging | `certificates-cert-manager-lets-encrypt-staging.yaml` | `ClusterIssuer` ACME Let's Encrypt staging | Uses a staging ACME URL; issues a `Certificate` for the Service FQDN; issuer `Ready=True`; chart pods Ready |
| wildcard | `certificates-cert-manager-wildcard.yaml` | `ClusterIssuer` selfSigned | Issues a wildcard `Certificate` with SAN `DNS:*.test.local` and base domain SAN; `tls.crt` contains both SANs |
| jks-pkcs12 | `certificates-cert-manager-jks-pkcs12.yaml` (optional) | `ClusterIssuer` selfSigned | Issues a `Certificate` and bundles the key material into a JKS or PKCS12 secret alongside `tls.crt` / `tls.key` |

The self-signed-ca variant is the fastest to run (no external ACME
challenge) and serves as the baseline. The lets-encrypt-staging variant
uses the ACME staging endpoint (`https://acme-staging-v02.api.letsencrypt.org/directory`)
and exercises the HTTP-01 challenge solver path, but the resulting
certificate is **not** trusted by any real client — it is a staging
certificate only.

## Assertions

Every cert-manager scenario uses three assertion types:

| Type | Purpose |
|---|---|
| `helm-status-deployed` | Confirm the chart release is deployed |
| `pods-ready` | Confirm all pods in the product namespace are Ready |
| `smoke-script` | Create the `Certificate`, wait for issuance, probe HTTPS |

The smoke-script assertions live under
`examples/sample-product-chart/chart-test/assertions/` and are referenced by
`path` from the scenario. Each script receives `RELEASE`, `NAMESPACE`,
`KUBECONFIG`, `KUBE_CONTEXT`, and `PROJECT_DIR` via the environment.

## Known gotchas

- **CRDs not installed**: If `cert-manager` is installed without
  `installCRDs: true`, the `Certificate` CRD is not registered. Always set
  this flag. The webhook also needs the CRDs to be present before it can
  serve.
- **Webhook not ready**: The cert-manager webhook takes 30–60 seconds on a
  cold kind cluster. The preinstall `wait: pods-ready` with
  `wait_timeout: 3m` handles this. If the webhook is not ready when the
  chart installs, helm errors with "failed calling webhook
  `webhook.cert-manager.io`".
- **Secret not created before pod starts**: The Deployment volume references
  the TLS Secret with `optional: true` so the pod remains Pending (not
  CrashLoopBackOff) until the smoke-script creates the `Certificate` and
  cert-manager issues the Secret. Without `optional: true`, the pod would
  fail repeatedly.
- **ACME HTTP-01 challenge needs a reachable endpoint**: The
  lets-encrypt-staging scenario works out of the box because Let's Encrypt
  staging uses the self-check validation pattern — cert-manager's own
  solver pods respond to the challenge. No ingress controller or external
  DNS is required for the staging endpoint.
- **Certificate duration**: The self-signed and wildcard scenarios use
  `duration: 24h` and `renewBefore: 12h`. For local test runs these are
  intentionally short to exercise the renewal path, though actual renewal
  is not asserted by these scenarios.
- **Previous helm-test pattern is deprecated**: Scenarios authored before
  F3.1 used a helm-test pod to create `Certificate` resources. The
  smoke-script pattern replaces this — it is simpler, easier to debug
  (stdout/stderr captured in logs), and doesn't require RBAC resources
  in the chart's `templates/` directory.

## References

- [cert-manager documentation](https://cert-manager.io/docs/)
- [cert-manager helm chart](https://artifacthub.io/packages/helm/cert-manager/cert-manager)
- [ACME staging environment](https://letsencrypt.org/docs/staging-environment/)
- [Self-signed issuer](https://cert-manager.io/docs/configuration/selfsigned/)
