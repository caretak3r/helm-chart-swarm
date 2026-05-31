#!/usr/bin/env bash
# Istio Gateway API Backend TLS cert generation.
# Generates a self-signed CA and leaf cert (for use as TLS backend cert),
# then creates/updates the TLS Secret and CA ConfigMap in the cluster.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

HOST="sample.${NS}.svc.cluster.local"
CERT_NAME="backend-tls-cert"
CA_CONFIGMAP="backend-ca-cert"

echo "==> Generating self-signed CA and TLS cert for backend"
TMPDIR=$(mktemp -d)
trap 'rm -rf ${TMPDIR}' EXIT

# Generate CA key and certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${TMPDIR}/ca.key" \
  -out "${TMPDIR}/ca.crt" \
  -subj "/CN=${HOST}" \
  -addext "subjectAltName=DNS:${HOST}" 2>/dev/null

# Generate leaf key and CSR
openssl req -nodes -newkey rsa:2048 \
  -keyout "${TMPDIR}/tls.key" \
  -out "${TMPDIR}/csr.pem" \
  -subj "/CN=${HOST}" 2>/dev/null

# Sign leaf with CA
openssl x509 -req -days 365 \
  -in "${TMPDIR}/csr.pem" \
  -CA "${TMPDIR}/ca.crt" \
  -CAkey "${TMPDIR}/ca.key" \
  -CAcreateserial \
  -out "${TMPDIR}/tls.crt" \
  -extfile <(printf "subjectAltName=DNS:%s" "${HOST}") 2>/dev/null

echo "==> Creating/updating TLS Secret ${CERT_NAME}"
kctl -n "${NS}" create secret tls "${CERT_NAME}" \
  --cert="${TMPDIR}/tls.crt" \
  --key="${TMPDIR}/tls.key" \
  --dry-run=client -o yaml | kctl apply -f -
echo "PASS: TLS Secret ${CERT_NAME} created"

echo "==> Creating/updating CA ConfigMap ${CA_CONFIGMAP}"
kctl -n "${NS}" create configmap "${CA_CONFIGMAP}" \
  --from-file=ca.crt="${TMPDIR}/ca.crt" \
  --dry-run=client -o yaml | kctl apply -f -
echo "PASS: CA ConfigMap ${CA_CONFIGMAP} created"

echo "PASS: Backend TLS certs generated and applied"
