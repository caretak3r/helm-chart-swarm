#!/usr/bin/env bash
# NGINX Ingress canary smoke assertion.
# Verifies: two Ingresses for the same host (one with canary annotations + weight 20),
#           100 curl probes show 10-30 routed to canary backend.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
NGINX_NS="ingress-nginx"
HOST="sample.test.local"
PROBE_COUNT=100
CANARY_WEIGHT=20
MIN_CANARY=10
MAX_CANARY=30

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for nginx controller pod Ready (3m max)"
kctl -n "${NGINX_NS}" wait pod -l app.kubernetes.io/name=ingress-nginx --for=condition=Ready --timeout=3m
echo "PASS: nginx controller pod Ready"

echo "==> Waiting for product pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=sample" --for=condition=Ready --timeout=3m
echo "PASS: stable product pods Ready"

echo "==> Waiting for canary pod Ready (2m max)"
kctl -n "${NS}" wait pod -l app=sample-canary --for=condition=Ready --timeout=2m
echo "PASS: canary pod Ready"

echo "==> Verifying stable Ingress exists"
kctl -n "${NS}" get ingress sample-stable -o name || { echo "FAIL: stable Ingress not found" >&2; exit 1; }
echo "PASS: stable Ingress exists"

echo "==> Verifying canary Ingress exists with canary annotations"
CANARY_FLAG=$(kctl -n "${NS}" get ingress sample-canary -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary}')
CWEIGHT=$(kctl -n "${NS}" get ingress sample-canary -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary-weight}')
echo "Canary flag: '${CANARY_FLAG}', canary-weight: '${CWEIGHT}'"

if [ "${CANARY_FLAG}" = "true" ] && [ "${CWEIGHT}" = "${CANARY_WEIGHT}" ]; then
  echo "PASS: canary Ingress has correct annotations"
else
  echo "FAIL: expected canary=true and canary-weight=${CANARY_WEIGHT}, got canary=${CANARY_FLAG} weight=${CWEIGHT}" >&2
  exit 1
fi

echo "==> Getting nginx controller pod IP"
NGINX_IP=$(kctl -n "${NGINX_NS}" get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].status.podIP}')
echo "NGINX pod IP: ${NGINX_IP}"

echo "==> Running ${PROBE_COUNT} canary probes (expect ${MIN_CANARY}-${MAX_CANARY} canary hits)"
CANARY_COUNT=0
STABLE_COUNT=0

for i in $(seq 1 "${PROBE_COUNT}"); do
  RESULT=$(kctl -n "${NS}" run "ct-canary-${i}" --rm -i --restart=Never --quiet \
    --image=quay.io/curl/curl:8.6.0 --timeout=15s -- \
    sh -c "curl -s -D - --max-time 5 \
      -H 'Host: ${HOST}' \
      'http://${NGINX_IP}/'" 2>/dev/null || echo "")

  if echo "${RESULT}" | grep -qi "x-backend: canary"; then
    CANARY_COUNT=$((CANARY_COUNT + 1))
  elif echo "${RESULT}" | grep -qi "canary-response"; then
    CANARY_COUNT=$((CANARY_COUNT + 1))
  else
    STABLE_COUNT=$((STABLE_COUNT + 1))
  fi

  # Progress indicator every 20 probes
  if [ $((i % 20)) -eq 0 ]; then
    echo "  ... probe ${i}/${PROBE_COUNT}: canary=${CANARY_COUNT} stable=${STABLE_COUNT}"
  fi
done

echo ""
echo "Canary hits: ${CANARY_COUNT}/${PROBE_COUNT} (${CANARY_WEIGHT}% target)"
echo "Stable hits: ${STABLE_COUNT}/${PROBE_COUNT}"

if [ "${CANARY_COUNT}" -ge "${MIN_CANARY}" ] && [ "${CANARY_COUNT}" -le "${MAX_CANARY}" ]; then
  echo "PASS: canary traffic in range [${MIN_CANARY}, ${MAX_CANARY}] — ${CANARY_COUNT} hits"
else
  echo "FAIL: canary traffic out of range [${MIN_CANARY}, ${MAX_CANARY}] — got ${CANARY_COUNT} hits" >&2
  exit 1
fi

echo "PASS: NGINX Ingress canary integration verified"
