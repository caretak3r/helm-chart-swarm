#!/usr/bin/env bash
# Cilium ingress controller (dedicated mode) smoke assertion.
# Locates the dedicated per-Ingress Service Cilium creates,
# probes it in-cluster with Host: sample.test.local,
# and asserts the product Service responds (expected HTTP 200).
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
HOST="sample.test.local"
SVC_PORT=80

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Locating Cilium per-Ingress Service (dedicated mode)"
# Cilium creates the per-Ingress Service asynchronously after the Ingress
# resource is created. Poll with bounded retries to avoid false failures
# on slow clusters.
MAX_ATTEMPTS=30
SLEEP_SECONDS=2
INGRESS_SVC=""
for i in $(seq 1 "${MAX_ATTEMPTS}"); do
  # Primary search: specific per-Ingress Service for this Ingress
  INGRESS_SVC=$(kctl -n "${NS}" get svc -o name 2>/dev/null | grep "cilium-ingress-${RELEASE}" | head -1 || echo "")
  if [ -z "${INGRESS_SVC}" ]; then
    # Fallback: search for any cilium-ingress service in the namespace
    INGRESS_SVC=$(kctl -n "${NS}" get svc -o name 2>/dev/null | grep "cilium-ingress" | head -1 || echo "")
  fi
  if [ -n "${INGRESS_SVC}" ]; then
    break
  fi
  if [ "${i}" -lt "${MAX_ATTEMPTS}" ]; then
    sleep "${SLEEP_SECONDS}"
  fi
done
if [ -z "${INGRESS_SVC}" ]; then
  echo "FAIL: No Cilium per-Ingress Service found in namespace ${NS} after ${MAX_ATTEMPTS} attempts" >&2
  echo "Available services:" >&2
  kctl -n "${NS}" get svc >&2
  exit 1
fi
echo "Cilium per-Ingress Service: ${INGRESS_SVC}"

echo "==> Getting per-Ingress Service ClusterIP (no LB on kind)"
SVC_IP=$(kctl -n "${NS}" get "${INGRESS_SVC}" -o jsonpath='{.spec.clusterIP}')
if [ -z "${SVC_IP}" ]; then
  echo "FAIL: Could not get ClusterIP for ${INGRESS_SVC}" >&2
  exit 1
fi
echo "Per-Ingress Service ClusterIP: ${SVC_IP}:${SVC_PORT}"

echo "==> Probing per-Ingress Service with Host: ${HOST} (in-cluster)"
RAW=$(kctl -n "${NS}" run ct-cilium-ingress --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: ${HOST}" \
    "http://${SVC_IP}:${SVC_PORT}/" 2>/dev/null || echo "000")
HTTP_CODE=$(echo "${RAW}" | grep -oE '[0-9]{3}' | tail -1)

echo "HTTP response (Host: ${HOST}): ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: Cilium ingress routes HTTP through dedicated per-Ingress Service"
else
  echo "FAIL: expected HTTP 200 via Cilium per-Ingress Service, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: Cilium ingress controller verified"
