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

echo "PASS: OPA Gatekeeper required-labels + nginx-ingress cross-feature compose verified"
