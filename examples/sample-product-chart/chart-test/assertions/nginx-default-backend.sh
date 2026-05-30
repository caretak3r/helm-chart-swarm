#!/usr/bin/env bash
# NGINX Ingress default backend smoke assertion.
# Verifies: nginx controller uses custom default backend,
#           curl without matching Host returns the custom backend's distinctive body.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
NGINX_NS="ingress-nginx"
EXPECTED_BODY="chart-test-swarm-default-backend"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for nginx controller pod Ready (3m max)"
kctl -n "${NGINX_NS}" wait pod -l app.kubernetes.io/name=ingress-nginx --for=condition=Ready --timeout=3m
echo "PASS: nginx controller pod Ready"

echo "==> Waiting for product pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: product pods Ready"

echo "==> Waiting for custom default backend pod Ready (2m max)"
kctl -n "${NGINX_NS}" wait pod -l app=custom-default-backend --for=condition=Ready --timeout=2m
echo "PASS: custom default backend pod Ready"

echo "==> Getting nginx controller pod IP"
NGINX_IP=$(kctl -n "${NGINX_NS}" get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].status.podIP}')
echo "NGINX pod IP: ${NGINX_IP}"

echo "==> Probing HTTP without Host header (should hit custom default backend)"
BODY=$(kctl -n "${NS}" run ct-probe-def --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  curl -s --max-time 15 \
    "http://${NGINX_IP}/" 2>/dev/null || echo "")

echo "Response body: '${BODY}'"

if echo "${BODY}" | grep -qF "${EXPECTED_BODY}"; then
  echo "PASS: custom default backend served distinctive body '${EXPECTED_BODY}'"
else
  echo "FAIL: expected body containing '${EXPECTED_BODY}', got '${BODY}'" >&2
  exit 1
fi

echo "==> Verifying Host-matched request still reaches product Service"
HTTP_CODE=$(kctl -n "${NS}" run ct-probe-host --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: sample.test.local" \
    "http://${NGINX_IP}/" 2>/dev/null || echo "000")

echo "HTTP response (with Host): ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTP 200 with matching Host header"
else
  echo "FAIL: expected HTTP 200 with Host header, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: NGINX Ingress default backend integration verified"
