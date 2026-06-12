#!/usr/bin/env bash
# manual-tls-secret ECDSA smoke assertion.
# Verifies: TLS Secret exists, pods Ready, HTTPS serving,
# certificate uses ECDSA P-256 or P-384 public key algorithm.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SECRET_NAME="${TLS_SECRET_NAME:-manual-tls-ecdsa}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Verifying TLS Secret '${SECRET_NAME}' exists"
kctl -n "${NS}" get secret "${SECRET_NAME}" >/dev/null || { echo "FAIL: Secret ${SECRET_NAME} not found" >&2; exit 1; }
echo "PASS: Secret exists"

echo "==> Verifying certificate public-key algorithm is ECDSA"
PK_ALGO=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep "Public Key Algorithm" | sed 's/^[[:space:]]*//')
echo "Public Key Algorithm: ${PK_ALGO}"

# Match ECDSA P-256 (id-ecPublicKey with prime256v1) or P-384 (secp384r1)
if echo "${PK_ALGO}" | grep -qE "id-ecPublicKey|ecdsa-with-SHA"; then
  echo "PASS: certificate uses ECDSA public key"
else
  echo "FAIL: expected ECDSA public key, got: ${PK_ALGO}" >&2
  exit 1
fi

echo "==> Verifying ECDSA curve (P-256 or P-384)"
CURVE=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep -E "NIST CURVE|ASN1 OID" | head -1 | sed 's/^[[:space:]]*//')
echo "Curve info: ${CURVE}"
if echo "${CURVE}" | grep -qE "prime256v1|secp384r1|P-256|P-384"; then
  echo "PASS: ECDSA curve is in {P-256, P-384}"
else
  echo "FAIL: expected P-256 or P-384 curve" >&2
  exit 1
fi

echo "==> Waiting for pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: chart pods Ready"

echo "==> Verifying HTTPS reachable from in-cluster curl"
SVC_IP=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.clusterIP}')
TLS_PORT=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
DOMAIN="${RELEASE}.${NS}.svc"

RAW_HTTP_CODE=$(kctl -n "${NS}" run ct-curl --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
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

echo "PASS: manual-tls-secret ECDSA scenario verified"
