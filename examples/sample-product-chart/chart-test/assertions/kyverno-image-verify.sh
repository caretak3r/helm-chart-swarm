#!/usr/bin/env bash
# Kyverno image-verify smoke assertion.
# Verifies: ClusterPolicy image-registry-allowlist reconciled,
#           Pod with non-allowlisted image denied (stderr names policy),
#           Pod with allowlisted image accepted.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
KYVERNO_NS="kyverno"
FIXTURES="${PROJECT_DIR:-.}/chart-test/fixtures/policy"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "=== Kyverno: Image-Verify (only-approved-registries) ==="

echo "==> Phase 0: Wait for kyverno admission controller pods Ready"
kctl -n "${KYVERNO_NS}" wait pod -l app.kubernetes.io/part-of=kyverno --for=condition=Ready --timeout=3m
echo "PASS: kyverno controller pods Ready"

kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=2m
echo "PASS: product pods Ready"

echo "==> Phase 1: Verify ClusterPolicy applied"
POLICY_NAME="image-registry-allowlist"
echo "Waiting for ClusterPolicy ${POLICY_NAME} to be ready (30s max)..."
kctl wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True "clusterpolicy/${POLICY_NAME}" --timeout=30s
echo "PASS: ClusterPolicy ${POLICY_NAME} Ready=True"

echo "==> Wait for webhook sync (8s)"
sleep 8

echo "==> Phase 2a: Pod with non-allowlisted image (docker.io/library/redis:7-alpine)"
if kctl apply --dry-run=server -f "${FIXTURES}/test-pod-untrusted-image-kyverno.yaml" 2>&1 | tee /tmp/kyverno-image-noncompliant.txt; then
  echo "FAIL: Pod with non-allowlisted image was NOT rejected" >&2
  exit 1
else
  if grep -qi "denied\|only-allowed-registries\|image-registry-allowlist" /tmp/kyverno-image-noncompliant.txt 2>/dev/null; then
    echo "PASS: Pod with non-allowlisted image rejected (admission webhook denied)"
  else
    echo "FAIL: rejection did not reference image-verify policy" >&2
    cat /tmp/kyverno-image-noncompliant.txt >&2
    exit 1
  fi
fi

echo "==> Phase 2b: Pod with allowlisted image (public.ecr.aws/nginx/nginx:1.27-alpine)"
if kctl apply --dry-run=server -f "${FIXTURES}/test-pod-trusted-image-kyverno.yaml" 2>&1; then
  echo "PASS: Pod with allowlisted image accepted"
else
  echo "FAIL: Pod with allowlisted image was rejected" >&2
  exit 1
fi

echo "PASS: Kyverno image-verify variant verified"
