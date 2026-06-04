## Area: Certificates

Coverage: F3.1 cert-manager primer + variants, F3.2 manual-tls-secret primer + variants,
F3.3 mounted-tls-certs primer + variants, F3.4 shared certificates fixture set under
`examples/sample-product-chart/chart-test/fixtures/certificates/`.

All cluster operations referenced below run on a cluster whose name matches
`^chart-test-swarm-[a-z0-9-]+$` (per the mission's hard constraint). Scenario YAMLs live
under `examples/sample-product-chart/chart-test/scenarios/` and are validated against
`engine/templates/scenario.schema.json`.

### Structural / artifact assertions (per integration)

### VAL-CERT-001: cert-manager primer exists with required sections
The primer file at `engine/skills/chart-test-swarm/references/integrations/certificates/cert-manager.md` exists, is non-empty, and contains a non-empty `## Cluster preinstall` section plus a section explaining *what* the integration does, *when* to use it, and *how* the consumer chart wires the resulting Secret into pods (mount + env vars).
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/certificates/cert-manager.md`), terminal-output of `grep -c '^## ' engine/skills/chart-test-swarm/references/integrations/certificates/cert-manager.md` (≥ 3)

### VAL-CERT-002: cert-manager scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/certificates-cert-manager-*.yaml`, covering self-signed-ca, lets-encrypt-staging, wildcard, and (optionally) jks-pkcs12. Each file's `id` field matches its filename stem.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/certificates-cert-manager-*.yaml | wc -l` ≥ 3, file paths listed

### VAL-CERT-003: manual-tls-secret primer exists with required sections
The primer file at `engine/skills/chart-test-swarm/references/integrations/certificates/manual-tls-secret.md` exists, is non-empty, and documents what manual TLS Secret provisioning is, when a consumer ships a chart against a pre-existing TLS Secret, and how the scenario delivers the Secret via a `raw_manifest` preinstall item.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/certificates/manual-tls-secret.md`), terminal-output of `grep -E '^## (What|When|How|Cluster preinstall)' engine/skills/chart-test-swarm/references/integrations/certificates/manual-tls-secret.md` returns ≥ 3 matches

### VAL-CERT-004: manual-tls-secret scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-*.yaml`, covering basic, multiple-sans, and ecdsa variants. Each file's `id` matches its filename stem.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-*.yaml | wc -l` ≥ 3

### VAL-CERT-005: mounted-tls-certs primer exists with required sections
The primer at `engine/skills/chart-test-swarm/references/integrations/certificates/mounted-tls-certs.md` exists, is non-empty, and documents what mounted-TLS-from-volume is, when to use it (PVC vs projected vs CSI secret-store), and how the consumer chart references the mounted path.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/certificates/mounted-tls-certs.md`), terminal-output of `grep -c '^## ' engine/skills/chart-test-swarm/references/integrations/certificates/mounted-tls-certs.md` ≥ 3

### VAL-CERT-006: mounted-tls-certs scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/certificates-mounted-tls-certs-*.yaml`, covering pvc-mount, projected-volume, and csi-secret-store variants.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/certificates-mounted-tls-certs-*.yaml | wc -l` ≥ 3

### Variant execution assertions (cert-manager)

### VAL-CERT-007: cert-manager self-signed-ca scenario runs PASS
Running `bash engine/scripts/run-scenario.sh examples/sample-product-chart/chart-test/scenarios/certificates-cert-manager-self-signed-ca.yaml` against a `chart-test-swarm-<test-id>` kind cluster results in `status: PASS`. The cluster shows: a `cert-manager` namespace with controller + webhook + cainjector pods Ready; a `ClusterIssuer` of type `selfSigned`; a `Certificate` whose `Ready` condition is `True`; and a TLS `Secret` containing `tls.crt`, `tls.key`, and `ca.crt` data keys.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-cert-manager-self-signed-ca-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get certificate -n sample -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}'` == `True`), kubectl-output(`kubectl get secret sample-tls -n sample -o json | jq -r '.data | keys[]' | sort` produces lines `ca.crt`, `tls.crt`, `tls.key`)

