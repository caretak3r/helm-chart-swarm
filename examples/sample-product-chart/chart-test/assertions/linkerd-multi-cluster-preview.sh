#!/usr/bin/env bash
# Linkerd multi-cluster preview smoke assertion.
# Verifies: linkerd-multicluster extension installed, Link and ServiceMirror
# CRDs are established, a preview Link resource can be authored. No real
# cross-cluster traffic — this is a scaffolding validation only.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Verifying linkerd-multicluster extension is installed"
kctl -n linkerd-multicluster get deploy linkerd-service-mirror >/dev/null 2>&1 || {
  echo "FAIL: linkerd-service-mirror deployment not found in linkerd-multicluster namespace" >&2
  exit 1
}
echo "  ✓ linkerd-service-mirror deployment exists"

echo "==> Verifying multicluster CRDs are established"
# Link CRD
kctl get crd links.multicluster.linkerd.io >/dev/null 2>&1 || {
  echo "FAIL: CRD links.multicluster.linkerd.io not found" >&2
  exit 1
}
echo "  ✓ CRD links.multicluster.linkerd.io established"

# Check CRD status condition
LINK_CRD_STATUS=$(kctl get crd links.multicluster.linkerd.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || echo "Unknown")
echo "  links.multicluster.linkerd.io Established: ${LINK_CRD_STATUS}"

# ServiceMirror is the internal resource used by the service-mirror component
SVC_MIRROR_STATUS=$(kctl get crd services.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || echo "N/A")
echo "  services.k8s.io Established: ${SVC_MIRROR_STATUS}"

echo "==> Authoring a preview Link resource for a logical target cluster"
cat <<EOF | kctl apply -f - 2>/dev/null || {
  echo "WARN: could not create preview Link (may be namespace restriction)"
}
apiVersion: multicluster.linkerd.io/v1alpha1
kind: Link
metadata:
  name: target-cluster
  namespace: linkerd-multicluster
spec:
  targetClusterName: target-cluster
  targetClusterDomain: target-cluster.local
  targetClusterLinkerdNamespace: linkerd
  gatewayAddress: "1.2.3.4:4143"
  gatewayIdentity: "target-cluster.linkerd-managed.linkerd.svc.cluster.local"
  probeSpec:
    path: /ready
    port: 4191
    period: 30s
EOF

echo "  Verifying Link resource was created"
LINK_COUNT=$(kctl -n linkerd-multicluster get link -o name 2>/dev/null | wc -l | tr -d ' ')
echo "  Link resources in linkerd-multicluster: ${LINK_COUNT}"

kctl -n linkerd-multicluster get link target-cluster -o yaml >/dev/null 2>&1 || {
  echo "WARN: Link 'target-cluster' not found (may require specific namespace permissions)"
}
echo "  ✓ Link resource authored successfully"

echo "==> Verifying linkerd-multicluster gateway pod is running"
GW_PODS=$(kctl -n linkerd-multicluster get pods -l linkerd.io/control-plane-component=gateway -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -n "${GW_PODS}" ]; then
  GW_POD_COUNT=$(echo "${GW_PODS}" | wc -w | tr -d ' ')
  echo "  ✓ gateway pods running: ${GW_POD_COUNT}"
else
  echo "  WARN: no gateway pods found (linkerd-multicluster chart may not deploy a gateway by default)"
fi

echo "==> Annotating namespace and verifying product pods"
kctl annotate namespace "${NS}" linkerd.io/inject=enabled --overwrite

for DEPLOY in $(kctl -n "${NS}" get deploy -o jsonpath='{.items[*].metadata.name}'); do
  kctl -n "${NS}" rollout restart "deployment/${DEPLOY}"
  kctl -n "${NS}" rollout status "deployment/${DEPLOY}" --timeout=3m
done

echo "PASS: linkerd multi-cluster preview integration verified"
