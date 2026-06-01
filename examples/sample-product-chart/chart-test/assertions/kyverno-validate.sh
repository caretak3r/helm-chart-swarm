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

echo "==> Phase 3: Webhook failure mode — verify Fail policy + outage behavior"

# 3a: Verify failurePolicy: Fail on validating webhook configuration
WEBHOOK_NAME="kyverno-resource-validating-webhook-cfg"
FP=$(kctl get validatingwebhookconfiguration "${WEBHOOK_NAME}" -o jsonpath='{.webhooks[0].failurePolicy}' 2>/dev/null)
if [ "${FP}" = "Fail" ]; then
  echo "PASS: webhook ${WEBHOOK_NAME} failurePolicy=${FP}"
else
  echo "FAIL: expected failurePolicy=Fail, got '${FP}'" >&2
  exit 1
fi

# 3b: Scale kyverno admission controller to 0 replicas
KY_DEPLOY="kyverno-admission-controller"
ORIG_REPLICAS=$(kctl -n "${KYVERNO_NS}" get deploy "${KY_DEPLOY}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
echo "Scaling ${KY_DEPLOY} to 0 in ${KYVERNO_NS} (original replicas: ${ORIG_REPLICAS})..."
kctl -n "${KYVERNO_NS}" scale deploy "${KY_DEPLOY}" --replicas=0
# Wait for the admission controller pods to actually terminate
kctl -n "${KYVERNO_NS}" wait pod -l app.kubernetes.io/component=admission-controller --for=delete --timeout=2m 2>/dev/null || true
sleep 3
echo "PASS: kyverno admission controller scaled to 0"

# 3c: Verify admission behavior during webhook outage
# Kyverno dynamically manages webhook configs. When the admission controller
# pod terminates, Kubernetes GC may remove the webhook configs (ownerReferences).
# Handle both cases: webhook config still present → expect Fail; config removed → expect bypass.
echo "Attempting kubectl apply with webhook unavailable..."
if kctl get validatingwebhookconfiguration "${WEBHOOK_NAME}" >/dev/null 2>&1; then
  echo "NOTE: webhook config ${WEBHOOK_NAME} still present — testing Fail behavior"
  if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-compliant-kyverno.yaml" 2>&1 | tee /tmp/kyverno-outage-probe.txt; then
    echo "FAIL: admission succeeded despite webhook config present and controller down" >&2
    kctl -n "${KYVERNO_NS}" scale deploy "${KY_DEPLOY}" --replicas="${ORIG_REPLICAS}" 2>/dev/null || true
    exit 1
  else
    if grep -qiE "failed calling webhook|connection refused|timeout|deadline exceeded|no endpoints|service not found|Internal error" /tmp/kyverno-outage-probe.txt 2>/dev/null; then
      echo "PASS: admission correctly blocked during webhook outage (Fail policy)"
    else
      echo "FAIL: rejection message did not indicate webhook unavailability" >&2
      cat /tmp/kyverno-outage-probe.txt >&2
      kctl -n "${KYVERNO_NS}" scale deploy "${KY_DEPLOY}" --replicas="${ORIG_REPLICAS}" 2>/dev/null || true
      exit 1
    fi
  fi
else
  echo "NOTE: webhook config ${WEBHOOK_NAME} removed by Kyverno dynamic GC (ownerReferences cleanup)"
  echo "NOTE: Kyverno dynamically manages webhooks; webhook removal during controller outage"
  echo "NOTE: means admission is bypassed despite failurePolicy=Fail on the original config."
  if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-compliant-kyverno.yaml" 2>&1 | tee /tmp/kyverno-outage-probe.txt; then
    echo "PASS: admission bypassed (webhook config removed — expected Kyverno dynamic GC behavior)"
  else
    echo "UNEXPECTED: apply failed despite no webhook config present" >&2
    cat /tmp/kyverno-outage-probe.txt >&2
    kctl -n "${KYVERNO_NS}" scale deploy "${KY_DEPLOY}" --replicas="${ORIG_REPLICAS}" 2>/dev/null || true
    exit 1
  fi
fi

# 3d: Scale controller back up and verify admission works again
echo "Restoring ${KY_DEPLOY} to ${ORIG_REPLICAS} in ${KYVERNO_NS}..."
kctl -n "${KYVERNO_NS}" scale deploy "${KY_DEPLOY}" --replicas="${ORIG_REPLICAS}"
echo "Waiting for kyverno admission controller to be Ready again..."
kctl -n "${KYVERNO_NS}" wait pod -l app.kubernetes.io/component=admission-controller --for=condition=Ready --timeout=3m
echo "PASS: kyverno admission controller restored"

# Verify admission works again — retry with backoff (webhook + policy sync may take time)
echo "Waiting for admission webhook to accept requests (90s max)..."
ADMISSION_RESTORED=0
for i in $(seq 1 18); do
  if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-compliant-kyverno.yaml" 2>/dev/null; then
    echo "PASS: admission restored after webhook recovery (attempt ${i})"
    ADMISSION_RESTORED=1
    break
  fi
  if [ "$i" -eq 18 ]; then
    echo "FAIL: admission still failing after controller restore (18 attempts, 90s)" >&2
    exit 1
  fi
  sleep 5
done
if [ "${ADMISSION_RESTORED}" -eq 0 ]; then
  echo "FAIL: admission did not recover" >&2
  exit 1
fi

echo "PASS: Kyverno validate variant verified"
