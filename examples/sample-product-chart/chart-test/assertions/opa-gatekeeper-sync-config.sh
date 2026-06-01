#!/usr/bin/env bash
# OPA Gatekeeper sync-config smoke assertion.
# Verifies: Gatekeeper Config resource in gatekeeper-system has non-empty spec.sync.syncOnly,
#           gatekeeper controller pod is Ready.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
GK_NS="gatekeeper-system"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "=== OPA Gatekeeper: Sync Config ==="

echo "==> Phase 0: Wait for gatekeeper controller pods Ready"
kctl -n "${GK_NS}" wait pod -l control-plane=controller-manager --for=condition=Ready --timeout=3m
echo "PASS: gatekeeper controller Ready"

kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=2m
echo "PASS: product pod Ready"

echo "==> Phase 1: Verify Gatekeeper Config exists"
CONFIG_NAME="config"
if kctl -n "${GK_NS}" get config "${CONFIG_NAME}" -o yaml 2>/dev/null | tee /tmp/gk-config.yaml; then
  echo "PASS: Gatekeeper Config resource '${CONFIG_NAME}' exists"
else
  echo "FAIL: Gatekeeper Config resource '${CONFIG_NAME}' not found" >&2
  exit 1
fi

echo "==> Phase 2: Verify spec.sync.syncOnly is non-empty"
SYNC_COUNT=$(kctl -n "${GK_NS}" get config "${CONFIG_NAME}" -o jsonpath='{.spec.sync.syncOnly}' | jq 'length')
echo "syncOnly entry count: ${SYNC_COUNT}"
if [ "${SYNC_COUNT}" -gt 0 ] 2>/dev/null; then
  echo "PASS: spec.sync.syncOnly has ${SYNC_COUNT} entries (non-empty)"
  kctl -n "${GK_NS}" get config "${CONFIG_NAME}" -o jsonpath='{.spec.sync.syncOnly[*].kind}' | tr ' ' '\n' | sort
else
  echo "FAIL: spec.sync.syncOnly is empty or missing" >&2
  exit 1
fi

echo "==> Phase 3: Verify syncOnly includes expected kinds"
SYNC_KINDS=$(kctl -n "${GK_NS}" get config "${CONFIG_NAME}" -o jsonpath='{.spec.sync.syncOnly[*].kind}')
echo "${SYNC_KINDS}" | grep -q "Namespace" || { echo "FAIL: syncOnly missing Namespace kind" >&2; exit 1; }
echo "${SYNC_KINDS}" | grep -q "Pod"       || { echo "FAIL: syncOnly missing Pod kind" >&2; exit 1; }
echo "${SYNC_KINDS}" | grep -q "Ingress"   || { echo "FAIL: syncOnly missing Ingress kind" >&2; exit 1; }
echo "PASS: syncOnly includes Namespace, Pod, and Ingress kinds"

echo "PASS: OPA Gatekeeper sync-config integration verified"
