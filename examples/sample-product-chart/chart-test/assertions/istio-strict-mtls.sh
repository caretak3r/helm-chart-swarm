#!/usr/bin/env bash
# Istio strict mTLS smoke assertion.
# Verifies: PeerAuthentication STRICT created in product namespace,
# plain HTTP from non-mesh pod is rejected (non-zero / 503),
# in-mesh probe pod still succeeds with HTTP 200 via auto-upgraded mTLS.
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

echo "==> Applying PeerAuthentication STRICT"
kctl -n "${NS}" apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: ${RELEASE}-mtls
  namespace: ${NS}
spec:
  mtls:
    mode: STRICT
EOF
echo "PASS: PeerAuthentication ${RELEASE}-mtls created with mode=STRICT"

echo "==> Verifying PeerAuthentication resource"
PA_MODE=$(kctl -n "${NS}" get peerauthentication "${RELEASE}-mtls" -o jsonpath='{.spec.mtls.mode}')
echo "PeerAuthentication mode: ${PA_MODE}"
if [ "${PA_MODE}" = "STRICT" ]; then
  echo "PASS: PeerAuthentication mode is STRICT"
else
  echo "FAIL: expected mode=STRICT, got ${PA_MODE}" >&2
  exit 1
fi

echo "==> Waiting 10s for mTLS policy propagation"
sleep 10

echo "==> Creating non-mesh namespace ${CTRL_NS} (no injection label)"
kctl create namespace "${CTRL_NS}" --dry-run=client -o yaml | kctl apply -f -

echo "==> Non-mesh probe: plain HTTP from pod without sidecar (expect failure)"
PRODUCT_SVC="${RELEASE}.${NS}.svc.cluster.local"

# Non-mesh pod: no sidecar, plain HTTP → should be rejected under STRICT
# Create a pod in the non-mesh namespace
kctl -n "${CTRL_NS}" run ct-nonmesh --restart=Never \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  sleep 300 2>/dev/null || true
kctl -n "${CTRL_NS}" wait pod ct-nonmesh --for=condition=Ready --timeout=60s || true

RAW_NONMESH_CODE=$(kctl -n "${CTRL_NS}" exec ct-nonmesh -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "http://${PRODUCT_SVC}:${SVC_PORT}/" 2>/dev/null || echo "000")
NONMESH_CODE=$(echo "$RAW_NONMESH_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1)

echo "HTTP response from non-mesh probe: ${NONMESH_CODE}"
if [ "${NONMESH_CODE}" = "200" ]; then
  echo "FAIL: plain HTTP from non-mesh pod succeeded under STRICT mTLS (should be rejected)" >&2
  exit 1
else
  echo "PASS: plain HTTP from non-mesh pod rejected (code=${NONMESH_CODE})"
fi

echo "==> In-mesh probe: HTTP from pod with sidecar (expect 200)"
# Create a dedicated probe pod with sidecar injection
kctl -n "${NS}" run ct-mesh-probe --restart=Never \
  --image=quay.io/curl/curl:8.6.0 --timeout=60s \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"true"}}}' -- \
  sleep 300 2>/dev/null || true
echo "  Waiting for in-mesh probe pod to be ready (2m max)"
kctl -n "${NS}" wait pod ct-mesh-probe --for=condition=Ready --timeout=2m || {
  echo "WARN: in-mesh probe pod not ready; attempting exec anyway"
}

RAW_MESH_CODE=$(kctl -n "${NS}" exec ct-mesh-probe -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "http://${PRODUCT_SVC}:${SVC_PORT}/" 2>/dev/null || echo "000")
MESH_CODE=$(echo "$RAW_MESH_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1)

echo "HTTP response from in-mesh probe: ${MESH_CODE}"
if [ "${MESH_CODE}" = "200" ]; then
  echo "PASS: in-mesh pod reached product Service with HTTP 200 via auto-upgraded mTLS"
else
  echo "FAIL: expected HTTP 200 from in-mesh probe, got ${MESH_CODE}" >&2
  exit 1
fi

# Clean up probe pods
kctl -n "${CTRL_NS}" delete pod ct-nonmesh --ignore-not-found --timeout=30s || true
kctl -n "${NS}" delete pod ct-mesh-probe --ignore-not-found --timeout=30s || true

echo "==> Cleaning up control namespace"
kctl delete namespace "${CTRL_NS}" --ignore-not-found --timeout=30s || true

echo "PASS: istio strict mTLS integration verified"
