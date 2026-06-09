# Agent 1 Brief — run run-full-bench-20260609-085346

You are executor 1 of 1 in a `chart-test-swarm` run.

- **Project:**    `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart`
- **Run dir:**    `reports/run-full-bench-20260609-085346/`
- **Your dir:**   `reports/run-full-bench-20260609-085346/agent-1/`

## Your assigned scenarios

- **`annotations-off`** — Capability: no custom annotation leaks when unset (OFF)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/annotations-off.yaml`
  - desc: Renders the product chart with NO annotation override and asserts that the custom annotation key (example.com/owner) is absent from every rendered object's metadata. Since the chart has no extraAnnotations/commonAnnotations knob and the default render never emits this annotation, this scenario is EXPECTED to PASS — confirming no annotation leakage.
- **`annotations-on`** — Capability: custom annotations stamped on every object (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/annotations-on.yaml`
  - desc: Renders the product chart with a global annotation knob set (extraAnnotations.example\.com/owner=team-x) and asserts every rendered object (all kinds) carries the configured annotation at .metadata.annotations. The sample chart does NOT expose an extraAnnotations/commonAnnotations knob — this scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks global annotation propagation.
- **`imagepullsecrets-off`** — Capability: no imagePullSecrets when unset (OFF)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/imagepullsecrets-off.yaml`
  - desc: Renders the product chart with default values (no imagePullSecrets overrides) and asserts that no workload pod spec and no ServiceAccount carries an imagePullSecrets field. Since the chart has no imagePullSecrets templates, none should appear. This scenario is EXPECTED to PASS — confirming no imagePullSecrets leakage when the knob is off.
- **`imagepullsecrets-on`** — Capability: imagePullSecrets propagate to every pod spec + ServiceAccount (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/imagepullsecrets-on.yaml`
  - desc: Renders the product chart with imagePullSecrets[0].name=regcred configured and asserts that every workload pod spec carries the imagePullSecrets entry and the chart ServiceAccount also carries it. The sample chart does NOT include an imagePullSecrets field in any template (no Deployment pod spec, no ServiceAccount template). Setting imagePullSecrets has no effect. This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks imagePullSecrets knobs on both pod specs and ServiceAccount.
- **`labels-off`** — Capability: no extra-label keys leak when unset (OFF)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/labels-off.yaml`
  - desc: Renders the product chart with NO extra-label overrides and asserts that the configured test-label keys (team, cost-center) are absent from every rendered object's metadata. Since the chart has no extraLabels/commonLabels knob and the default render never emits these keys, this scenario is EXPECTED to PASS — confirming no label leakage.
- **`labels-on`** — Capability: extra labels stamped on every object (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/labels-on.yaml`
  - desc: Renders the product chart with a global extra-label knob set (extraLabels.team=platform, extraLabels.cost-center=42) and asserts every rendered object (all kinds, not just pod templates) carries the configured labels at .metadata.labels. The sample chart does NOT expose an extraLabels/commonLabels knob — this scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks global label propagation.
- **`minimal`** — Vanilla cluster — no preinstalled addons
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/minimal.yaml`
  - desc: Baseline: chart installs and pods come up on a stock kind cluster.
- **`network-policy-off`** — Capability: no NetworkPolicy when disabled (OFF)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/network-policy-off.yaml`
  - desc: Renders the product chart with networkPolicy.enabled=false (or unset) and asserts zero NetworkPolicy documents in the render. Since the chart has no NetworkPolicy template at all, no NetworkPolicy objects are ever emitted regardless of the networkPolicy.enabled value. This scenario is EXPECTED to PASS — confirming no NetworkPolicy leakage when the knob is off.
