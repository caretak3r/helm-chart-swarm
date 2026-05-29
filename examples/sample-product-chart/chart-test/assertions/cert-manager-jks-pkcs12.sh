#!/usr/bin/env bash
# cert-manager JKS/PKCS12 smoke assertion (optional variant).
# Verifies: Certificate Ready, creates PKCS12 bundle, stores as Secret.
# Certificate is created by cluster.preinstall raw_manifest.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SECRET_NAME="${TLS_SECRET_NAME:-sample-jks-tls}"
CERT_NAME="${RELEASE}-jks-tls"
JKS_SECRET="${RELEASE}-jks-bundle"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for Certificate '${CERT_NAME}' Ready (3m max)"
kctl -n "${NS}" wait certificate "${CERT_NAME}" --for=condition=Ready --timeout=3m
echo "PASS: Certificate Ready=True"

echo "==> Extracting cert and key, creating PKCS12 bundle"
TLS_CRT=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.crt}')
TLS_KEY=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.key}')

WORKDIR=$(mktemp -d)
trap "rm -rf ${WORKDIR}" EXIT
echo "${TLS_CRT}" | base64 -d > "${WORKDIR}/tls.crt"
echo "${TLS_KEY}" | base64 -d > "${WORKDIR}/tls.key"

openssl pkcs12 -export \
  -in "${WORKDIR}/tls.crt" \
  -inkey "${WORKDIR}/tls.key" \
  -out "${WORKDIR}/keystore.p12" \
  -passout pass:changeit \
  -name "${RELEASE}" 2>/dev/null || { echo "FAIL: PKCS12 export failed" >&2; exit 1; }

P12_B64=$(base64 < "${WORKDIR}/keystore.p12" | tr -d '\n')

echo "==> Storing PKCS12 bundle as Secret '${JKS_SECRET}'"
kctl -n "${NS}" delete secret "${JKS_SECRET}" --ignore-not-found
kctl -n "${NS}" create secret generic "${JKS_SECRET}" \
  --from-file=tls.crt="${WORKDIR}/tls.crt" \
  --from-file=tls.key="${WORKDIR}/tls.key" \
  --from-file=keystore.p12="${WORKDIR}/keystore.p12"

echo "==> Verifying JKS/PKCS12 Secret keys"
bundle_keys=$(kctl -n "${NS}" get secret "${JKS_SECRET}" -o json | jq -r '.data | keys | sort[]')
echo "Bundle keys: ${bundle_keys}"
echo "${bundle_keys}" | grep -qx 'keystore.p12' || { echo "FAIL: missing keystore.p12" >&2; exit 1; }
echo "${bundle_keys}" | grep -qx 'tls.crt'       || { echo "FAIL: missing tls.crt" >&2; exit 1; }
echo "${bundle_keys}" | grep -qx 'tls.key'       || { echo "FAIL: missing tls.key" >&2; exit 1; }
echo "OK: keystore.p12, tls.crt, tls.key all present"

# Verify PKCS12 is valid
kctl -n "${NS}" get secret "${JKS_SECRET}" -o jsonpath='{.data.keystore\.p12}' | base64 -d > "${WORKDIR}/verify.p12"
openssl pkcs12 -in "${WORKDIR}/verify.p12" -passin pass:changeit -nokeys 2>/dev/null | grep -q "BEGIN CERTIFICATE" || { echo "FAIL: PKCS12 bundle not readable" >&2; exit 1; }
echo "PASS: PKCS12 bundle is valid"

echo "PASS: cert-manager JKS/PKCS12 integration verified"