### VAL-CERT-008: cert-manager self-signed-ca serves HTTPS with matching SAN
After the self-signed-ca scenario installs the chart, an in-cluster `curl` against the product Service over HTTPS using `--cacert` pointing at the issuer's CA succeeds with HTTP `200`, and the served peer certificate's Subject Alternative Names include the host the chart was configured to serve (e.g. `sample.sample.svc.cluster.local`).
Tool: curl
Evidence: curl-response(headers: `HTTP/1.1 200`, body: matches expected probe response), terminal-output of `openssl s_client -connect <pod-ip>:443 -servername sample.sample.svc.cluster.local </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName` includes `DNS:sample.sample.svc.cluster.local`

### VAL-CERT-009: cert-manager lets-encrypt-staging scenario runs PASS
Running the `certificates-cert-manager-lets-encrypt-staging.yaml` scenario via `run-scenario.sh` results in `status: PASS`. The scenario uses a `staging` ACME server URL (so no real ACME challenge is solved against production). The scenario either uses the `selfSigned` issuer for offline behavior or stubs out the ACME challenge; the assertion verifies that the `Issuer`/`ClusterIssuer` resource is `Ready: True` and the chart pods are Ready.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-cert-manager-lets-encrypt-staging-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get clusterissuer -o jsonpath='{.items[?(@.metadata.name=="letsencrypt-staging")].status.conditions[?(@.type=="Ready")].status}'` == `True`)

### VAL-CERT-010: cert-manager wildcard scenario issues *.test.local certificate
Running the `certificates-cert-manager-wildcard.yaml` scenario via `run-scenario.sh` results in `status: PASS`. The issued TLS Secret's certificate has SAN `DNS:*.test.local` (or the documented wildcard host) and a sibling literal SAN for the base domain.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-cert-manager-wildcard-*/result.yaml`) with `status: PASS`, terminal-output of `kubectl get secret <wildcard-secret> -n sample -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName` includes `DNS:*.test.local`

### VAL-CERT-011: cert-manager jks-pkcs12 secret contains keystore + truststore (optional 4th variant)
If the scenario `certificates-cert-manager-jks-pkcs12.yaml` is present, running it via `run-scenario.sh` produces `status: PASS` and the resulting Secret contains data keys `keystore.jks` and `truststore.jks` (or `keystore.p12`) in addition to `tls.crt` / `tls.key`. If the variant file is not authored, this assertion is marked N/A.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-cert-manager-jks-pkcs12-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get secret -n sample <jks-secret> -o json | jq -r '.data | keys[]' | sort`) includes both `tls.crt` and either `keystore.jks` or `keystore.p12`

### Variant execution assertions (manual-tls-secret)

### VAL-CERT-012: manual-tls-secret basic scenario delivers Secret via raw_manifest preinstall
Running `certificates-manual-tls-secret-basic.yaml` via `run-scenario.sh` results in `status: PASS`. The scenario's `cluster.preinstall` list includes at least one item with `kind: raw_manifest` (per F1.2) whose `path` resolves to a manifest containing a `kind: Secret` with `type: kubernetes.io/tls` and base64-encoded `tls.crt` + `tls.key`. After the run, the Secret is present in the product namespace with both keys populated.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-manual-tls-secret-basic-*/result.yaml`) with `status: PASS`, file(`examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-basic.yaml`) contains `kind: raw_manifest`, kubectl-output(`kubectl get secret <manual-tls-name> -n sample -o jsonpath='{.type}'` == `kubernetes.io/tls`)

