#!/usr/bin/env bash
# cert-manager self-signed-ca smoke assertion.
# Verifies: Certificate Ready, TLS Secret keys, HTTPS serving with --cacert, SAN.
# Certificate is created by cluster.preinstall raw_manifest.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SECRET_NAME="${TLS_SECRET_NAME:-sample-tls}"
CERT_NAME="${RELEASE}-tls"
DOMAIN="${RELEASE}.${NS}.svc"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for Certificate '${CERT_NAME}' Ready (3m max)"
kctl -n "${NS}" wait certificate "${CERT_NAME}" --for=condition=Ready --timeout=3m
echo "PASS: Certificate Ready=True"

echo "==> Verifying TLS Secret '${SECRET_NAME}' keys"
secret_keys=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o json | jq -r '.data | keys | sort[]')
echo "Secret keys: ${secret_keys}"
echo "${secret_keys}" | grep -qx 'ca.crt'  || { echo "FAIL: missing ca.crt" >&2; exit 1; }
echo "${secret_keys}" | grep -qx 'tls.crt' || { echo "FAIL: missing tls.crt" >&2; exit 1; }
echo "${secret_keys}" | grep -qx 'tls.key' || { echo "FAIL: missing tls.key" >&2; exit 1; }
echo "OK: tls.crt, tls.key, ca.crt all present"

echo "==> Waiting for pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: chart pods Ready"

echo "==> Verifying HTTPS reachable from in-cluster curl"
SVC_IP=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.clusterIP}')
TLS_PORT=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.ports[?(@.name=="https")].port}')

# Extract ca.crt from the Secret
CA_CRT_B64=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.ca\.crt}')

RAW_HTTP_CODE=$(kctl -n "${NS}" run ct-curl --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
  sh -c "echo '${CA_CRT_B64}' | base64 -d > /tmp/ca.crt && \
    curl -s -o /dev/null -w '%{http_code}' --cacert /tmp/ca.crt \
    --resolve '${DOMAIN}:${TLS_PORT}:${SVC_IP}' \
    'https://${DOMAIN}:${TLS_PORT}/'" 2>/dev/null || echo "000")
HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")

echo "HTTPS response: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTPS 200 with --cacert verification"
else
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "==> Verifying peer certificate SAN"
SAN_OUT=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName)
echo "SAN: ${SAN_OUT}"
echo "${SAN_OUT}" | grep -q "DNS:${DOMAIN}" || { echo "FAIL: SAN does not contain ${DOMAIN}" >&2; exit 1; }
echo "PASS: cert SAN includes configured host"

echo "PASS: cert-manager self-signed CA integration verified"
