#!/usr/bin/env bash
# Contour TLS delegation smoke assertion.
# Verifies: TLSCertificateDelegation grants cross-namespace TLS Secret access,
#           HTTPS 200 with the delegated cert.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
CONTOUR_NS="projectcontour"
HOST="sample.test.local"
TLS_NS="tls-secrets"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Generating test TLS cert and creating Secret"
TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${TMPDIR}/tls.key" \
  -out "${TMPDIR}/tls.crt" \
  -subj "/CN=${HOST}" \
  -addext "subjectAltName=DNS:${HOST}" 2>/dev/null

kctl -n "${TLS_NS}" create secret tls sample-tls \
  --cert="${TMPDIR}/tls.crt" \
  --key="${TMPDIR}/tls.key" \
  --dry-run=client -o yaml | kctl apply -f -
echo "PASS: TLS secret sample-tls created"

echo "==> Waiting for envoy pod Ready (3m max)"
kctl -n "${CONTOUR_NS}" wait pod -l app.kubernetes.io/component=envoy --for=condition=Ready --timeout=3m
echo "PASS: envoy pod Ready"

echo "==> Waiting for contour controller pod Ready (3m max)"
kctl -n "${CONTOUR_NS}" wait pod -l app.kubernetes.io/component=contour --for=condition=Ready --timeout=3m
echo "PASS: contour controller pod Ready"

echo "==> Waiting for product pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: product pods Ready"

echo "==> Verifying TLSCertificateDelegation exists"
kctl -n tls-secrets get tlscertificatedelegation sample-tls-delegation -o name || { echo "FAIL: TLSCertificateDelegation not found" >&2; exit 1; }
echo "PASS: TLSCertificateDelegation sample-tls-delegation exists"

echo "==> Verifying TLS secret exists in tls-secrets namespace"
kctl -n tls-secrets get secret sample-tls -o name || { echo "FAIL: TLS secret sample-tls not found" >&2; exit 1; }
echo "PASS: TLS secret sample-tls exists"

echo "==> Verifying HTTPProxy status is valid"
HTTPPROXY_STATUS=$(kctl -n "${NS}" get httpproxy sample-tls -o jsonpath='{.status.currentStatus}' 2>/dev/null || echo "MISSING")
echo "HTTPProxy status: ${HTTPPROXY_STATUS}"
if [ "${HTTPPROXY_STATUS}" = "valid" ]; then
  echo "PASS: HTTPProxy status is valid"
elif [ "${HTTPPROXY_STATUS}" = "MISSING" ]; then
  echo "FAIL: HTTPProxy sample-tls not found" >&2
  exit 1
else
  echo "FAIL: HTTPProxy status is '${HTTPPROXY_STATUS}', expected 'valid'" >&2
  exit 1
fi

echo "==> Getting envoy pod IP"
ENVOY_IP=$(kctl -n "${CONTOUR_NS}" get pod -l app.kubernetes.io/component=envoy -o jsonpath='{.items[0].status.podIP}')
echo "envoy pod IP: ${ENVOY_IP}"

echo "==> Probing HTTPS (expect 200) on envoy container port 8443"
RAW_HTTP_CODE=$(kctl -n "${NS}" run ct-probe-tls --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 --insecure \
    --resolve "${HOST}:8443:${ENVOY_IP}" \
    "https://${HOST}:8443/" 2>/dev/null || echo "000")
HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1)

echo "HTTPS response: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTPS 200 with delegated TLS cert"
else
  echo "FAIL: expected HTTPS 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "==> Verifying cert subject (expect CN=sample.test.local)"
# Use port-forward to access envoy via the host machine
kctl -n "${CONTOUR_NS}" port-forward "pod/$(kctl -n ${CONTOUR_NS} get pod -l app.kubernetes.io/component=envoy -o jsonpath='{.items[0].metadata.name}')" 9443:8443 >/dev/null 2>&1 &
PF_PID=$!
sleep 2

CERT_SUBJECT=$(echo | openssl s_client -connect localhost:9443 -servername "${HOST}" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || echo "")
kill ${PF_PID} 2>/dev/null || true

echo "Certificate subject: ${CERT_SUBJECT}"
if echo "${CERT_SUBJECT}" | grep -q "sample.test.local"; then
  echo "PASS: certificate CN matches sample.test.local"
else
  echo "FAIL: certificate CN does not match expected value" >&2
  exit 1
fi

echo "PASS: Contour TLS delegation integration verified"
