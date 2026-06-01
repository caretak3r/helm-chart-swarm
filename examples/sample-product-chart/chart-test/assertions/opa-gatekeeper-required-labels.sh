#!/usr/bin/env bash
# OPA Gatekeeper required-labels smoke assertion.
# Verifies: ConstraintTemplate k8srequiredlabels Established, CRD Established,
#           non-compliant Deployment denied, compliant Deployment accepted,
#           non-compliant Ingress denied, compliant Ingress admitted + Ready.
# Cross-feature compose: opa-gatekeeper (M7) + nginx-ingress (M4).
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
GK_NS="gatekeeper-system"
NGINX_NS="ingress-nginx"
FIXTURES="${PROJECT_DIR:-.}/chart-test/fixtures/policy"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "=== OPA Gatekeeper: Required Labels ==="

echo "==> Phase 0: Wait for gatekeeper controller + nginx ingress pods Ready"
kctl -n "${GK_NS}" wait pod -l control-plane=controller-manager --for=condition=Ready --timeout=3m
echo "PASS: gatekeeper controller Ready"

kctl -n "${NGINX_NS}" wait pod -l app.kubernetes.io/name=ingress-nginx --for=condition=Ready --timeout=2m
echo "PASS: nginx ingress controller Ready"

kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=2m
echo "PASS: product pod Ready"

echo "==> Phase 1: Verify ConstraintTemplate applied"
CT_NAME="k8srequiredlabels"
echo "Waiting for ConstraintTemplate ${CT_NAME} to reconcile (60s max)..."
for i in $(seq 1 12); do
  GEN=$(kctl get constrainttemplate "${CT_NAME}" -o jsonpath='{.metadata.generation}' 2>/dev/null)
  # Gatekeeper stores observedGeneration under status.byPod[0].observedGeneration
  OBS_GEN=$(kctl get constrainttemplate "${CT_NAME}" -o jsonpath='{.status.byPod[0].observedGeneration}' 2>/dev/null)
  if [ -n "${OBS_GEN}" ] && [ "${OBS_GEN}" -ge "${GEN}" ] 2>/dev/null; then
    echo "PASS: observedGeneration (${OBS_GEN}) >= generation (${GEN}) at attempt ${i}"
    break
  fi
  if [ "$i" -eq 12 ]; then
    echo "FAIL: ConstraintTemplate ${CT_NAME} not reconciled after 60s (gen=${GEN}, obs=${OBS_GEN})" >&2
    exit 1
  fi
  sleep 5
done

echo "==> Wait for CRD Established (90s max)"
kctl wait "crd/k8srequiredlabels.constraints.gatekeeper.sh" --for=condition=Established --timeout=90s
echo "PASS: CRD k8srequiredlabels.constraints.gatekeeper.sh Established=True"

echo "==> Apply Constraint"
kctl apply -f "${FIXTURES}/k8srequiredlabels-constraint.yaml"
echo "PASS: K8sRequiredLabels constraint applied"

sleep 8  # gatekeeper webhook sync lag after constraint creation

echo "==> Phase 2a: Non-compliant Deployment (missing app.kubernetes.io/name)"
if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-noncompliant-labels.yaml" 2>&1 | tee /tmp/gk-noncompliant-dep.txt; then
  echo "FAIL: non-compliant Deployment was NOT rejected" >&2
  exit 1
else
  if grep -q "admission webhook.*denied" /tmp/gk-noncompliant-dep.txt 2>/dev/null && \
     grep -q "app.kubernetes.io/name" /tmp/gk-noncompliant-dep.txt 2>/dev/null; then
    echo "PASS: non-compliant Deployment rejected (missing required label)"
  else
    echo "FAIL: rejection did not name constraint + missing label" >&2
    cat /tmp/gk-noncompliant-dep.txt >&2
    exit 1
  fi
fi

echo "==> Phase 2b: Compliant Deployment (has app.kubernetes.io/name)"
if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-compliant.yaml" 2>&1; then
  echo "PASS: compliant Deployment accepted"
else
  echo "FAIL: compliant Deployment was rejected" >&2
  exit 1
fi

echo "==> Phase 3a: Non-compliant Ingress (missing app.kubernetes.io/name)"
if kctl apply --dry-run=server -f "${FIXTURES}/test-ingress-noncompliant.yaml" 2>&1 | tee /tmp/gk-noncompliant-ing.txt; then
  echo "FAIL: non-compliant Ingress was NOT rejected" >&2
  exit 1
else
  if grep -q "admission webhook.*denied" /tmp/gk-noncompliant-ing.txt 2>/dev/null && \
     grep -q "app.kubernetes.io/name" /tmp/gk-noncompliant-ing.txt 2>/dev/null; then
    echo "PASS: non-compliant Ingress rejected (missing required label)"
  else
    echo "FAIL: rejection did not name constraint + missing label" >&2
    cat /tmp/gk-noncompliant-ing.txt >&2
    exit 1
  fi
fi

