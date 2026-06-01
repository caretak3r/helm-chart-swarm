#!/usr/bin/env bash
# Linkerd cert generation. Generates ephemeral ECDSA P-256 trust anchor and issuer
# certs at runtime, then upgrades the linkerd-control-plane Helm release with the
# generated certs. This replaces the REPLACE_AT_RUNTIME placeholders in
# linkerd-control-plane-values.yaml with real but ephemeral certs.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

CTRL_NS="linkerd"
CTRL_RELEASE="linkerd-control-plane"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }
helm_cmd() { helm ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} "$@"; }

echo "==> Generating ephemeral ECDSA P-256 trust anchor and issuer certs"
TMPDIR=$(mktemp -d)
trap 'rm -rf ${TMPDIR}' EXIT

# Generate trust anchor (root CA) private key
openssl ecparam -name prime256v1 -genkey -noout \
  -out "${TMPDIR}/trust-anchor-key.pem" 2>/dev/null

# Generate trust anchor self-signed cert
openssl req -x509 -new -key "${TMPDIR}/trust-anchor-key.pem" -days 3650 \
  -out "${TMPDIR}/trust-anchor.crt" \
  -subj "/CN=root.linkerd.cluster.local" 2>/dev/null

# Generate issuer private key
openssl ecparam -name prime256v1 -genkey -noout \
  -out "${TMPDIR}/issuer-key.pem" 2>/dev/null

# Convert issuer key to PKCS#8 (Linkerd expects PKCS#8 format)
openssl pkcs8 -topk8 -nocrypt -in "${TMPDIR}/issuer-key.pem" \
  -out "${TMPDIR}/issuer-key-pkcs8.pem" 2>/dev/null

# Generate issuer CSR
openssl req -new -key "${TMPDIR}/issuer-key.pem" \
  -out "${TMPDIR}/issuer.csr" \
  -subj "/CN=identity.linkerd.cluster.local" 2>/dev/null

# Create extensions file for intermediate CA (Linkerd requires CA:TRUE on issuer cert)
cat > "${TMPDIR}/issuer-ext.cnf" <<EOF
[ v3_intermediate_ca ]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

# Sign issuer cert with trust anchor, applying intermediate CA extensions
openssl x509 -req -in "${TMPDIR}/issuer.csr" \
  -CA "${TMPDIR}/trust-anchor.crt" \
  -CAkey "${TMPDIR}/trust-anchor-key.pem" \
  -CAcreateserial -out "${TMPDIR}/issuer.crt" -days 365 \
  -extfile "${TMPDIR}/issuer-ext.cnf" \
  -extensions v3_intermediate_ca 2>/dev/null

# Read certs and keys
TRUST_ANCHOR_CERT=$(cat "${TMPDIR}/trust-anchor.crt")
ISSUER_CERT=$(cat "${TMPDIR}/issuer.crt")
ISSUER_KEY=$(cat "${TMPDIR}/issuer-key-pkcs8.pem")

echo "==> Creating temp values.yaml with generated certs"
cat > "${TMPDIR}/values.yaml" <<VALUESEOF
proxy:
  resources:
    cpu:
      limit: "250m"
      request: "100m"
    memory:
      limit: "256Mi"
      request: "64Mi"
identity:
  issuer:
    scheme: linkerd.io/tls
    tls:
      crtPEM: |
$(echo "${ISSUER_CERT}" | sed 's/^/        /')
      keyPEM: |
$(echo "${ISSUER_KEY}" | sed 's/^/        /')
identityTrustAnchorsPEM: |
$(echo "${TRUST_ANCHOR_CERT}" | sed 's/^/  /')
VALUESEOF

# Detect the currently installed chart version
CHART_VERSION=$(helm_cmd list -n "${CTRL_NS}" -o json 2>/dev/null | \
  jq -r ".[] | select(.name==\"${CTRL_RELEASE}\") | .chart" | \
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
if [ -z "${CHART_VERSION}" ]; then
  echo "WARN: could not detect linkerd-control-plane chart version, defaulting to 1.16.11"
  CHART_VERSION="1.16.11"
fi

echo "==> Upgrading linkerd-control-plane (v${CHART_VERSION}) with generated certs"
helm_cmd upgrade "${CTRL_RELEASE}" linkerd/linkerd-control-plane \
  --namespace "${CTRL_NS}" \
  --version "${CHART_VERSION}" \
  --values "${TMPDIR}/values.yaml"

echo "==> Waiting for linkerd control-plane rollout to complete"
# Wait for each deployment to roll out (new pods ready, old pods terminated).
# The old pods from the initial install have broken certs and won't become Ready.
# We give each deployment up to 5 minutes to complete its rollout.
for deploy in linkerd-destination linkerd-identity linkerd-proxy-injector; do
  echo "  Waiting for deployment/${deploy} rollout (5m max)..."
  kctl -n "${CTRL_NS}" rollout status "deployment/${deploy}" --timeout=5m || {
    echo "WARN: deployment/${deploy} rollout did not complete within 5m"
    echo "  Current pod states:"
    kctl -n "${CTRL_NS}" get pods -o wide 2>/dev/null || true
  }
done

# Force-delete any pods that are still stuck in non-Ready state (old pods from
# the initial install with REPLACE_AT_RUNTIME certs that refuse to terminate).
# This ensures the subsequent pods-ready assertion doesn't wait on dead pods.
echo "==> Cleaning up any stuck old pods"
while IFS= read -r pod; do
  if [ -n "${pod}" ]; then
    echo "  Force-deleting stuck pod: ${pod}"
    kctl -n "${CTRL_NS}" delete pod "${pod}" --force --grace-period=0 2>/dev/null || true
  fi
done < <(kctl -n "${CTRL_NS}" get pods -o json 2>/dev/null | \
  jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready") | .status != "True") | .metadata.name' 2>/dev/null || echo "")
sleep 3

echo "PASS: linkerd-control-plane upgraded with ephemeral certs"
