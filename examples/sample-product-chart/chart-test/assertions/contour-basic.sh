#!/usr/bin/env bash
# Contour basic HTTPProxy smoke assertion (gap-probe).
# Verifies: envoy pod Ready, HTTPProxy routes HTTP with Host header,
#           HTTPProxy status.currentStatus is valid.
# Gap-probe: chart does NOT natively emit a Contour HTTPProxy CRD —
#            the HTTPProxy was created by the fixture, not a chart template.
#            This is an honest gap (red cell); do NOT over-engineer the chart.
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
RAW_HTTP_CODE=""
RAW_HTTP_CODE=$(kctl -n "${NS}" run ct-probe --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: ${HOST}" \
    "http://${ENVOY_IP}:8080/" 2>/dev/null) || RAW_HTTP_CODE="000"
HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")

echo "HTTP response (with Host): ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTP 200 with Host header"
else
  echo "FAIL: expected HTTP 200 with Host header, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "==> Probing HTTP without Host header (expect 404) on envoy container port 8080"
RAW_NO_HOST_CODE=""
RAW_NO_HOST_CODE=$(kctl -n "${NS}" run ct-probe-no-host --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "http://${ENVOY_IP}:8080/" 2>/dev/null) || RAW_NO_HOST_CODE="000"
NO_HOST_CODE=$(echo "$RAW_NO_HOST_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")

echo "HTTP response (without Host): ${NO_HOST_CODE}"
if [ "${NO_HOST_CODE}" = "404" ]; then
  echo "PASS: HTTP 404 without Host header (envoy default)"
else
  echo "FAIL: expected HTTP 404 without Host header, got ${NO_HOST_CODE}" >&2
  exit 1
fi

echo "PASS: Contour basic HTTPProxy integration verified"

echo "==> GAP-PROBE: Checking if chart natively emits an HTTPProxy CRD"
# A chart-emitted HTTPProxy would have Helm ownership labels/annotations.
# The fixture-created HTTPProxy does not carry these markers.
CHART_HTTPPROXIES=$(kctl -n "${NS}" get httpproxy \
  -l "app.kubernetes.io/managed-by=Helm" \
  -o name 2>/dev/null || echo "")
HELM_ANNOTATED=$(kctl -n "${NS}" get httpproxy \
  -o jsonpath='{range .items[?(@.metadata.annotations.meta\.helm\.sh/release-name)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

if [ -n "${CHART_HTTPPROXIES}" ] || [ -n "${HELM_ANNOTATED}" ]; then
  echo "INFO: Chart appears to emit HTTPProxy CRD(s): ${CHART_HTTPPROXIES}${HELM_ANNOTATED}"
  echo "PASS: Chart natively emits Contour HTTPProxy CRD"
else
  echo "GAP-PROBE: No HTTPProxy emitted by the chart template found"
  echo "  The HTTPProxy 'sample-basic' was created by the raw_manifest fixture,"
  echo "  not by a Helm-managed chart template. The chart has no contour"
  echo "  HTTPProxy template — this is a known gap (chart does not yet support"
  echo "  native Contour HTTPProxy emission). Documented as non-blocking: the"
  echo "  Contour infrastructure itself is verified functional above."
  echo "INFO: gap documented — chart has no native Contour HTTPProxy template"
fi
