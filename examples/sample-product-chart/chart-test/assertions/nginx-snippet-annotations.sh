#!/usr/bin/env bash
# NGINX Ingress snippet annotations smoke assertion.
# Verifies: nginx controller pod Ready, Ingress has nginx.ingress.kubernetes.io/configuration-snippet
#           annotation, controller has allowSnippetAnnotations enabled,
#           curl response includes the snippet-injected header X-Test.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
NGINX_NS="ingress-nginx"
HOST="sample.test.local"
EXPECTED_HEADER="X-Test"
EXPECTED_VALUE="chart-test-swarm"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for nginx controller pod Ready (3m max)"
kctl -n "${NGINX_NS}" wait pod -l app.kubernetes.io/name=ingress-nginx --for=condition=Ready --timeout=3m
echo "PASS: nginx controller pod Ready"

echo "==> Waiting for product pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: product pods Ready"

echo "==> Verifying Ingress has configuration-snippet annotation"
SNIPPET_ANNOTATION=$(kctl -n "${NS}" get ingress sample-snippet -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/configuration-snippet}')
if [ -n "${SNIPPET_ANNOTATION}" ]; then
  echo "PASS: Ingress has nginx.ingress.kubernetes.io/configuration-snippet annotation"
  echo "Snippet content: ${SNIPPET_ANNOTATION}"
else
  echo "FAIL: Ingress is missing configuration-snippet annotation" >&2
  exit 1
fi

echo "==> Getting nginx controller pod IP"
NGINX_IP=$(kctl -n "${NGINX_NS}" get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].status.podIP}')
echo "NGINX pod IP: ${NGINX_IP}"

echo "==> Probing HTTP with Host header (expect 200 with X-Test header, retry up to 2m)"
# Nginx ingress may take a few seconds to sync endpoints after the product pod becomes Ready.
# Retry up to 20 times (6s apart = 2m) before declaring failure.
HTTP_CODE="000"
RESPONSE=""
for _attempt in $(seq 1 20); do
  RESPONSE=""
  RESPONSE=$(kctl -n "${NS}" run "ct-snip-${_attempt}" --rm -i --restart=Never --quiet \
    --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
    sh -c "curl -s -D - --max-time 10 \
      -H 'Host: ${HOST}' \
      'http://${NGINX_IP}/'" 2>/dev/null) || RESPONSE=""
  HTTP_CODE=$(echo "${RESPONSE}" | grep -E '^HTTP/' | head -1 | awk '{print $2}')
  echo "HTTP response (attempt ${_attempt}): ${HTTP_CODE:-none}"
  [ "${HTTP_CODE}" = "200" ] && break
  [ "$_attempt" -lt 20 ] && sleep 6
done

echo "HTTP response code: ${HTTP_CODE}"

if [ "${HTTP_CODE}" != "200" ]; then
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi
echo "PASS: HTTP 200 with Host header"

echo "==> Verifying snippet-injected header '${EXPECTED_HEADER}: ${EXPECTED_VALUE}'"
HEADER_VALUE=$(echo "${RESPONSE}" | grep -i "^${EXPECTED_HEADER}:" | head -1 | sed 's/^[^:]*: *//' | tr -d '\r')
echo "Response header ${EXPECTED_HEADER}: '${HEADER_VALUE}'"

if echo "${HEADER_VALUE}" | grep -qF "${EXPECTED_VALUE}"; then
  echo "PASS: snippet-injected header '${EXPECTED_HEADER}: ${EXPECTED_VALUE}' present"
else
  echo "FAIL: header '${EXPECTED_HEADER}' not found or value mismatch (got '${HEADER_VALUE}')" >&2
  exit 1
fi

echo "PASS: NGINX Ingress snippet annotations integration verified"
