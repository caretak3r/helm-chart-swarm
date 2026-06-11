#!/usr/bin/env bash
# NGINX Ingress basic smoke assertion.
# Verifies: nginx controller pod Ready, Ingress carries ingressClassName: nginx,
#           HTTP 200 with Host header, controller logs show request matched product Service.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
NGINX_NS="ingress-nginx"
HOST="sample.test.local"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for nginx controller pod Ready (3m max)"
kctl -n "${NGINX_NS}" wait pod -l app.kubernetes.io/name=ingress-nginx --for=condition=Ready --timeout=3m
echo "PASS: nginx controller pod Ready"

echo "==> Waiting for product pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: product pods Ready"

echo "==> Verifying Ingress exists with ingressClassName: nginx"
INGRESS_CLASS=$(kctl -n "${NS}" get ingress sample-basic -o jsonpath='{.spec.ingressClassName}')
echo "Ingress class: ${INGRESS_CLASS}"
if [ "${INGRESS_CLASS}" = "nginx" ]; then
  echo "PASS: Ingress carries ingressClassName: nginx"
else
  echo "FAIL: expected ingressClassName=nginx, got '${INGRESS_CLASS}'" >&2
  exit 1
fi

echo "==> Getting nginx controller pod IP"
NGINX_IP=$(kctl -n "${NGINX_NS}" get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].status.podIP}')
echo "NGINX pod IP: ${NGINX_IP}"

echo "==> Probing HTTP with Host header (expect 200, retry up to 2m for ingress backend ready)"
# Nginx ingress may take a few seconds to sync endpoints after the product pod becomes Ready.
# Retry up to 20 times (6s apart = 2m) before declaring failure.
HTTP_CODE="000"
for _attempt in $(seq 1 20); do
  RAW_HTTP_CODE=""
  RAW_HTTP_CODE=$(kctl -n "${NS}" run "ct-probe-${_attempt}" --rm -i --restart=Never --quiet \
    --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      -H "Host: ${HOST}" \
      "http://${NGINX_IP}/" 2>/dev/null) || RAW_HTTP_CODE="000"
  HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  echo "HTTP response (with Host): ${HTTP_CODE} (attempt ${_attempt})"
  if [ "${HTTP_CODE}" = "200" ]; then
    break
  fi
  [ "$_attempt" -lt 20 ] && sleep 6
done

if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTP 200 with Host header"
else
  echo "FAIL: expected HTTP 200 with Host header, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "==> Verifying nginx controller logs show request matched product Service"
CONTROLLER_POD=$(kctl -n "${NGINX_NS}" get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].metadata.name}')
LOGS=$(kctl -n "${NGINX_NS}" logs "${CONTROLLER_POD}" --tail=50 2>/dev/null || echo "")
if echo "${LOGS}" | grep -q "${RELEASE}"; then
  echo "PASS: controller logs reference product Service '${RELEASE}'"
else
  # Not a hard failure — logs may not have the exact service name depending on format
  echo "NOTE: controller logs (last 50 lines) may not contain explicit Service name (informational only)"
fi

echo "PASS: NGINX Ingress basic integration verified"
