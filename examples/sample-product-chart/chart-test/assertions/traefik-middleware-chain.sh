#!/usr/bin/env bash
# Traefik middleware chain smoke assertion.
# Verifies: Traefik pod Ready, Middleware CR exists, IngressRoute references
#           the Middleware, response includes the injected header.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
TRAEFIK_NS="traefik"
HOST="sample.test.local"
MIDDLEWARE_NAME="add-test-header"
EXPECTED_HEADER="X-Test"
EXPECTED_VALUE="chart-test-swarm"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for Traefik pod Ready (3m max)"
kctl -n "${TRAEFIK_NS}" wait pod -l app.kubernetes.io/name=traefik --for=condition=Ready --timeout=3m
echo "PASS: Traefik pod Ready"

echo "==> Waiting for product pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: product pods Ready"

echo "==> Verifying Middleware CR exists"
kctl -n "${NS}" get middleware "${MIDDLEWARE_NAME}" -o name || { echo "FAIL: Middleware ${MIDDLEWARE_NAME} not found" >&2; exit 1; }
echo "PASS: Middleware ${MIDDLEWARE_NAME} exists"

echo "==> Verifying IngressRoute references the Middleware"
MIDDLEWARE_REF=$(kctl -n "${NS}" get ingressroute sample-middleware -o jsonpath='{.spec.routes[0].middlewares[0].name}')
if [ "${MIDDLEWARE_REF}" = "${MIDDLEWARE_NAME}" ]; then
  echo "PASS: IngressRoute references Middleware '${MIDDLEWARE_NAME}'"
else
  echo "FAIL: IngressRoute middlewares[0].name='${MIDDLEWARE_REF}', expected '${MIDDLEWARE_NAME}'" >&2
  exit 1
fi

echo "==> Getting Traefik pod IP"
TRAEFIK_IP=$(kctl -n "${TRAEFIK_NS}" get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.podIP}')
echo "Traefik pod IP: ${TRAEFIK_IP}"

echo "==> Probing HTTP with Host header (expect 200 with X-Test header)"
RAW_RESPONSE=$(kctl -n "${NS}" run ct-probe-mw --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
  sh -c "curl -s -D - --max-time 15 \
    -H 'Host: ${HOST}' \
    'http://${TRAEFIK_IP}:8000/'" 2>/dev/null || echo "")
RESPONSE="${RAW_RESPONSE}"

HTTP_CODE=$(echo "${RESPONSE}" | head -1 | awk '{print $2}')
echo "HTTP response code: ${HTTP_CODE}"

if [ "${HTTP_CODE}" != "200" ]; then
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi
echo "PASS: HTTP 200 with Host header"

echo "==> Verifying middleware-injected header '${EXPECTED_HEADER}: ${EXPECTED_VALUE}'"
HEADER_VALUE=$(echo "${RESPONSE}" | grep -i "^${EXPECTED_HEADER}:" | head -1 | sed 's/^[^:]*: *//' | tr -d '\r')
echo "Response header ${EXPECTED_HEADER}: '${HEADER_VALUE}'"

if echo "${HEADER_VALUE}" | grep -qF "${EXPECTED_VALUE}"; then
  echo "PASS: middleware injected header '${EXPECTED_HEADER}: ${EXPECTED_VALUE}'"
else
  echo "FAIL: header '${EXPECTED_HEADER}' not found or value mismatch (got '${HEADER_VALUE}')" >&2
  exit 1
fi

echo "PASS: Traefik middleware chain integration verified"
