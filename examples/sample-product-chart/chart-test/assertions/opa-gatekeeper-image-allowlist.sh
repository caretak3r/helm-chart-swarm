#!/usr/bin/env bash
# OPA Gatekeeper image-allowlist smoke assertion.
# Verifies: ConstraintTemplate k8sallowedrepos Established,
#           non-allowlisted image Deployment denied (stderr names disallowed registry),
#           allowlisted image Deployment accepted.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
GK_NS="gatekeeper-system"
FIXTURES="${PROJECT_DIR:-.}/chart-test/fixtures/policy"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "=== OPA Gatekeeper: Image Allowlist ==="

echo "==> Phase 0: Wait for gatekeeper controller pods Ready"
kctl -n "${GK_NS}" wait pod -l control-plane=controller-manager --for=condition=Ready --timeout=3m
echo "PASS: gatekeeper controller Ready"

kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=2m
echo "PASS: product pod Ready"

echo "==> Phase 1: Verify ConstraintTemplate applied"
CT_NAME="k8sallowedrepos"
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
kctl wait "crd/k8sallowedrepos.constraints.gatekeeper.sh" --for=condition=Established --timeout=90s
echo "PASS: CRD k8sallowedrepos.constraints.gatekeeper.sh Established=True"

echo "==> Apply Constraint"
kctl apply -f "${FIXTURES}/k8sallowedrepos-constraint.yaml"
echo "PASS: K8sAllowedRepos constraint applied"

sleep 8  # gatekeeper webhook sync lag after constraint creation

echo "==> Phase 2a: Non-allowlisted image Deployment (docker.io/library/redis)"
if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-noncompliant-image.yaml" 2>&1 | tee /tmp/gk-bad-image.txt; then
  echo "FAIL: non-allowlisted image Deployment was NOT rejected" >&2
  exit 1
else
  if grep -q "admission webhook.*denied" /tmp/gk-bad-image.txt 2>/dev/null && \
     grep -qi "disallowed\|redis" /tmp/gk-bad-image.txt 2>/dev/null; then
    echo "PASS: non-allowlisted image Deployment rejected (disallowed registry)"
  else
    echo "FAIL: rejection did not name disallowed registry" >&2
    cat /tmp/gk-bad-image.txt >&2
    exit 1
  fi
fi

echo "==> Phase 2b: Allowlisted image Deployment (nginx)"
if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-allowlisted-image.yaml" 2>&1; then
  echo "PASS: allowlisted image Deployment accepted"
else
  echo "FAIL: allowlisted image Deployment was rejected" >&2
  exit 1
fi

echo "PASS: OPA Gatekeeper image-allowlist integration verified"
