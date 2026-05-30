#!/usr/bin/env bash
# manual-tls-secret multiple-sans smoke assertion.
# Verifies: TLS Secret exists, pods Ready, HTTPS serving,
# certificate has >=2 DNS SAN entries.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SECRET_NAME="${TLS_SECRET_NAME:-manual-tls-multisite}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Verifying TLS Secret '${SECRET_NAME}' exists"
kctl -n "${NS}" get secret "${SECRET_NAME}" >/dev/null || { echo "FAIL: Secret ${SECRET_NAME} not found" >&2; exit 1; }
echo "PASS: Secret exists"

echo "==> Verifying certificate SANs (>=2 DNS entries)"
SAN_OUT=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName)
echo "SANs: ${SAN_OUT}"
SAN_COUNT=$(echo "${SAN_OUT}" | grep -o 'DNS:' | wc -l | tr -d ' ')
echo "SAN count: ${SAN_COUNT}"
if [ "${SAN_COUNT}" -ge 2 ]; then
  echo "PASS: certificate has ${SAN_COUNT} SANs (>=2 required)"
else
  echo "FAIL: certificate has only ${SAN_COUNT} SAN(s), need >=2" >&2
  exit 1
fi

echo "==> Waiting for pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: chart pods Ready"

echo "==> Verifying HTTPS reachable from in-cluster curl"
SVC_IP=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.clusterIP}')
TLS_PORT=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
DOMAIN="${RELEASE}.${NS}.svc"

HTTP_CODE=$(kctl -n "${NS}" run ct-curl --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.6.0 --timeout=30s -- \
  sh -c "curl -s -o /dev/null -w '%{http_code}' -k \
    --resolve '${DOMAIN}:${TLS_PORT}:${SVC_IP}' \
    'https://${DOMAIN}:${TLS_PORT}/'" 2>/dev/null || echo "000")

echo "HTTPS response: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTPS 200"
else
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: manual-tls-secret multiple-sans scenario verified"