### VAL-CERT-013: manual-tls-secret-multiple-sans certificate has all declared SANs
Running `certificates-manual-tls-secret-multiple-sans.yaml` via `run-scenario.sh` results in `status: PASS`. The certificate inside the manually-delivered TLS Secret has at least 2 SAN entries (e.g. `DNS:sample.test.local` AND `DNS:api.sample.test.local`).
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-manual-tls-secret-multiple-sans-*/result.yaml`) with `status: PASS`, terminal-output of `kubectl get secret -n sample <secret-name> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName | grep -c DNS:` ≥ 2

### VAL-CERT-014: manual-tls-secret-ecdsa scenario installs an ECDSA-keyed certificate
Running `certificates-manual-tls-secret-ecdsa.yaml` via `run-scenario.sh` results in `status: PASS`. The certificate in the resulting Secret reports public-key algorithm `id-ecPublicKey` (P-256 or P-384), not RSA. The chart pods that mount this Secret reach Ready and serve TLS using the ECDSA key.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-manual-tls-secret-ecdsa-*/result.yaml`) with `status: PASS`, terminal-output of `kubectl get secret -n sample <ecdsa-secret> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep "Public Key Algorithm"` contains `id-ecPublicKey`

### Variant execution assertions (mounted-tls-certs)

### VAL-CERT-015: mounted-tls-certs-pvc-mount scenario mounts cert from PVC into pod
Running `certificates-mounted-tls-certs-pvc-mount.yaml` via `run-scenario.sh` results in `status: PASS`. The chart's main pod has a `volumeMount` whose `mountPath` matches the value in `tls.mountPath` (e.g. `/etc/tls`) and whose volume source is a `persistentVolumeClaim`. `kubectl exec` into the pod can `stat /etc/tls/tls.crt` successfully.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-mounted-tls-certs-pvc-mount-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get pod -n sample -l app.kubernetes.io/instance=sample -o jsonpath='{.items[0].spec.volumes[?(@.persistentVolumeClaim)].name}'` is non-empty), kubectl-output(`kubectl exec -n sample <pod> -- stat /etc/tls/tls.crt`) exit code 0

### VAL-CERT-016: mounted-tls-certs-projected-volume scenario uses a projected volume source
Running `certificates-mounted-tls-certs-projected-volume.yaml` via `run-scenario.sh` results in `status: PASS`. The product pod has a `volume` of kind `projected` that includes at least one `secret` source (the TLS Secret) and the mount path is reachable from inside the pod.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-mounted-tls-certs-projected-volume-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get pod -n sample <pod> -o jsonpath='{.spec.volumes[?(@.projected)].projected.sources[?(@.secret)].secret.name}'`) is non-empty

### VAL-CERT-017: mounted-tls-certs-csi-secret-store scenario produces SecretProviderClass-backed mount
Running `certificates-mounted-tls-certs-csi-secret-store.yaml` via `run-scenario.sh` results in `status: PASS`. The scenario's preinstall installs the `secrets-store-csi-driver` Helm chart (and a stub `SecretProviderClass` via `raw_manifest`); the chart pod has a volume of `csi.driver=secrets-store.csi.k8s.io`; the mount path contains the expected cert files. (If CSI driver cannot run on the test kind backend, the scenario must mark itself SKIP with a documented reason rather than FAIL.)
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-mounted-tls-certs-csi-secret-store-*/result.yaml`) with `status: PASS` (or `SKIP` with reason), kubectl-output(`kubectl get pod -n sample <pod> -o jsonpath='{.spec.volumes[?(@.csi.driver=="secrets-store.csi.k8s.io")].name}'`) is non-empty when status is PASS

### Area-wide structural assertions

### VAL-CERT-018: All certificates scenario YAMLs pass jsonschema validation
Every scenario file under `examples/sample-product-chart/chart-test/scenarios/certificates-*.yaml` validates cleanly against `engine/templates/scenario.schema.json` (using the same validator the engine invokes in `dispatch-swarm.sh` / `run-scenario.sh`).
Tool: bash
Evidence: terminal-output of `for f in examples/sample-product-chart/chart-test/scenarios/certificates-*.yaml; do uv run --directory engine/testgrid python -m testgrid validate-scenario "$f" && echo OK $f || echo FAIL $f; done` shows `OK` for every file and exit code 0 overall

