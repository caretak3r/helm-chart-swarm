#!/usr/bin/env bash
# Contour basic HTTPProxy smoke assertion.
# Verifies: envoy pod Ready, HTTPProxy routes HTTP with Host header,
#           HTTPProxy status.currentStatus is valid.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
CONTOUR_NS="projectcontour"
HOST="sample.test.local"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for envoy pod Ready (3m max)"
kctl -n "${CONTOUR_NS}" wait pod -l app.kubernetes.io/component=envoy --for=condition=Ready --timeout=3m
echo "PASS: envoy pod Ready"

echo "==> Waiting for contour controller pod Ready (3m max)"
kctl -n "${CONTOUR_NS}" wait pod -l app.kubernetes.io/component=contour --for=condition=Ready --timeout=3m
echo "PASS: contour controller pod Ready"

echo "==> Waiting for product pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: product pods Ready"

echo "==> Getting envoy pod IP (probe via pod IP)"
ENVOY_IP=$(kctl -n "${CONTOUR_NS}" get pod -l app.kubernetes.io/component=envoy -o jsonpath='{.items[0].status.podIP}')
echo "envoy pod IP: ${ENVOY_IP}"

echo "==> Verifying HTTPProxy exists and status is valid"
HTTPPROXY_STATUS=$(kctl -n "${NS}" get httpproxy sample-basic -o jsonpath='{.status.currentStatus}' 2>/dev/null || echo "MISSING")
echo "HTTPProxy status: ${HTTPPROXY_STATUS}"
if [ "${HTTPPROXY_STATUS}" = "valid" ]; then
  echo "PASS: HTTPProxy status is valid"
elif [ "${HTTPPROXY_STATUS}" = "MISSING" ]; then
  echo "FAIL: HTTPProxy sample-basic not found" >&2
  exit 1
else
  echo "FAIL: HTTPProxy status is '${HTTPPROXY_STATUS}', expected 'valid'" >&2
  exit 1
fi

echo "==> Probing HTTP with Host header (expect 200) on envoy container port 8080"
RAW_HTTP_CODE=$(kctl -n "${NS}" run ct-probe --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: ${HOST}" \
    "http://${ENVOY_IP}:8080/" 2>/dev/null || echo "000")
HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1)

echo "HTTP response (with Host): ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTP 200 with Host header"
else
  echo "FAIL: expected HTTP 200 with Host header, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "==> Probing HTTP without Host header (expect 404) on envoy container port 8080"
RAW_NO_HOST_CODE=$(kctl -n "${NS}" run ct-probe-no-host --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "http://${ENVOY_IP}:8080/" 2>/dev/null || echo "000")
NO_HOST_CODE=$(echo "$RAW_NO_HOST_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1)

echo "HTTP response (without Host): ${NO_HOST_CODE}"
if [ "${NO_HOST_CODE}" = "404" ]; then
  echo "PASS: HTTP 404 without Host header (envoy default)"
else
  echo "FAIL: expected HTTP 404 without Host header, got ${NO_HOST_CODE}" >&2
  exit 1
fi

echo "PASS: Contour basic HTTPProxy integration verified"
