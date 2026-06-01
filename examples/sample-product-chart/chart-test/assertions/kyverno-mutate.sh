#!/usr/bin/env bash
# Kyverno mutate smoke assertion.
# Verifies: ClusterPolicy add-managed-by-annotation reconciled,
#           Pod manifest lacking annotation gets it auto-added by mutating webhook.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
KYVERNO_NS="kyverno"
FIXTURES="${PROJECT_DIR:-.}/chart-test/fixtures/policy"
POD_NAME="test-mutate-kyverno"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "=== Kyverno: Mutate (add-managed-by-annotation) ==="

echo "==> Phase 0: Wait for kyverno admission controller pods Ready"
kctl -n "${KYVERNO_NS}" wait pod -l app.kubernetes.io/part-of=kyverno --for=condition=Ready --timeout=3m
echo "PASS: kyverno controller pods Ready"

kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=2m
echo "PASS: product pods Ready"

echo "==> Phase 1: Verify ClusterPolicy applied"
POLICY_NAME="add-managed-by-annotation"
echo "Waiting for ClusterPolicy ${POLICY_NAME} to be ready (30s max)..."
kctl wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True "clusterpolicy/${POLICY_NAME}" --timeout=30s
echo "PASS: ClusterPolicy ${POLICY_NAME} Ready=True"

echo "==> Clean up any prior test pod"
kctl -n "${NS}" delete pod "${POD_NAME}" --ignore-not-found --wait 2>/dev/null || true
sleep 2

echo "==> Phase 2: Apply Pod manifest (lacking target annotation)"
kctl -n "${NS}" apply -f "${FIXTURES}/test-pod-no-annotation-kyverno.yaml"
echo "PASS: Pod ${POD_NAME} applied"

echo "==> Wait for Pod to be Ready (30s max)"
kctl -n "${NS}" wait pod "${POD_NAME}" --for=condition=Ready --timeout=30s
echo "PASS: Pod ${POD_NAME} Ready"

echo "==> Phase 3: Verify annotation auto-added by mutating webhook"
ANNOTATION=$(kctl -n "${NS}" get pod "${POD_NAME}" -o jsonpath='{.metadata.annotations.kyverno\.io/managed-by}' 2>/dev/null)
if [ "${ANNOTATION}" = "chart-test-swarm" ]; then
  echo "PASS: annotation kyverno.io/managed-by=chart-test-swarm auto-added by mutating webhook"
else
  echo "FAIL: expected annotation 'chart-test-swarm', got '${ANNOTATION}'" >&2
  kctl -n "${NS}" get pod "${POD_NAME}" -o jsonpath='{.metadata.annotations}' >&2
  exit 1
fi

echo "==> Clean up test pod"
kctl -n "${NS}" delete pod "${POD_NAME}" --ignore-not-found --wait 2>/dev/null || true

echo "PASS: Kyverno mutate variant verified"
