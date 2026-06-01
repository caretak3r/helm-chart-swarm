#!/usr/bin/env bash
# Kyverno generate smoke assertion.
# Verifies: ClusterPolicy generate-configmap-on-ns reconciled,
#           creating a labeled namespace triggers ConfigMap generation within 10s.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
KYVERNO_NS="kyverno"
GEN_NS="kyverno-gen-test"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "=== Kyverno: Generate (ConfigMap on namespace) ==="

echo "==> Phase 0: Wait for kyverno controllers Ready"
kctl -n "${KYVERNO_NS}" wait pod -l app.kubernetes.io/part-of=kyverno --for=condition=Ready --timeout=3m
echo "PASS: kyverno controller pods Ready"

kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=2m
echo "PASS: product pods Ready"

echo "==> Phase 1: Verify ClusterPolicy applied"
POLICY_NAME="generate-configmap-on-ns"
echo "Waiting for ClusterPolicy ${POLICY_NAME} to be ready (30s max)..."
kctl wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True "clusterpolicy/${POLICY_NAME}" --timeout=30s
echo "PASS: ClusterPolicy ${POLICY_NAME} Ready=True"

echo "==> Clean up any prior test namespace"
kctl delete ns "${GEN_NS}" --ignore-not-found --wait 2>/dev/null || true
sleep 3

echo "==> Phase 2: Create namespace labeled kyverno.io/generate=true"
kctl create ns "${GEN_NS}" --dry-run=client -o yaml | \
  kctl label -f - --local --dry-run=client -o yaml kyverno.io/generate=true | \
  kctl apply -f -
kctl label ns "${GEN_NS}" kyverno.io/generate=true --overwrite 2>/dev/null || true
echo "PASS: namespace ${GEN_NS} created with trigger label"

echo "==> Phase 3: Wait for ConfigMap to be generated (10s max)"
CM_NAME="kyverno-generated-config"
for i in $(seq 1 10); do
  if kctl -n "${GEN_NS}" get configmap "${CM_NAME}" -o name 2>/dev/null; then
    echo "PASS: ConfigMap ${CM_NAME} generated in namespace ${GEN_NS} at attempt ${i}"
    break
  fi
  if [ "$i" -eq 10 ]; then
    echo "FAIL: ConfigMap ${CM_NAME} not generated after 10s" >&2
    kctl -n "${GEN_NS}" get configmap 2>/dev/null || echo "(no ConfigMaps found)"
    exit 1
  fi
  sleep 1
done

echo "==> Phase 4: Verify ConfigMap data"
GEN_BY=$(kctl -n "${GEN_NS}" get configmap "${CM_NAME}" -o jsonpath='{.data.generated-by}' 2>/dev/null)
if [ "${GEN_BY}" = "kyverno" ]; then
  echo "PASS: ConfigMap data.generated-by=kyverno confirmed"
else
  echo "FAIL: expected data.generated-by=kyverno, got '${GEN_BY}'" >&2
  kctl -n "${GEN_NS}" get configmap "${CM_NAME}" -o yaml >&2
  exit 1
fi

echo "==> Clean up test namespace"
kctl delete ns "${GEN_NS}" --ignore-not-found --wait 2>/dev/null || true

echo "PASS: Kyverno generate variant verified"
