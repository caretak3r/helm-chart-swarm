#!/usr/bin/env bash
# Istio PeerAuthentication lifecycle smoke assertion.
# Verifies: PERMISSIVE mode allows both mesh and non-mesh traffic;
# switching to STRICT blocks non-mesh while mesh traffic continues.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SVC_PORT="${SERVICE_PORT:-80}"
CTRL_NS="${NS}-plain"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Labeling namespace ${NS} for istio injection"
kctl label namespace "${NS}" istio-injection=enabled --overwrite || true

echo "==> Restarting deployments to pick up sidecar injection"
for DEPLOY in $(kctl -n "${NS}" get deploy -o jsonpath='{.items[*].metadata.name}'); do
  echo "  Restarting deployment/${DEPLOY}"
  kctl -n "${NS}" rollout restart "deployment/${DEPLOY}"
  echo "  Waiting for rollout of deployment/${DEPLOY} to complete (3m max)"
  kctl -n "${NS}" rollout status "deployment/${DEPLOY}" --timeout=3m
done
echo "PASS: all deployments rolled out with sidecars"

echo "==> Creating non-mesh namespace ${CTRL_NS} (no injection label)"
kctl create namespace "${CTRL_NS}" --dry-run=client -o yaml | kctl apply -f -

echo "==> Creating non-mesh probe pod in ${CTRL_NS}"
kctl -n "${CTRL_NS}" run ct-nonmesh --restart=Never \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  sleep 300 2>/dev/null || true
kctl -n "${CTRL_NS}" wait pod ct-nonmesh --for=condition=Ready --timeout=60s || true

echo "==> Creating in-mesh probe pod in ${NS} with sidecar"
kctl -n "${NS}" run ct-mesh-probe --restart=Never \
  --image=quay.io/curl/curl:8.6.0 --timeout=60s \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"true"}}}' -- \
  sleep 300 2>/dev/null || true
echo "  Waiting for in-mesh probe pod to be ready (2m max)"
kctl -n "${NS}" wait pod ct-mesh-probe --for=condition=Ready --timeout=2m || {
  echo "WARN: in-mesh probe pod not ready; proceeding anyway"
}

PRODUCT_SVC="${RELEASE}.${NS}.svc.cluster.local"

# ------------------------------------------------------------------
# Phase 1: PERMISSIVE mode — both mesh and non-mesh traffic allowed
# ------------------------------------------------------------------
echo "==> Phase 1: Applying PeerAuthentication PERMISSIVE"
kctl -n "${NS}" apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: ${RELEASE}-perm
  namespace: ${NS}
spec:
  mtls:
    mode: PERMISSIVE
EOF

echo "==> Verifying PeerAuthentication PERMISSIVE"
PA_MODE=$(kctl -n "${NS}" get peerauthentication "${RELEASE}-perm" -o jsonpath='{.spec.mtls.mode}')
echo "PeerAuthentication mode: ${PA_MODE}"
if [ "${PA_MODE}" = "PERMISSIVE" ]; then
  echo "PASS: PeerAuthentication mode is PERMISSIVE"
else
  echo "FAIL: expected mode=PERMISSIVE, got ${PA_MODE}" >&2
  exit 1
fi

echo "==> Waiting 10s for policy propagation"
sleep 10

echo "==> Phase 1a: Non-mesh probe under PERMISSIVE (expect 200)"
RAW_NM1=$(kctl -n "${CTRL_NS}" exec ct-nonmesh -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "http://${PRODUCT_SVC}:${SVC_PORT}/" 2>/dev/null || echo "000")
NM1=$(echo "$RAW_NM1" | tail -1 | grep -oE '[0-9]{3}' | tail -1)
echo "Non-mesh HTTP under PERMISSIVE: ${NM1}"
if [ "${NM1}" = "200" ]; then
  echo "PASS: non-mesh traffic allowed under PERMISSIVE"
else
  echo "FAIL: expected HTTP 200 from non-mesh pod under PERMISSIVE, got ${NM1}" >&2
  exit 1
fi

echo "==> Phase 1b: In-mesh probe under PERMISSIVE (expect 200)"
RAW_M1=$(kctl -n "${NS}" exec ct-mesh-probe -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "http://${PRODUCT_SVC}:${SVC_PORT}/" 2>/dev/null || echo "000")
M1=$(echo "$RAW_M1" | tail -1 | grep -oE '[0-9]{3}' | tail -1)
echo "In-mesh HTTP under PERMISSIVE: ${M1}"
if [ "${M1}" = "200" ]; then
  echo "PASS: in-mesh traffic allowed under PERMISSIVE"
else
  echo "FAIL: expected HTTP 200 from in-mesh pod under PERMISSIVE, got ${M1}" >&2
  exit 1
fi

# ------------------------------------------------------------------
# Phase 2: STRICT mode — non-mesh blocked, mesh still works
# ------------------------------------------------------------------
echo "==> Phase 2: Updating PeerAuthentication to STRICT"
kctl -n "${NS}" apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: ${RELEASE}-perm
  namespace: ${NS}
spec:
  mtls:
    mode: STRICT
EOF

echo "==> Verifying PeerAuthentication STRICT"
PA_MODE2=$(kctl -n "${NS}" get peerauthentication "${RELEASE}-perm" -o jsonpath='{.spec.mtls.mode}')
echo "PeerAuthentication mode: ${PA_MODE2}"
if [ "${PA_MODE2}" = "STRICT" ]; then
  echo "PASS: PeerAuthentication updated to STRICT"
else
  echo "FAIL: expected mode=STRICT, got ${PA_MODE2}" >&2
  exit 1
fi

echo "==> Waiting 10s for mTLS policy propagation"
sleep 10

echo "==> Phase 2a: Non-mesh probe under STRICT (expect rejection)"
RAW_NM2=$(kctl -n "${CTRL_NS}" exec ct-nonmesh -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "http://${PRODUCT_SVC}:${SVC_PORT}/" 2>/dev/null || echo "000")
NM2=$(echo "$RAW_NM2" | tail -1 | grep -oE '[0-9]{3}' | tail -1)
echo "Non-mesh HTTP under STRICT: ${NM2}"
if [ "${NM2}" = "200" ]; then
  echo "FAIL: plain HTTP from non-mesh pod succeeded under STRICT" >&2
  exit 1
else
  echo "PASS: non-mesh traffic rejected under STRICT (code=${NM2})"
fi

echo "==> Phase 2b: In-mesh probe under STRICT (expect 200)"
RAW_M2=$(kctl -n "${NS}" exec ct-mesh-probe -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "http://${PRODUCT_SVC}:${SVC_PORT}/" 2>/dev/null || echo "000")
M2=$(echo "$RAW_M2" | tail -1 | grep -oE '[0-9]{3}' | tail -1)
echo "In-mesh HTTP under STRICT: ${M2}"
if [ "${M2}" = "200" ]; then
  echo "PASS: in-mesh traffic still works under STRICT via auto-upgraded mTLS"
else
  echo "FAIL: expected HTTP 200 from in-mesh pod under STRICT, got ${M2}" >&2
  exit 1
fi

echo "==> Cleaning up pods and control namespace"
kctl -n "${CTRL_NS}" delete pod ct-nonmesh --ignore-not-found --timeout=30s || true
kctl -n "${NS}" delete pod ct-mesh-probe --ignore-not-found --timeout=30s || true
kctl delete namespace "${CTRL_NS}" --ignore-not-found --timeout=30s || true

echo "PASS: istio PeerAuthentication lifecycle verified"
