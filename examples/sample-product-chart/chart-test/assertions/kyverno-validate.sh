#!/usr/bin/env bash
# Kyverno validate smoke assertion.
# Verifies: ClusterPolicy require-app-label reconciled,
#           non-compliant Deployment denied (stderr names webhook + policy),
#           compliant Deployment accepted.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
KYVERNO_NS="kyverno"
FIXTURES="${PROJECT_DIR:-.}/chart-test/fixtures/policy"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "=== Kyverno: Validate (require-app-label) ==="

echo "==> Phase 0: Wait for kyverno admission controller pods Ready"
kctl -n "${KYVERNO_NS}" wait pod -l app.kubernetes.io/part-of=kyverno --for=condition=Ready --timeout=3m
echo "PASS: kyverno controller pods Ready"

kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=2m
echo "PASS: product pods Ready"

echo "==> Phase 1: Verify ClusterPolicy applied"
POLICY_NAME="require-app-label"
echo "Waiting for ClusterPolicy ${POLICY_NAME} to be ready (30s max)..."
kctl wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True "clusterpolicy/${POLICY_NAME}" --timeout=30s
echo "PASS: ClusterPolicy ${POLICY_NAME} Ready=True"

echo "==> Wait for webhook sync (8s)"
sleep 8

echo "==> Phase 2a: Non-compliant Deployment (missing app.kubernetes.io/name label)"
if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-noncompliant-kyverno.yaml" 2>&1 | tee /tmp/kyverno-validate-noncompliant.txt; then
  echo "FAIL: non-compliant Deployment was NOT rejected" >&2
  exit 1
else
  EXIT_CODE=$?
  if grep -qi "denied\|validate.kyverno.svc" /tmp/kyverno-validate-noncompliant.txt 2>/dev/null; then
    echo "PASS: non-compliant Deployment rejected (admission webhook denied)"
  else
    echo "FAIL: rejection did not reference kyverno admission webhook or policy" >&2
    cat /tmp/kyverno-validate-noncompliant.txt >&2
    exit 1
  fi
fi

echo "==> Phase 2b: Compliant Deployment (has app.kubernetes.io/name label)"
if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-compliant-kyverno.yaml" 2>&1; then
  echo "PASS: compliant Deployment accepted"
else
  echo "FAIL: compliant Deployment was rejected" >&2
  exit 1
fi

echo "PASS: Kyverno validate variant verified"