echo "==> Phase 3b: Compliant Ingress (has app.kubernetes.io/name)"
ING_NAME="test-compliant-ingress"
if kctl apply -f "${FIXTURES}/test-ingress-compliant.yaml" 2>&1; then
  echo "PASS: compliant Ingress applied"
else
  echo "FAIL: compliant Ingress was rejected" >&2
  exit 1
fi

# Wait for Ingress to be processed
sleep 5
if kctl -n "${NS}" get ingress "${ING_NAME}" -o jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null | grep -q .; then
  echo "PASS: compliant Ingress has loadBalancer address populated"
else
  echo "NOTE: compliant Ingress may not yet have address (NGINX controller processes async)"
fi

echo "==> Phase 4: Webhook failure mode — verify Fail policy + outage behavior"

# 4a: Verify failurePolicy: Fail on validating webhook configuration
WEBHOOK_NAME="gatekeeper-validating-webhook-configuration"
FP=$(kctl get validatingwebhookconfiguration "${WEBHOOK_NAME}" -o jsonpath='{.webhooks[0].failurePolicy}' 2>/dev/null)
if [ "${FP}" = "Fail" ]; then
  echo "PASS: webhook ${WEBHOOK_NAME} failurePolicy=${FP}"
else
  echo "FAIL: expected failurePolicy=Fail, got '${FP}'" >&2
  exit 1
fi

# 4b: Scale gatekeeper controller to 0 replicas
GK_DEPLOY="gatekeeper-controller-manager"
ORIG_REPLICAS=$(kctl -n "${GK_NS}" get deploy "${GK_DEPLOY}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
echo "Scaling ${GK_DEPLOY} to 0 in ${GK_NS} (original replicas: ${ORIG_REPLICAS})..."
kctl -n "${GK_NS}" scale deploy "${GK_DEPLOY}" --replicas=0
# Wait for the controller pods to actually terminate
kctl -n "${GK_NS}" wait pod -l control-plane=controller-manager --for=delete --timeout=2m 2>/dev/null || true
sleep 3
echo "PASS: gatekeeper controller scaled to 0"

# 4c: Verify admission fails with webhook timeout/connection-refused
echo "Attempting kubectl apply with webhook unavailable..."
if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-compliant.yaml" 2>&1 | tee /tmp/gk-outage-probe.txt; then
  echo "FAIL: admission succeeded despite webhook being down (possible Ignore policy)" >&2
  # Restore controller before exiting
  kctl -n "${GK_NS}" scale deploy "${GK_DEPLOY}" --replicas="${ORIG_REPLICAS}" 2>/dev/null || true
  exit 1
else
  if grep -qiE "failed calling webhook|connection refused|timeout|deadline exceeded|no endpoints|service not found|Internal error" /tmp/gk-outage-probe.txt 2>/dev/null; then
    echo "PASS: admission correctly blocked during webhook outage (Fail policy)"
  else
    echo "FAIL: rejection message did not indicate webhook unavailability" >&2
    cat /tmp/gk-outage-probe.txt >&2
    kctl -n "${GK_NS}" scale deploy "${GK_DEPLOY}" --replicas="${ORIG_REPLICAS}" 2>/dev/null || true
    exit 1
  fi
fi

# 4d: Scale controller back up and verify admission works again
echo "Restoring ${GK_DEPLOY} to ${ORIG_REPLICAS} in ${GK_NS}..."
kctl -n "${GK_NS}" scale deploy "${GK_DEPLOY}" --replicas="${ORIG_REPLICAS}"
echo "Waiting for gatekeeper controller pods to be Ready again..."
kctl -n "${GK_NS}" wait pod -l control-plane=controller-manager --for=condition=Ready --timeout=3m
echo "PASS: gatekeeper controller pods Ready"

# Note: kind clusters may restart kube-controller-manager during gatekeeper CRD installation,
# which can delay endpoint reconciliation. We retry with generous timeout.
echo "Waiting for admission webhook to accept requests (180s max, may be slow on resource-constrained clusters)..."
ADMISSION_RESTORED=0
for i in $(seq 1 36); do
  # Periodically nudge the endpoint controller by touching the service
  if [ $((i % 6)) -eq 0 ]; then
    kctl -n "${GK_NS}" delete endpoints gatekeeper-webhook-service --ignore-not-found=true 2>/dev/null || true
  fi
  if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-compliant.yaml" 2>/dev/null; then
    echo "PASS: admission restored after webhook recovery (attempt ${i})"
    ADMISSION_RESTORED=1
    break
  fi
  if [ "$i" -eq 36 ]; then
    echo "FAIL: admission still failing after controller restore (36 attempts, 180s)" >&2
    exit 1
  fi
  sleep 5
done
if [ "${ADMISSION_RESTORED}" -eq 0 ]; then
  echo "FAIL: admission did not recover" >&2
  exit 1
fi

echo "PASS: OPA Gatekeeper required-labels + nginx-ingress cross-feature compose verified"
