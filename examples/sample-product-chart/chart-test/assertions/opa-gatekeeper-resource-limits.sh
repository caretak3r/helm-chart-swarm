#!/usr/bin/env bash
# OPA Gatekeeper resource-limits smoke assertion.
# Verifies: ConstraintTemplate k8scontainerlimits Established,
#           Deployment without resources.limits denied with K8sContainerLimits message,
#           Compliant Deployment with limits accepted.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
GK_NS="gatekeeper-system"
FIXTURES="${PROJECT_DIR:-.}/chart-test/fixtures/policy"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "=== OPA Gatekeeper: Resource Limits ==="

echo "==> Phase 0: Wait for gatekeeper controller pods Ready"
kctl -n "${GK_NS}" wait pod -l control-plane=controller-manager --for=condition=Ready --timeout=3m
echo "PASS: gatekeeper controller Ready"

kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=2m
echo "PASS: product pod Ready"

echo "==> Phase 1: Verify ConstraintTemplate applied"
CT_NAME="k8scontainerlimits"
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
kctl wait "crd/k8scontainerlimits.constraints.gatekeeper.sh" --for=condition=Established --timeout=90s
echo "PASS: CRD k8scontainerlimits.constraints.gatekeeper.sh Established=True"

echo "==> Apply Constraint"
kctl apply -f "${FIXTURES}/k8scontainerlimits-constraint.yaml"
echo "PASS: K8sContainerLimits constraint applied"

sleep 8  # gatekeeper webhook sync lag after constraint creation

echo "==> Phase 2a: Deployment without resources.limits"
if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-noncompliant-limits.yaml" 2>&1 | tee /tmp/gk-no-limits.txt; then
  echo "FAIL: Deployment without limits was NOT rejected" >&2
  exit 1
else
  if grep -q "admission webhook.*denied" /tmp/gk-no-limits.txt 2>/dev/null && \
     grep -q "missing" /tmp/gk-no-limits.txt 2>/dev/null; then
    echo "PASS: Deployment without limits rejected with K8sContainerLimits message"
  else
    echo "FAIL: rejection did not contain container limits violation" >&2
    cat /tmp/gk-no-limits.txt >&2
    exit 1
  fi
fi

echo "==> Phase 2b: Compliant Deployment with resources.limits"
if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-compliant.yaml" 2>&1; then
  echo "PASS: compliant Deployment accepted"
else
  echo "FAIL: compliant Deployment was rejected" >&2
  exit 1
fi

echo "PASS: OPA Gatekeeper resource-limits integration verified"
