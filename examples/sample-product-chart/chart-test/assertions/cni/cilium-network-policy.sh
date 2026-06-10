#!/usr/bin/env bash
# CiliumNetworkPolicy enforcement smoke assertion.
# Deploys an ALLOWED client pod (label access=allowed) and a DENIED client
# pod (no matching label), then asserts:
#   - Allowed client CAN reach the product Service (HTTP 200)
#   - Denied client CANNOT (connection blocked/timed out)
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SVC_PORT=80
CURL_IMAGE="quay.io/curl/curl:8.20.0"
TIMEOUT=15

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Getting product Service ClusterIP"
SVC_IP=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.clusterIP}')
if [ -z "${SVC_IP}" ]; then
  echo "FAIL: Could not get ClusterIP for Service ${RELEASE}.${NS}" >&2
  exit 1
fi
echo "Product Service ClusterIP: ${SVC_IP}:${SVC_PORT}"

# ---------------------------------------------------------------------------
# ALLOWED client — label access=allowed matches the CiliumNetworkPolicy
# ---------------------------------------------------------------------------
echo "==> Testing ALLOWED client (label access=allowed)"
ALLOWED_RAW=$(kctl -n "${NS}" run ct-cnp-allowed --rm -i --restart=Never --quiet \
  --image="${CURL_IMAGE}" --timeout=60s \
  --labels="access=allowed" -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" \
    "http://${SVC_IP}:${SVC_PORT}/" 2>/dev/null || echo "000")
ALLOWED_CODE=$(echo "${ALLOWED_RAW}" | grep -oE '[0-9]{3}' | tail -1)

echo "ALLOWED client HTTP code: ${ALLOWED_CODE}"
if [ "${ALLOWED_CODE}" = "200" ]; then
  echo "PASS: Allowed client reached the product Service"
else
  echo "FAIL: expected HTTP 200 from allowed client, got ${ALLOWED_CODE}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# DENIED client — no matching label, should be blocked by CiliumNetworkPolicy
# ---------------------------------------------------------------------------
echo "==> Testing DENIED client (no access label)"
DENIED_RAW=$(kctl -n "${NS}" run ct-cnp-denied --rm -i --restart=Never --quiet \
  --image="${CURL_IMAGE}" --timeout=60s \
  -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" \
    "http://${SVC_IP}:${SVC_PORT}/" 2>/dev/null || echo "000")
DENIED_CODE=$(echo "${DENIED_RAW}" | grep -oE '[0-9]{3}' | tail -1)

echo "DENIED client HTTP code: ${DENIED_CODE}"

# The denied client should be blocked: curl either times out (exit 28),
# gets connection reset/refused, or returns 000.  Any response code
# in the 2xx/3xx/4xx range means the policy did NOT enforce the block.
if [ "${DENIED_CODE}" = "000" ] || [ "${DENIED_CODE}" = "028" ]; then
  echo "PASS: Denied client was blocked (no reachable product Service)"
else
  echo "FAIL: denied client reached the product Service (HTTP ${DENIED_CODE}); CiliumNetworkPolicy enforcement not working" >&2
  exit 1
fi

echo "PASS: CiliumNetworkPolicy enforcement verified (allowed=reachable, denied=blocked)"
