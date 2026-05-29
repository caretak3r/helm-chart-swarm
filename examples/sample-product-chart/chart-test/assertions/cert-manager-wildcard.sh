#!/usr/bin/env bash
# cert-manager wildcard certificate smoke assertion.
# Verifies: Certificate Ready, wildcard SANs (*.test.local + test.local).
# Certificate is created by cluster.preinstall raw_manifest.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SECRET_NAME="${TLS_SECRET_NAME:-sample-wildcard-tls}"
CERT_NAME="${RELEASE}-wildcard-tls"

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

echo "==> Verifying wildcard certificate SANs"
SAN_OUT=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName)
echo "SAN: ${SAN_OUT}"

echo "${SAN_OUT}" | grep -q "DNS:\*\.test\.local" || { echo "FAIL: SAN does not contain *.test.local" >&2; exit 1; }
echo "${SAN_OUT}" | grep -q "DNS:test\.local" || { echo "FAIL: SAN does not contain test.local" >&2; exit 1; }
echo "PASS: cert SAN includes DNS:*.test.local and DNS:test.local"

echo "PASS: cert-manager wildcard certificate integration verified"