- **`network-policy-on`** — Capability: NetworkPolicy present when enabled (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/network-policy-on.yaml`
  - desc: Renders the product chart with networkPolicy.enabled=true and asserts a NetworkPolicy is rendered selecting the product pods. The sample chart does NOT include a networkpolicy.yaml template — setting networkPolicy.enabled=true has no effect because the chart lacks the template. This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks a networkPolicy knob and template.
- **`priority-class-off`** — Capability: no priorityClassName when unset (OFF)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/priority-class-off.yaml`
  - desc: Renders the product chart with default values (no priorityClassName override) and asserts that no workload pod spec carries a priorityClassName field. Since the chart has no priorityClassName template and no value is set, none should appear. This scenario is EXPECTED to PASS — confirming no priorityClassName leakage when unset.
- **`priority-class-on`** — Capability: priorityClassName settable on ALL workloads (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/priority-class-on.yaml`
  - desc: Renders the product chart with priorityClassName=high-priority configured and asserts that every workload pod spec carries the priorityClassName with the configured value. The sample chart does NOT expose a priorityClassName knob in its values.yaml and has no priorityClassName field in any Deployment template — setting priorityClassName has no effect. This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks the priorityClassName scheduling knob.
- **`rbac-off`** — Capability: no RBAC objects when disabled (OFF)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/rbac-off.yaml`
  - desc: Renders the product chart with rbac.create=false and asserts zero RBAC-kind objects (ServiceAccount, Role, ClusterRole, RoleBinding, ClusterRoleBinding) in the render. Since the chart has no RBAC templates at all, no RBAC objects are ever emitted regardless of the rbac.create value. This scenario is EXPECTED to PASS — confirming no RBAC objects leak when the knob is off.
- **`rbac-on`** — Capability: RBAC objects present when enabled (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/rbac-on.yaml`
  - desc: Renders the product chart with rbac.create=true and serviceAccount.create=true and asserts a ServiceAccount, Role or ClusterRole, and matching RoleBinding or ClusterRoleBinding are present with correct wiring (roleRef, subjects, serviceAccountName). The sample chart does NOT include RBAC templates — no serviceaccount.yaml, role.yaml, or rolebinding.yaml exists. Setting rbac.create=true has no effect because the chart lacks the templates. This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks rbac.create and serviceAccount.create knobs.
- **`resources-off`** — Capability: no populated resources block when unset (OFF)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/resources-off.yaml`
  - desc: Renders the product chart with default values (no resources overrides) and asserts that no workload container carries a populated resources block. Since the skywatcher template has no resources block at all, and scope/darkroom are disabled, no populated resources block should appear. This scenario is EXPECTED to PASS — confirming no resources leakage when the knob is off.
- **`resources-on`** — Capability: resource requests/limits set on ALL workloads (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/resources-on.yaml`
  - desc: Renders the product chart with resources.requests and resources.limits configured (cpu=100m memory=128Mi / cpu=500m memory=256Mi) and asserts that every workload container carries the configured resources block. The scope and darkroom templates wire {{- with .Values.resources }} but the skywatcher Deployment does NOT include a resources block — setting resources has no effect on skywatcher. Scope and darkroom are not enabled in this scenario due to a pre-existing chart bug (scope readiness probe mismatch), but the skywatcher gap alone makes this scenario EXPECTED to FAIL (honest red gap). Scope and darkroom WOULD honor resources if enabled.
- **`scheduling-affinity-on`** — Capability: affinity settable on ALL workloads (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/scheduling-affinity-on.yaml`
  - desc: Renders the product chart with a nodeAffinity rule configured (requiredDuringSchedulingIgnoredDuringExecution preferring kubernetes.io/os=linux) and asserts that every workload pod spec carries the affinity block. The sample chart does NOT expose an affinity knob in its values.yaml and has no affinity block in any Deployment template — setting affinity has no effect. This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks the affinity scheduling knob.
- **`scheduling-nodeselector-on`** — Capability: nodeSelector settable on ALL workloads (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/scheduling-nodeselector-on.yaml`
  - desc: Renders the product chart with nodeSelector.disktype=ssd configured and asserts that every workload pod spec carries nodeSelector with the configured value. The sample chart does NOT expose a nodeSelector knob in its values.yaml and has no nodeSelector block in any Deployment template — setting nodeSelector has no effect. This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks the nodeSelector scheduling knob on its workloads.
- **`scheduling-off`** — Capability: no scheduling fields when unset (OFF)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/scheduling-off.yaml`
  - desc: Renders the product chart with default values (no nodeSelector, tolerations, affinity, or topologySpreadConstraints overrides) and asserts that no workload pod spec carries any of these scheduling fields. Since the chart has no scheduling templates and no values are set, none should appear. This scenario is EXPECTED to PASS — confirming no scheduling fields leak onto pod specs when unset.
- **`scheduling-tolerations-on`** — Capability: tolerations settable on ALL workloads (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/scheduling-tolerations-on.yaml`
  - desc: Renders the product chart with a toleration configured (key=dedicated, operator=Equal, value=gpu, effect=NoSchedule) and asserts that every workload pod spec carries the toleration. The sample chart does NOT expose a tolerations knob in its values.yaml and has no tolerations block in any Deployment template — setting tolerations has no effect. This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks the tolerations scheduling knob.
- **`scheduling-topology-spread-on`** — Capability: topologySpreadConstraints settable on ALL workloads (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/scheduling-topology-spread-on.yaml`
  - desc: Renders the product chart with a topologySpreadConstraint configured (maxSkew=1, topologyKey=topology.kubernetes.io/zone, whenUnsatisfiable=DoNotSchedule) and asserts that every workload pod spec carries the constraint. The sample chart does NOT expose a topologySpreadConstraints knob in its values.yaml and has no topologySpreadConstraints block in any Deployment template — setting the constraint has no effect. This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks the topologySpreadConstraints scheduling knob.
- **`scheme-allow-http`** — Capability: HTTP baseline scheme (OFF)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/scheme-allow-http.yaml`
  - desc: Renders the product chart with default values (no TLS override) and asserts the plain-HTTP port 80 IS present on the Service, confirming the off-case baseline that the HTTPS-only knob must be able to suppress. This scenario is EXPECTED to PASS — the default render exposes port 80 (name: http) on the skywatcher Service.
- **`scheme-https-only`** — Capability: HTTPS-only scheme enforcement (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/scheme-https-only.yaml`
  - desc: Renders the product chart with TLS enabled (tls.enabled=true) and asserts no plain-HTTP Service port, container port, probe, or Ingress backend is present. The sample chart does NOT support suppressing the HTTP port — when TLS is enabled it merely ADDS an HTTPS port (443) alongside the always-present HTTP port 80 on the Service, containerPort 80 on the Deployment, probes targeting port 80, and the Ingress backend pointing at service.port (80). This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks an HTTPS-only / http-disable knob. A TLS secret fixture is preinstalled so the chart can deploy with tls.enabled=true.
- **`security-context-off`** — Capability: no securityContext when knobs unset (OFF)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/security-context-off.yaml`
  - desc: Renders the product chart with default values (no securityContext overrides) and asserts that no pod-level or container-level securityContext block is present on any workload. Since the chart has no securityContext templates, no securityContext blocks are ever emitted. This scenario is EXPECTED to PASS — confirming no securityContext leakage when the knob is off.
- **`security-context-on`** — Capability: pod/container securityContext knobs set (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/security-context-on.yaml`
  - desc: Renders the product chart with pod-security and container-security knobs set (podSecurityContext.runAsNonRoot=true, podSecurityContext.seccompProfile.type=RuntimeDefault, securityContext.readOnlyRootFilesystem=true, securityContext.allowPrivilegeEscalation=false, securityContext.capabilities.drop[0]=ALL) and asserts pod-level and container-level securityContext fields appear with the configured values. The sample chart does NOT expose podSecurityContext or securityContext values and has no securityContext blocks in its templates — setting these knobs has no effect. This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks securityContext knobs.
- **`serviceaccount-annotations-off`** — Capability: ServiceAccount identity annotations absent when unset (OFF)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/serviceaccount-annotations-off.yaml`
  - desc: Renders the product chart with serviceAccount.create=true and no annotation overrides, then asserts the ServiceAccount does NOT carry any cloud-identity annotation keys (IRSA, Azure WI, GKE WI). The sample chart does NOT include a serviceaccount.yaml template — no ServiceAccount is rendered at all. Since no ServiceAccount exists, the off-case is vacuously satisfied. This scenario is EXPECTED to PASS — confirming no cloud-identity annotation leakage (and no ServiceAccount) when the knob is off.
- **`serviceaccount-annotations-on`** — Capability: ServiceAccount cloud-identity annotations settable (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/serviceaccount-annotations-on.yaml`
  - desc: Renders the product chart with serviceAccount.annotations configured for AWS IRSA (eks.amazonaws.com/role-arn) and asserts the rendered ServiceAccount carries the exact annotation key/value. The sample chart does NOT include a serviceaccount.yaml template — no ServiceAccount is rendered. Setting serviceAccount.annotations has no effect because the chart lacks both a ServiceAccount template and a serviceAccount.annotations knob. This scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks ServiceAccount cloud-identity annotation support.
- **`certificates-cert-manager-jks-pkcs12`** — cert-manager JKS/PKCS12 keystore bundle
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-cert-manager-jks-pkcs12.yaml`
  - desc: Installs cert-manager with a self-signed ClusterIssuer, issues a Certificate, wraps tls.crt+tls.key into a PKCS12 bundle, and stores as a new Secret alongside the TLS material.
- **`certificates-cert-manager-lets-encrypt-staging`** — cert-manager Let's Encrypt staging issuer
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-cert-manager-lets-encrypt-staging.yaml`
  - desc: Installs cert-manager with Let's Encrypt staging ACME issuer. Verifies ClusterIssuer Ready=True and uses self-signed fallback Certificate to confirm chart pods serve TLS.
- **`certificates-cert-manager-self-signed-ca`** — cert-manager self-signed CA issuer
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-cert-manager-self-signed-ca.yaml`
  - desc: Installs cert-manager, creates a self-signed ClusterIssuer, issues a Certificate for the product Service FQDN, and verifies HTTPS serving with --cacert.
- **`certificates-cert-manager-wildcard`** — cert-manager wildcard certificate
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-cert-manager-wildcard.yaml`
  - desc: Installs cert-manager with a self-signed ClusterIssuer, issues a wildcard Certificate with SAN DNS:*.test.local + test.local, and verifies both SANs are present.
- **`certificates-manual-tls-secret-basic`** — manual-tls-secret basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-manual-tls-secret-basic.yaml`
  - desc: Delivers a pre-provisioned TLS Secret (RSA 2048) via raw_manifest preinstall and verifies the chart serves HTTPS with it. No cert-manager dependency.
- **`certificates-manual-tls-secret-ecdsa`** — manual-tls-secret ECDSA key
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-manual-tls-secret-ecdsa.yaml`
  - desc: Delivers a pre-provisioned TLS Secret with ECDSA P-256 key via raw_manifest. Verifies cert has id-ecPublicKey algorithm and pods serve HTTPS with the ECDSA key.
- **`certificates-manual-tls-secret-multiple-sans`** — manual-tls-secret multiple SANs
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-manual-tls-secret-multiple-sans.yaml`
  - desc: Delivers a pre-provisioned TLS Secret with 3 DNS SANs (sample.sample.svc, api.sample.sample.svc, admin.sample.sample.svc) via raw_manifest and verifies the cert has >=2 SAN entries.
- **`certificates-mounted-tls-certs-csi-secret-store`** — mounted-tls-certs csi-secret-store
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-mounted-tls-certs-csi-secret-store.yaml`
  - desc: Installs the secrets-store-csi-driver helm chart and a stub SecretProviderClass, then installs the chart with a TLS secret volume. Verifies CSI driver presence, SecretProviderClass resource, and that the product pod serves HTTPS. Full CSI volume mount verification requires a real CSI provider plugin (e.g. AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, or HashiCorp Vault) which is not available on kind; the scenario validates CSI infrastructure deployment and documents the mount verification as a SKIP on kind.
- **`certificates-mounted-tls-certs-projected-volume`** — mounted-tls-certs projected-volume
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-mounted-tls-certs-projected-volume.yaml`
  - desc: Creates a TLS Secret, then installs the chart using a projected volume that projects the Secret into the pod. Verifies projected volume source and HTTPS serving.
- **`certificates-mounted-tls-certs-pvc-mount`** — mounted-tls-certs pvc-mount
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/certificates-mounted-tls-certs-pvc-mount.yaml`
  - desc: Creates a PVC, populates it with TLS certs via a Job, then installs the chart with a persistentVolumeClaim-backed TLS volume. Verifies the pod mount and HTTPS serving.
- **`tls-cert-manager-self-signed`** — cert-manager self-signed Issuer -> CA Cert -> CA Issuer -> leaf Cert
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/tls-cert-manager-self-signed.yaml`
  - desc: Installs cert-manager with CRDs, applies a self-signed Issuer, a CA Certificate bootstrapping a CA Secret, a CA Issuer backed by that Secret, and a leaf Certificate for the product Service FQDN. Deploys chart with tls.enabled=true and tls.secretName pointing at the issued Secret. Verifies HTTPS 200 with --cacert and SAN match.
- **`tls-manual-secret`** — Manual TLS Secret via raw_manifest
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/tls-manual-secret.yaml`
  - desc: Delivers a pre-provisioned kubernetes.io/tls Secret (RSA 2048) via raw_manifest preinstall sourced from chart-test/fixtures/, no inline base64 blobs. The chart mounts it with tls.volumeType=secret (default) and serves HTTPS 200. Validates Secret type, data keys, PEM validity, and in-cluster HTTPS reachability.
- **`tls-mounted-projected`** — TLS via projected volume
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/tls-mounted-projected.yaml`
  - desc: Creates a kubernetes.io/tls Secret, then deploys the chart with tls.volumeType=projected so the pod has a projected volume sourcing the TLS Secret. Verifies projected volume source, tls.crt/tls.key present at mountPath, and in-cluster HTTPS curl returns 200.
- **`tls-mounted-pvc`** — TLS via persistentVolumeClaim
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/tls-mounted-pvc.yaml`
  - desc: Creates a PVC, populates it with TLS certs via a Job, then deploys the chart with tls.volumeType=persistentVolumeClaim and tls.pvcClaimName pointing at the pre-populated PVC. Verifies the pod mount, cert files at mountPath, and in-cluster HTTPS curl returns 200. Artifact bundle records the exact volumeType=persistentVolumeClaim.
- **`with-cert-manager`** — Customer ships cert-manager preinstalled
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/certificates/with-cert-manager.yaml`
  - desc: Validates chart coexists with cert-manager and its CRDs.
- **`cni-cilium-ebpf-kube-proxy-replacement`** — Cilium eBPF kube-proxy replacement
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/cni/cni-cilium-ebpf-kube-proxy-replacement.yaml`
  - desc: Proves full eBPF kube-proxy replacement on kind: Cilium replaces kube-proxy, product ClusterIP reachable through eBPF datapath.
- **`cni-cilium-ingress`** — Cilium ingress controller — dedicated loadbalancerMode
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/cni/cni-cilium-ingress.yaml`
  - desc: Proves the Cilium ingress controller in dedicated loadbalancerMode on kind: per-Ingress Service routes HTTP with matching Host header to the product Service.
- **`cni-cilium-network-policy`** — CiliumNetworkPolicy enforcement — default-deny + allow-by-label
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/cni/cni-cilium-network-policy.yaml`
  - desc: Proves CiliumNetworkPolicy (CNP) enforcement on kind: default-deny + allow-by-label. Blocks unlabeled traffic; allows labeled clients. CNP applied as raw_manifest preinstall.
- **`envoy-gateway`** — Envoy Gateway (Gateway API)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/envoy-gateway.yaml`
  - desc: Installs Envoy Gateway controller via OCI helm chart (CRDs are bundled in the chart's crds/ directory and installed automatically by Helm before templates). Verifies chart coexists with a running gateway controller.
- **`gateway-api-contour-gateway-api-basic`** — Contour Gateway API Basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-contour-gateway-api-basic.yaml`
  - desc: Installs Gateway API CRDs and Contour Gateway Provisioner, creates GatewayClass contour + Gateway + HTTPRoute, and verifies HTTP routing through the auto-provisioned Envoy proxy.
- **`gateway-api-contour-gateway-api-response-header-modifier`** — Contour Gateway API Response Header Modifier
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-contour-gateway-api-response-header-modifier.yaml`
  - desc: Installs Gateway API CRDs + Contour Gateway Provisioner, creates GatewayClass contour + Gateway + HTTPRoute with ResponseHeaderModifier filter, verifies X-Powered-By header.
- **`gateway-api-contour-gateway-api-route-precedence`** — Contour Gateway API Route Precedence
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-contour-gateway-api-route-precedence.yaml`
  - desc: Installs Gateway API CRDs + Contour Gateway Provisioner, creates GatewayClass contour + Gateway + two HTTPRoutes with overlapping prefixes, verifies more specific route wins.
- **`gateway-api-envoy-gateway-cert-manager-tls`** — Envoy Gateway + cert-manager TLS
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-envoy-gateway-cert-manager-tls.yaml`
  - desc: Installs cert-manager and envoy-gateway, issues a TLS certificate, creates Gateway with HTTPS listener using cert-manager Secret, and verifies HTTPS serving with expected cert.
- **`gateway-api-envoy-gateway-grpcroute`** — Envoy Gateway GRPCRoute
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-envoy-gateway-grpcroute.yaml`
  - desc: Installs Gateway API CRDs and envoy-gateway controller, deploys a gRPC backend, creates GRPCRoute, and verifies gRPC reflection through the Envoy proxy.
- **`gateway-api-envoy-gateway-httproute`** — Envoy Gateway HTTPRoute
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-envoy-gateway-httproute.yaml`
  - desc: Installs Gateway API CRDs and envoy-gateway controller, creates GatewayClass+Gateway+HTTPRoute, and verifies HTTP routing through the Envoy proxy.
- **`gateway-api-envoy-gateway-security-policy-attach`** — Envoy Gateway SecurityPolicy (CORS)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-envoy-gateway-security-policy-attach.yaml`
  - desc: Installs Gateway API CRDs and envoy-gateway controller, creates HTTPRoute with SecurityPolicy (CORS) attaching to the route, and verifies CORS header on preflight.
- **`gateway-api-istio-egress`** — Istio Gateway API Egress
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-istio-egress.yaml`
  - desc: Installs istio/base + istio/istiod with REGISTRY_ONLY outbound policy and an egress gateway, applies a ServiceEntry + istio egress Gateway + VirtualService (raw_manifest) for httpbin.org, deploys the chart with sidecar injection, and verifies the egress infrastructure. Gap-probe: the chart exposes no knob to route its workload egress through the egress Gateway (no Sidecar/VirtualService from chart), and end-to-end egress proof is unverifiable for the chart-owned path. The artifact bundle documents the gap.
- **`gateway-api-istio-gateway-api-backend-tls-policy`** — Istio Gateway API BackendTLSPolicy
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-istio-gateway-api-backend-tls-policy.yaml`
  - desc: Installs istio/base + istio/istiod and Gateway API CRDs, generates self-signed TLS certs at runtime, creates BackendTLSPolicy targeting the Service, and verifies Policy acceptance and gateway routing.
- **`gateway-api-istio-gateway-api-basic`** — Istio Gateway API Basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-istio-gateway-api-basic.yaml`
  - desc: Installs istio/base + istio/istiod and Gateway API CRDs, creates GatewayClass istio + Gateway + HTTPRoute, and verifies HTTP routing through auto-provisioned Istio data-plane.
- **`gateway-api-istio-gateway-api-multi-listener`** — Istio Gateway API Multi-Listener
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-istio-gateway-api-multi-listener.yaml`
  - desc: Installs istio/base + istio/istiod and Gateway API CRDs, creates Gateway with HTTP:80 + HTTPS:443 listeners, and verifies both protocols with TLS certificate.
- **`gateway-api-istio-ingress`** — Istio Gateway API Ingress
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/gateway-api/gateway-api-istio-ingress.yaml`
  - desc: Installs istio/base + istio/istiod and Gateway API CRDs (raw_manifest), applies an istio-class Gateway via fixture, deploys the chart with gatewayRoute.enabled=true pointing to the Gateway, and verifies the chart's HTTPRoute is Accepted=True and ResolvedRefs=True, and the gateway data-plane serves HTTP 200.
- **`ingress-controllers-contour-basic-httpproxy`** — Contour basic HTTPProxy (gap-probe)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-contour-basic-httpproxy.yaml`
  - desc: Installs Contour, creates an HTTPProxy for the product Service via fixture, and verifies HTTP routing through the envoy pod IP with Host header matching and HTTPProxy status valid. Then runs a gap-probe: the chart does NOT natively emit a Contour HTTPProxy CRD — the HTTPProxy was created by the fixture, not by a chart template. This is an honest gap (red cell); do NOT over-engineer the chart.
- **`ingress-controllers-contour-rate-limit`** — Contour rate limit
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-contour-rate-limit.yaml`
  - desc: Installs Contour, creates an HTTPProxy with local rateLimitPolicy (5 req/min), and verifies that exceeding the limit produces 429 responses while requests within the limit succeed.
- **`ingress-controllers-contour-tls-delegation`** — Contour TLS delegation
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-contour-tls-delegation.yaml`
  - desc: Installs Contour, deploys TLS Secret in tls-secrets NS, grants cross-namespace access via TLSCertificateDelegation, creates HTTPProxy with delegated Secret, verifies HTTPS 200.
- **`ingress-controllers-nginx-ingress-basic`** — NGINX Ingress basic routing
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-nginx-ingress-basic.yaml`
  - desc: Installs NGINX Ingress controller, creates an Ingress with ingressClassName: nginx, and verifies Host-header routing returns HTTP 200.
- **`ingress-controllers-nginx-ingress-canary`** — NGINX Ingress canary traffic splitting
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-nginx-ingress-canary.yaml`
  - desc: Installs NGINX Ingress controller with stable+canary Ingresses (canary-weight=20), deploys a canary backend with distinctive response, verifies ~20% of 100 probes hit canary.
- **`ingress-controllers-nginx-ingress-default-backend`** — NGINX Ingress custom default backend
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-nginx-ingress-default-backend.yaml`
  - desc: Installs NGINX Ingress with custom default backend Deployment+Service, verifies requests without matching Host return the custom backend's distinctive body instead of stock 404.
- **`ingress-controllers-nginx-ingress-snippet-annotations`** — NGINX Ingress snippet annotations
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-nginx-ingress-snippet-annotations.yaml`
  - desc: Installs NGINX Ingress with allowSnippetAnnotations=true, creates an Ingress with configuration-snippet annotation injecting add_header X-Test, verifies the header appears.
- **`ingress-controllers-nginx-ingress-tls-cert-manager`** — NGINX Ingress TLS with cert-manager
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-nginx-ingress-tls-cert-manager.yaml`
  - desc: Installs cert-manager + NGINX Ingress, creates self-signed ClusterIssuer+Certificate, verifies HTTPS routing through nginx with TLS terminated by cert-manager-issued cert chain.
- **`ingress-controllers-traefik-basic`** — Traefik basic IngressRoute
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-traefik-basic.yaml`
  - desc: Installs Traefik, creates an IngressRoute for the product Service, and verifies HTTP routing through the Traefik pod IP with Host header matching.
- **`ingress-controllers-traefik-ingressroute-crd`** — Traefik IngressRoute CRD
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-traefik-ingressroute-crd.yaml`
  - desc: Installs Traefik, uses IngressRoute CRD exclusively for routing (no classic Ingress), and verifies HTTP traffic reaches the backend.
- **`ingress-controllers-traefik-middleware-chain`** — Traefik middleware chain
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-traefik-middleware-chain.yaml`
  - desc: Installs Traefik, creates a Middleware CR that injects custom headers, references it from an IngressRoute, and verifies the middleware effect is observable.
- **`ingress-controllers-traefik-tls-passthrough`** — Traefik TLS passthrough
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/ingress-controllers-traefik-tls-passthrough.yaml`
  - desc: Installs Traefik, configures IngressRouteTCP with tls.passthrough=true, and verifies the backend's TLS certificate is served untouched through the proxy.
- **`networking-kong-ingress`** — Kong Ingress (className=kong)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/networking-kong-ingress.yaml`
  - desc: Installs Kong Ingress Controller, deploys the product chart with ingress.enabled=true and ingress.className=kong, and verifies end-to-end routing through the Kong proxy data path via the chart's built-in Ingress resource. Also includes a KongPlugin gap-probe documenting that the sample chart exposes no konghq.com/plugins annotation or KongPlugin CRD knob, which is an honest gap (red cell) — do NOT over-engineer the chart.
- **`networking-metallb-loadbalancer`** — MetalLB LoadBalancer (service.type=LoadBalancer)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/networking-metallb-loadbalancer.yaml`
  - desc: Installs MetalLB, configures an IPAddressPool + L2Advertisement whose CIDR is inside the kind Docker bridge subnet, deploys the product chart with service.type=LoadBalancer, and verifies that MetalLB assigns an external IP from the pool and the LB endpoint serves HTTP 200.
- **`networking-traefik-ingress`** — Traefik Ingress (className=traefik)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/networking/networking-traefik-ingress.yaml`
  - desc: Installs Traefik, deploys the product chart with ingress.enabled=true and ingress.className=traefik, and verifies end-to-end routing through the Traefik data path via the chart's built-in Ingress resource.
- **`customer-b-gatekeeper`** — Customer B — OPA Gatekeeper admission policies
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/customer-b-gatekeeper.yaml`
  - desc: Customer B runs Gatekeeper with strict admission policies. Chart must satisfy required-labels + no-privileged constraints.
- **`policy-kyverno-generate`** — Kyverno generate: ConfigMap in labeled namespaces
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-kyverno-generate.yaml`
  - desc: Installs Kyverno, creates a ClusterPolicy that generates a ConfigMap in any namespace labeled kyverno.io/generate=true. Verifies that creating a fresh namespace with the trigger label causes Kyverno to generate the ConfigMap within 10s. Webhook failure mode: Fail.
- **`policy-kyverno-image-verify`** — Kyverno image-verify: only approved registries
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-kyverno-image-verify.yaml`
  - desc: Installs Kyverno, creates a ClusterPolicy that only allows images from public.ecr.aws/* or nginx* registries. Verifies a Pod referencing docker.io/library/redis:7-alpine is denied (stderr names rule), while a Pod with an approved image is accepted. Webhook failure mode: Fail.
- **`policy-kyverno-mutate`** — Kyverno mutate: auto-add annotation to Pods
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-kyverno-mutate.yaml`
  - desc: Installs Kyverno, creates a ClusterPolicy that adds the annotation kyverno.io/managed-by: chart-test-swarm to Pods. Verifies a Pod manifest lacking the annotation gets it auto-added after the mutating webhook fires. Webhook failure mode: Fail.
- **`policy-kyverno-validate`** — Kyverno validate: require labels on Deployments
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-kyverno-validate.yaml`
  - desc: Installs Kyverno, creates a ClusterPolicy that requires app.kubernetes.io/name label on Deployments. Verifies non-compliant Deployment denied (stderr names validate.kyverno.svc-fail and policy name), compliant Deployment accepted. Webhook failure mode: Fail.
- **`policy-opa-gatekeeper-image-allowlist`** — OPA Gatekeeper image allowlist enforcement
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-opa-gatekeeper-image-allowlist.yaml`
  - desc: Installs OPA Gatekeeper, creates k8sallowedrepos ConstraintTemplate + Constraint allowing only nginx + public.ecr.aws images. Verifies non-allowlisted image denied, allowlisted image accepted.
- **`policy-opa-gatekeeper-required-labels`** — OPA Gatekeeper required labels enforcement (gap-probe)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-opa-gatekeeper-required-labels.yaml`
  - desc: Installs OPA Gatekeeper + NGINX Ingress, creates k8srequiredlabels ConstraintTemplate + Constraint targeting Deployments and Ingresses. Verifies non-compliant resources denied, compliant accepted. Cross-feature compose with M4 nginx-ingress. Then runs a gap-probe: the chart's Ingress template uses selectorLabels (just app: <release>) instead of the full common labels (which include app.kubernetes.io/name), so the chart's Ingress fails the required-labels constraint — an honest gap (red cell); do NOT over-engineer the chart.
- **`policy-opa-gatekeeper-resource-limits`** — OPA Gatekeeper resource limits enforcement
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-opa-gatekeeper-resource-limits.yaml`
  - desc: Installs OPA Gatekeeper, creates k8scontainerlimits ConstraintTemplate + Constraint requiring CPU and memory limits on all containers. Verifies Deployment without limits denied, compliant Deployment accepted.
- **`policy-opa-gatekeeper-sync-config`** — OPA Gatekeeper sync configuration
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/policy/policy-opa-gatekeeper-sync-config.yaml`
  - desc: Installs OPA Gatekeeper, applies Gatekeeper Config with sync.syncOnly listing Namespace, Pod, and Ingress kinds for OPA cache sync. Verifies Config exists with non-empty syncOnly, controller Ready.
- **`customer-a-istio`** — Customer A — Istio mesh + cert-manager
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/customer-a-istio.yaml`
  - desc: Customer A's profile: istio sidecar injection, istio-ingress, cert-manager.
- **`service-mesh-istio-ambient-live`** — Istio Ambient Mesh — Live mTLS Verification (ztunnel/HBONE)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-ambient-live.yaml`
  - desc: Installs istio/base + istio/istiod (profile=ambient) + istio/cni (profile=ambient) + istio/ztunnel, annotates the product namespace istio.io/dataplane-mode=ambient via raw_manifest, deploys the chart with mesh.inject=false (NO sidecar), and proves: (1) ztunnel DaemonSet pods are Ready in istio-system, (2) the product namespace carries the ambient annotation and every product pod has exactly 1 container (no istio-proxy), (3) in-mesh traffic to the product Service returns HTTP 200 and the connection is mTLS over HBONE — confirmed via ztunnel metrics/logs. Emits a PASS artifact bundle with 1-container pod manifest, ambient-annotated namespace manifest, applied-overrides recording inject: false, and versions.json.
- **`service-mesh-istio-ingress-gateway-basic`** — Istio Ingress Gateway — Basic
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-ingress-gateway-basic.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart with ingress disabled, creates an Istio Gateway + VirtualService to route external traffic through the ingressgateway pod, and verifies HTTP 200 via the gateway with a Host header.
- **`service-mesh-istio-ingress-gateway-jwt`** — Istio Ingress Gateway — JWT Authentication
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-ingress-gateway-jwt.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart, creates an Istio Gateway + VirtualService, applies a RequestAuthentication + AuthorizationPolicy requiring a valid JWT, and verifies: (a) requests without a Bearer token are rejected with 401/403, (b) requests with a valid JWT signed by the test issuer key from fixtures/service-mesh/jwt/ return HTTP 200.
- **`service-mesh-istio-ingress-gateway-multi-host`** — Istio Ingress Gateway — Multi-Host
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-ingress-gateway-multi-host.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart with scope.enabled=true, creates an Istio Gateway with two server blocks for different hosts, and a VirtualService that routes each host to a different backend (skywatcher vs scope). Verifies both hosts return HTTP 200 through the ingressgateway.
- **`service-mesh-istio-ingress-gateway-request-authentication`** — Istio Ingress Gateway — RequestAuthentication (No Deny)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-ingress-gateway-request-authentication.yaml`
  - desc: Installs istio/base + istio/istiod + istio/gateway, deploys the product chart, creates an Istio Gateway + VirtualService, applies a RequestAuthentication that validates JWTs from the test issuer but does NOT require them (no AuthorizationPolicy). Verifies: (a) requests without a token still pass through (HTTP 200), (b) requests with a valid JWT also return 200, and (c) requests with an invalid JWT (wrong issuer) are rejected with 401 by RequestAuthentication validation alone.
- **`service-mesh-istio-service-mesh-cert-manager-tls`** — Istio Service Mesh + cert-manager TLS Gateway
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-service-mesh-cert-manager-tls.yaml`
  - desc: Cross-feature compose: installs cert-manager + istio (base + istiod + gateway), creates a cert-manager self-signed ClusterIssuer and Certificate that issues a TLS Secret, then creates an Istio Gateway with a TLS listener referencing that Secret via credentialName. Verifies: istioctl analyze clean, HTTPS through gateway returns 200 with the cert-manager-issued certificate.
- **`service-mesh-istio-service-mesh-peer-authentication`** — Istio Service Mesh — PeerAuthentication lifecycle
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-service-mesh-peer-authentication.yaml`
  - desc: Installs istio/base + istio/istiod, deploys the product chart with mesh.inject=true, and exercises the PeerAuthentication lifecycle: PERMISSIVE mode allows both mesh and non-mesh traffic; switching to STRICT mode blocks non-mesh traffic while mesh traffic continues via auto-upgraded mTLS.
- **`service-mesh-istio-service-mesh-sidecar-injection`** — Istio Service Mesh — Sidecar Injection
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-service-mesh-sidecar-injection.yaml`
  - desc: Installs istio/base + istio/istiod, enables mesh injection on the product namespace, deploys the product chart with mesh.inject=true and scope.enabled=true, and verifies every product pod has exactly 2 containers including istio-proxy and in-mesh HTTP reaches the product Service with 200.
- **`service-mesh-istio-service-mesh-strict-mtls`** — Istio Service Mesh — strict mTLS
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-service-mesh-strict-mtls.yaml`
  - desc: Installs istio/base + istio/istiod, enables mesh injection, deploys the product chart with scope.enabled=true, creates a PeerAuthentication with mode=STRICT in the product namespace, and verifies: (a) plain HTTP from a non-mesh pod is rejected, (b) in-mesh probe pod still reaches the product Service with 200 via auto-upgraded mTLS.
- **`service-mesh-istio-service-mesh-telemetry-v2`** — Istio Service Mesh — Telemetry v2
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-service-mesh-telemetry-v2.yaml`
  - desc: Installs istio/base + istio/istiod, deploys the product chart with mesh.inject=true, applies a Telemetry resource in the product namespace to configure Envoy access logging and metrics, and verifies proxy stats are accessible and telemetry configuration is active.
- **`service-mesh-istio-sidecar-live`** — Istio Sidecar Mesh — Live mTLS Verification
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-istio-sidecar-live.yaml`
  - desc: Installs istio/base + istio/istiod, pre-labels the product namespace istio-injection=enabled via raw_manifest, deploys the chart with mesh.inject=true, and proves: (1) istiod is Ready and the sidecar injector webhook is present, (2) every product pod has exactly 2 containers including istio-proxy, (3) in-mesh traffic to the product Service returns HTTP 200 and the connection is mTLS — confirmed via istio-proxy stats reporting non-zero inbound SSL handshakes. Emits a PASS artifact bundle with 2-container pod manifest, applied-overrides recording inject: true, and versions.json.
- **`service-mesh-linkerd-basic-mesh`** — Linkerd — Basic Mesh (Sidecar Injection)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-linkerd-basic-mesh.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane via Helm, annotates the product namespace with linkerd.io/inject=enabled, deploys the product chart with scope.enabled=true, and verifies every product pod has a linkerd-proxy sidecar alongside the app container (2-container pods), with linkerd check --proxy returning healthy.
- **`service-mesh-linkerd-live`** — Linkerd — Live mTLS Sidecar Mesh
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-linkerd-live.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane (with a preinstalled trust anchor / issuer cert via raw_manifest), annotates the product namespace with linkerd.io/inject=enabled, deploys the chart, and proves: (1) linkerd control-plane pods Ready and proxy-injector webhook present, (2) every product pod has a linkerd-proxy container alongside the app container, (3) linkerd check --proxy -n sample exits 0 confirming the data plane is healthy. Emits a PASS artifact bundle with a 2-container pod manifest, linkerd.io/inject-annotated namespace, and versions.json.
- **`service-mesh-linkerd-mtls-rotation`** — Linkerd — mTLS Identity Rotation
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-linkerd-mtls-rotation.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane via Helm, annotates the product namespace for injection, deploys the product chart, and verifies that mTLS identities are issued and valid by running linkerd check --proxy and inspecting the identity issuer certificate. Documents the mTLS rotation window and trust-anchor expiry.
- **`service-mesh-linkerd-multi-cluster-preview`** — Linkerd — Multi-Cluster Preview
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-linkerd-multi-cluster-preview.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane + linkerd-multicluster extension via Helm, verifies the multicluster Link and ServiceMirror CRDs are established, and authors a preview Link resource targeting a logical target cluster. No real cross-cluster traffic — this variant validates that the multicluster extension installs cleanly and that the CRD scaffolding is functional.
- **`service-mesh-linkerd-service-profile`** — Linkerd — ServiceProfile (Per-Route Observability)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/service-mesh/service-mesh-linkerd-service-profile.yaml`
  - desc: Installs linkerd-crds + linkerd-control-plane via Helm, annotates the product namespace for injection, deploys the product chart, creates a ServiceProfile CRD for the sample Service defining routes with timeout and retry policies, and verifies the ServiceProfile is recognized.
- **`subchart-postgres-internal`** — Internal postgres subchart enabled
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/storage/subchart-postgres-internal.yaml`
  - desc: Product chart bundles postgres via subchart; verify both come up together.




## Your task

For each assigned scenario YAML:

1. Run end-to-end via the engine:
   ```bash
   bash engine/scripts/run-scenario.sh <scenario.yaml>
   ```
   That brings the cluster up, applies preinstall addons, installs the
   product chart, runs the asserts, and emits a per-scenario
   `result.yaml` into `reports/scenario-<id>-<ts>/`.

2. Aggregate your scenarios' results into a single `result.yaml` at
   `reports/run-full-bench-20260609-085346/agent-1/result.yaml` using this schema:

   ```yaml
   agent: 1
   run_id: run-full-bench-20260609-085346
   results:
     - scenario_id: <id from scenario yaml>
       status: PASS | FAIL | PARTIAL | INCONCLUSIVE
       duration_s: <seconds>
       fail_stage: ""           # only on non-PASS
       fail_msg: ""             # only on non-PASS, include reproduction command
       log_dir: /tmp/.../...
       asserts:
         - { type: pods-ready,           status: PASS, notes: "..." }
         - { type: helm-status-deployed, status: PASS, notes: "..." }
   ```

3. Between scenarios, tear down state cleanly:
   ```bash
   bash engine/scripts/cluster-down.sh
   ```
   so the next scenario starts from a known cluster. (Or use a separate
   cluster name per scenario via `CLUSTER_NAME` env.)

## Discipline

- **No PASS without a positive assertion.** Every PASS must capture at
  least one observable proof (kubectl event, helm status, exit code).
- **No FAIL without a reproduction command.** `fail_msg` must contain
  the exact command sequence that reproduces the failure.
- **INCONCLUSIVE is a valid status.** Use it when something
  intermittent or unobservable prevents a clean PASS/FAIL judgment.
- **Don't lie to the dashboard.** If you skipped a scenario, leave it
  out — the aggregator will surface it as UNTESTED.