### VAL-CERT-019: helm lint passes for the sample-product-chart
`helm lint examples/sample-product-chart/chart` exits 0 with no `[ERROR]` lines. The chart is the only chart referenced by the certificate-area scenarios via `product.chart`.
Tool: helm-lint
Evidence: terminal-output of `helm lint examples/sample-product-chart/chart` shows `1 chart(s) linted, 0 chart(s) failed` and exit code 0

### VAL-CERT-020: Shared TLS fixtures exist and are non-empty
The fixture set under `examples/sample-product-chart/chart-test/fixtures/certificates/` (F3.4) exists and contains at minimum `ca.crt` and `ca.key`. Each file is a non-empty regular file (> 0 bytes). `ca.crt` is a parseable PEM certificate; `ca.key` is a parseable PEM private key (RSA or ECDSA).
Tool: bash
Evidence: terminal-output of `ls -la examples/sample-product-chart/chart-test/fixtures/certificates/ca.crt examples/sample-product-chart/chart-test/fixtures/certificates/ca.key` shows both > 0 bytes; terminal-output of `openssl x509 -in examples/sample-product-chart/chart-test/fixtures/certificates/ca.crt -noout -subject` succeeds; terminal-output of `openssl pkey -in examples/sample-product-chart/chart-test/fixtures/certificates/ca.key -noout -text` succeeds

### VAL-CERT-021: Shared fixtures are byte-identical across scenarios that reference them
For any two certificates-area scenarios that reference the same fixture filename, the SHA-256 digest of the on-disk fixture file is identical. (Scenarios MUST NOT copy/duplicate fixture material — they reference the canonical file under `chart-test/fixtures/certificates/`.)
Tool: bash
Evidence: terminal-output of `shasum -a 256 examples/sample-product-chart/chart-test/fixtures/certificates/*` is a single deterministic set of digests; grep across `examples/sample-product-chart/chart-test/scenarios/certificates-*.yaml` shows no scenario embeds raw `BEGIN CERTIFICATE` PEM content inline

### VAL-CERT-022: manual-tls-secret scenarios reference fixtures via the fixture system, not inline base64
For each `certificates-manual-tls-secret-*.yaml`, the TLS material is delivered through a `raw_manifest` preinstall item whose `path` resolves into `examples/sample-product-chart/chart-test/fixtures/certificates/` (or a sibling fixtures directory) — not via a base64-encoded `tls.crt:` blob embedded inline in the scenario YAML.
Tool: bash
Evidence: terminal-output of `grep -lE 'tls\.crt:\s+[A-Za-z0-9+/=]{50,}' examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-*.yaml` returns empty (no inline base64 blobs); terminal-output of `yq '.cluster.preinstall[] | select(.kind == "raw_manifest") | .path' examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-*.yaml` returns paths that resolve under `chart-test/fixtures/certificates/`

### VAL-CERT-023: TLS private-key fixtures are gitignored or pre-generated, not committed real keys
The repo's `.gitignore` (or `examples/sample-product-chart/chart-test/fixtures/certificates/.gitignore`) excludes `*.key` files, OR the committed `ca.key` and any other `*.key` files in the fixtures dir have a header comment indicating they are "test-only ephemeral keys, regenerated by ./regen.sh" (or equivalent). No fixture key is referenced by a production-shaped certificate (e.g., a key whose corresponding cert names a real domain such as `example.com` or a real ACME issuer URL pointing at a Let's-Encrypt production endpoint).
Tool: bash
Evidence: file(.gitignore) or file(examples/sample-product-chart/chart-test/fixtures/certificates/.gitignore), terminal-output(`grep -l 'BEGIN.*PRIVATE KEY' examples/sample-product-chart/chart-test/fixtures/certificates/*.key | xargs head -n 5`)
