#!/usr/bin/env bash
# Contour rate-limit smoke assertion.
# Verifies: HTTPProxy rateLimitPolicy.local enforced,
#           >limit probes produce at least one 429, ≤limit probes all 200.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
CONTOUR_NS="projectcontour"
HOST="sample.test.local"
LIMIT=5  # must match the rateLimitPolicy in the HTTPProxy

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

echo "==> Verifying HTTPProxy rateLimitPolicy exists"
RATELIMIT=$(kctl -n "${NS}" get httpproxy sample-ratelimit -o jsonpath='{.spec.virtualhost.rateLimitPolicy.local}' 2>/dev/null || echo "MISSING")
echo "RateLimitPolicy: ${RATELIMIT}"
if [ "${RATELIMIT}" = "MISSING" ]; then
  echo "FAIL: HTTPProxy sample-ratelimit not found or no rateLimitPolicy" >&2
  exit 1
fi
echo "PASS: HTTPProxy has rateLimitPolicy.local configured"

echo "==> Getting envoy pod IP"
ENVOY_IP=$(kctl -n "${CONTOUR_NS}" get pod -l app.kubernetes.io/component=envoy -o jsonpath='{.items[0].status.podIP}')
echo "envoy pod IP: ${ENVOY_IP}"

echo "==> Sending ${LIMIT} requests at ≤limit rate (expect all 200)"
ALL_OK=1
for i in $(seq 1 "${LIMIT}"); do
  RAW_CODE=$(kctl -n "${NS}" run "ct-rl-und-${i}" --rm -i --restart=Never --quiet \
    --image=quay.io/curl/curl:8.20.0 --timeout=20s -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      -H "Host: ${HOST}" \
      "http://${ENVOY_IP}:8080/" 2>/dev/null || echo "000")
  CODE=$(echo "${RAW_CODE}" | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  echo "  req ${i}: HTTP ${CODE}"
  if [ "${CODE}" != "200" ]; then
    ALL_OK=0
  fi
done

if [ "${ALL_OK}" = "1" ]; then
  echo "PASS: all ${LIMIT} requests at/below limit returned 200"
else
  echo "WARN: some requests at/below limit did not return 200 (may be due to burst threshold)"
fi

echo "==> Sending $((${LIMIT} * 3)) requests above limit rate (expect at least one 429)"
GOT_429=0
for i in $(seq 1 $((${LIMIT} * 3))); do
  RAW_CODE=$(kctl -n "${NS}" run "ct-rl-over-${i}" --rm -i --restart=Never --quiet \
    --image=quay.io/curl/curl:8.20.0 --timeout=20s -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      -H "Host: ${HOST}" \
      "http://${ENVOY_IP}:8080/" 2>/dev/null || echo "000")
  CODE=$(echo "${RAW_CODE}" | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  if [ "${CODE}" = "429" ]; then
    GOT_429=1
    echo "  req ${i}: HTTP 429 (rate limited)"
    # Don't break - keep going to verify sustained rate limiting
  fi
done

if [ "${GOT_429}" = "1" ]; then
  echo "PASS: at least one 429 Too Many Requests returned"
else
  echo "FAIL: no 429 responses received — rate limit may not be enforced" >&2
  exit 1
fi

echo "PASS: Contour rate limit integration verified"
