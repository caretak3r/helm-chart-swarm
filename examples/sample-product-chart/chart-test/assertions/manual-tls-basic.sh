#!/usr/bin/env bash
# manual-tls-secret basic smoke assertion.
# Verifies: TLS Secret exists with tls.crt + tls.key, pods Ready,
# HTTPS serving with --insecure (self-signed), Secret type is kubernetes.io/tls.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SECRET_NAME="${TLS_SECRET_NAME:-manual-tls-basic}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Verifying TLS Secret '${SECRET_NAME}' type"
SECRET_TYPE=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.type}')
echo "Secret type: ${SECRET_TYPE}"
[ "${SECRET_TYPE}" = "kubernetes.io/tls" ] || { echo "FAIL: expected type kubernetes.io/tls, got ${SECRET_TYPE}" >&2; exit 1; }
echo "PASS: Secret type is kubernetes.io/tls"

echo "==> Verifying TLS Secret '${SECRET_NAME}' data keys"
secret_keys=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o json | jq -r '.data | keys | sort[]')
echo "Secret keys: ${secret_keys}"
echo "${secret_keys}" | grep -qx 'tls.crt' || { echo "FAIL: missing tls.crt" >&2; exit 1; }
echo "${secret_keys}" | grep -qx 'tls.key' || { echo "FAIL: missing tls.key" >&2; exit 1; }
echo "OK: tls.crt, tls.key both present"

echo "==> Verifying tls.crt is valid PEM"
kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject
echo "PASS: tls.crt is a valid certificate"

echo "==> Verifying tls.key is valid PEM"
kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.key}' | base64 -d | openssl rsa -check -noout 2>/dev/null || {
  # may be ECDSA - try that
  kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.key}' | base64 -d | openssl ec -check -noout 2>/dev/null || {
    echo "FAIL: tls.key is not a valid RSA or ECDSA private key" >&2; exit 1
  }
}
echo "PASS: tls.key is a valid private key"

echo "==> Waiting for pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: chart pods Ready"

echo "==> Verifying HTTPS reachable from in-cluster curl"
SVC_IP=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.clusterIP}')
TLS_PORT=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
DOMAIN="${RELEASE}.${NS}.svc"

RAW_HTTP_CODE=$(kctl -n "${NS}" run ct-curl --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.6.0 --timeout=30s -- \
  sh -c "curl -s -o /dev/null -w '%{http_code}' -k \
    --resolve '${DOMAIN}:${TLS_PORT}:${SVC_IP}' \
    'https://${DOMAIN}:${TLS_PORT}/'" 2>/dev/null || echo "000")
HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1)

echo "HTTPS response: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTPS 200"
else
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: manual-tls-secret basic scenario verified"
