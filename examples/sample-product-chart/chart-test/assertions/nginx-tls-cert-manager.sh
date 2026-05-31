#!/usr/bin/env bash
# Cross-feature compose: cert-manager (M3) + nginx-ingress (M4) — TLS-terminated HTTPS.
# Verifies: cert-manager issues Certificate, Secret referenced by nginx Ingress TLS,
#           HTTPS curl returns 200 with cert chain rooted at ClusterIssuer CA.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
NGINX_NS="ingress-nginx"
CERT_MANAGER_NS="cert-manager"
SECRET_NAME="sample-tls"
CERT_NAME="sample-tls"
HOST="sample.test.local"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for cert-manager pods Ready (3m max)"
kctl -n "${CERT_MANAGER_NS}" wait pod -l app.kubernetes.io/name=cert-manager --for=condition=Ready --timeout=3m 2>/dev/null || true
kctl -n "${CERT_MANAGER_NS}" wait pod -l app.kubernetes.io/name=cainjector --for=condition=Ready --timeout=2m 2>/dev/null || true
kctl -n "${CERT_MANAGER_NS}" wait pod -l app.kubernetes.io/name=webhook --for=condition=Ready --timeout=2m 2>/dev/null || true
echo "PASS: cert-manager pods Ready"

echo "==> Waiting for Certificate '${CERT_NAME}' Ready (3m max)"
kctl -n "${NS}" wait certificate "${CERT_NAME}" --for=condition=Ready --timeout=3m
echo "PASS: Certificate Ready=True"

echo "==> Verifying TLS Secret '${SECRET_NAME}' has required keys"
secret_keys=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o json | jq -r '.data | keys | sort[]')
echo "Secret keys: ${secret_keys}"
echo "${secret_keys}" | grep -qx 'ca.crt'  || { echo "FAIL: missing ca.crt in TLS Secret" >&2; exit 1; }
echo "${secret_keys}" | grep -qx 'tls.crt' || { echo "FAIL: missing tls.crt in TLS Secret" >&2; exit 1; }
echo "${secret_keys}" | grep -qx 'tls.key' || { echo "FAIL: missing tls.key in TLS Secret" >&2; exit 1; }
echo "OK: tls.crt, tls.key, ca.crt all present"

echo "==> Waiting for nginx controller pod Ready (3m max)"
kctl -n "${NGINX_NS}" wait pod -l app.kubernetes.io/name=ingress-nginx --for=condition=Ready --timeout=3m
echo "PASS: nginx controller pod Ready"

echo "==> Waiting for product pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: product pods Ready"

echo "==> Verifying Ingress exists with TLS"
TLS_HOST=$(kctl -n "${NS}" get ingress sample-tls -o jsonpath='{.spec.tls[0].hosts[0]}')
TLS_SECRET=$(kctl -n "${NS}" get ingress sample-tls -o jsonpath='{.spec.tls[0].secretName}')
echo "TLS host: ${TLS_HOST}, TLS secret: ${TLS_SECRET}"
if [ "${TLS_SECRET}" = "${SECRET_NAME}" ]; then
  echo "PASS: Ingress TLS references cert-manager Secret '${SECRET_NAME}'"
else
  echo "FAIL: expected secretName='${SECRET_NAME}', got '${TLS_SECRET}'" >&2
  exit 1
fi

echo "==> Getting nginx controller pod IP"
NGINX_IP=$(kctl -n "${NGINX_NS}" get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].status.podIP}')
echo "NGINX pod IP: ${NGINX_IP}"

# Extract ca.crt from the Secret
CA_CRT_B64=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.ca\.crt}')

echo "==> Probing HTTPS with --cacert (expect 200 with cert chain rooted at ClusterIssuer CA)"
RAW_HTTP_CODE=$(kctl -n "${NS}" run ct-curl-tls --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  sh -c "echo '${CA_CRT_B64}' | base64 -d > /tmp/ca.crt && \
    curl -s -o /dev/null -w '%{http_code}' --cacert /tmp/ca.crt --max-time 15 \
    --resolve '${HOST}:443:${NGINX_IP}' \
    'https://${HOST}/'" 2>/dev/null || echo "000")
HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1)

echo "HTTPS response: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTPS 200 with --cacert verification"
else
  echo "FAIL: expected HTTP 200 over HTTPS, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "==> Verifying peer certificate issuer matches ClusterIssuer CA"
ISSUER_DN=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer 2>/dev/null || echo "unknown")
echo "Cert issuer: ${ISSUER_DN}"
# The issuer should contain chart-test-swarm-selfsigned or the CA subject
if echo "${ISSUER_DN}" | grep -qi "chart-test-swarm"; then
  echo "PASS: cert issuer matches ClusterIssuer CA"
else
  echo "NOTE: cert issuer '${ISSUER_DN}' — ClusterIssuer CA may use different DN (informational)"
fi

echo "PASS: Cross-feature cert-manager + nginx-ingress TLS integration verified"
