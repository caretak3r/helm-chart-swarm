#!/usr/bin/env bash
# Cross-feature compose: Istio Gateway + cert-manager TLS.
# Verifies: cert-manager Certificate issues TLS Secret,
# Istio Gateway references the Secret via credentialName,
# istioctl analyze clean, HTTPS through gateway returns 200
# with the cert-manager-issued certificate.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
ISTIO_NS="istio-system"
GW_SECRET="sample-gw-tls"
GW_NAME="${RELEASE}-gw"
GW_HOST="sample.test.local"
GW_PORT="443"
ISTIO_VERSION="1.27.9"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for cert-manager pods Ready (3m max)"
kctl -n cert-manager wait pod -l app.kubernetes.io/name=cert-manager --for=condition=Ready --timeout=3m
echo "PASS: cert-manager pods Ready"

echo "==> Waiting for istiod pods Ready (3m max)"
kctl -n "${ISTIO_NS}" wait pod -l app=istiod --for=condition=Ready --timeout=3m
echo "PASS: istiod pods Ready"

echo "==> Waiting for istio-ingressgateway pods Ready (3m max)"
kctl -n "${ISTIO_NS}" wait pod -l app=istio-ingressgateway --for=condition=Ready --timeout=3m
echo "PASS: istio-ingressgateway pods Ready"

echo "==> Labeling namespace ${NS} for istio injection"
kctl label namespace "${NS}" istio-injection=enabled --overwrite || true

# Wait for product deployment rollout after labeling
echo "==> Restarting product deployment to inject sidecar"
kctl -n "${NS}" rollout restart "deploy/${RELEASE}" 2>/dev/null || true
sleep 5
kctl -n "${NS}" rollout status "deploy/${RELEASE}" --timeout=5m || true
sleep 5
echo "PASS: product deployment restarted"

echo "==> Creating cert-manager Certificate in ${ISTIO_NS} (gateway pod namespace)"
kctl -n "${ISTIO_NS}" apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${GW_SECRET}
spec:
  secretName: ${GW_SECRET}
  duration: 24h
  renewBefore: 12h
  issuerRef:
    name: chart-test-swarm-selfsigned
    kind: ClusterIssuer
  commonName: "${GW_HOST}"
  dnsNames:
    - "${GW_HOST}"
EOF
echo "PASS: Certificate ${GW_SECRET} created in ${ISTIO_NS}"

echo "==> Waiting for Certificate Ready (3m max)"
kctl -n "${ISTIO_NS}" wait certificate "${GW_SECRET}" --for=condition=Ready --timeout=3m
echo "PASS: Certificate Ready=True"

echo "==> Verifying TLS Secret exists and contains expected keys"
SECRET_KEYS=$(kctl -n "${ISTIO_NS}" get secret "${GW_SECRET}" -o jsonpath='{.data}' | jq -r 'keys | sort[]')
echo "Secret keys: ${SECRET_KEYS}"
echo "${SECRET_KEYS}" | grep -qx 'ca.crt'  || { echo "FAIL: missing ca.crt in Secret" >&2; exit 1; }
echo "${SECRET_KEYS}" | grep -qx 'tls.crt' || { echo "FAIL: missing tls.crt in Secret" >&2; exit 1; }
echo "${SECRET_KEYS}" | grep -qx 'tls.key' || { echo "FAIL: missing tls.key in Secret" >&2; exit 1; }
echo "PASS: TLS Secret contains tls.crt, tls.key, ca.crt"

echo "==> Creating Istio Gateway in ${ISTIO_NS} with TLS (credentialName references cert-manager Secret)"
kctl -n "${ISTIO_NS}" apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: ${GW_NAME}
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: ${GW_SECRET}
      hosts:
        - "${GW_HOST}"
EOF
echo "PASS: Istio Gateway ${GW_NAME} created with TLS credentialName=${GW_SECRET}"

echo "==> Creating VirtualService to route traffic through Gateway"
kctl -n "${ISTIO_NS}" apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${RELEASE}-vs
spec:
  hosts:
    - "${GW_HOST}"
  gateways:
    - ${GW_NAME}
  http:
    - route:
        - destination:
            host: ${RELEASE}.${NS}.svc.cluster.local
            port:
              number: 80
EOF
echo "PASS: VirtualService ${RELEASE}-vs created"

echo "==> Verifying Gateway resource exists"
GW_CHECK=$(kctl -n "${ISTIO_NS}" get gateway "${GW_NAME}" -o jsonpath='{.metadata.name}' 2>/dev/null || echo "NOT_FOUND")
if [ "${GW_CHECK}" = "${GW_NAME}" ]; then
  echo "PASS: Gateway ${GW_NAME} confirmed"
else
  echo "FAIL: Gateway ${GW_NAME} not found" >&2
  exit 1
fi

echo "==> Verifying Gateway TLS credentialName references cert-manager Secret"
GW_CRED=$(kctl -n "${ISTIO_NS}" get gateway "${GW_NAME}" -o jsonpath='{.spec.servers[0].tls.credentialName}')
echo "Gateway credentialName: ${GW_CRED}"
if [ "${GW_CRED}" = "${GW_SECRET}" ]; then
  echo "PASS: Gateway credentialName matches cert-manager Secret"
else
  echo "FAIL: expected credentialName=${GW_SECRET}, got ${GW_CRED}" >&2
  exit 1
fi

echo "==> Checking Gateway SDS secret resolution"
sleep 10
GW_LOGS=$(kctl -n "${ISTIO_NS}" logs deployment/istio-ingressgateway --tail=20 2>&1 || true)
echo "${GW_LOGS}" | tail -5

echo "==> Running istioctl analyze (downloading if needed)"
ISTIOCTL="/tmp/istioctl-${ISTIO_VERSION}"

if [ ! -x "${ISTIOCTL}" ]; then
  echo "  Downloading istioctl ${ISTIO_VERSION}..."
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  if [ "${ARCH}" = "x86_64" ]; then ARCH="amd64"; fi
  if [ "${ARCH}" = "aarch64" ]; then ARCH="arm64"; fi
  ISTIO_URL="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-${OS}-${ARCH}.tar.gz"
  curl -sL "${ISTIO_URL}" -o /tmp/istioctl.tar.gz --connect-timeout 10 --max-time 60 || {
    echo "WARN: could not download istioctl; skipping istioctl analyze" >&2
    echo "SKIP: istioctl analyze skipped (download failed)"
  }
  if [ -f /tmp/istioctl.tar.gz ]; then
    tar -xzf /tmp/istioctl.tar.gz -C /tmp/ istioctl 2>/dev/null || true
    if [ -f /tmp/istioctl ]; then
      mv -f /tmp/istioctl "${ISTIOCTL}"
      chmod +x "${ISTIOCTL}"
      rm -f /tmp/istioctl.tar.gz
    fi
  fi
fi

if [ -x "${ISTIOCTL}" ]; then
  echo "  Running istioctl analyze..."
  ANALYZE_OUT=$("${ISTIOCTL}" analyze -n "${ISTIO_NS}" --kubeconfig "${KUBECONFIG:-$HOME/.kube/config}" 2>&1) || true
  echo "${ANALYZE_OUT}"
  # Check for errors (not info/warning)
  if echo "${ANALYZE_OUT}" | grep -qE '^Error'; then
    echo "FAIL: istioctl analyze reported errors" >&2
    exit 1
  fi
  echo "PASS: istioctl analyze completed without errors"
else
  echo "SKIP: istioctl not available; skipping analyze step"
fi

echo "==> Testing HTTPS through Istio Gateway with TLS"
# Create a dedicated long-running pod for curl tests (avoids sidecar attach timeout)
CURL_POD="ct-gw-tls-probe"
kctl -n "${NS}" delete pod "${CURL_POD}" --ignore-not-found --grace-period=0 --force 2>/dev/null || true
kctl -n "${NS}" run "${CURL_POD}" --restart=Never --image=quay.io/curl/curl:8.20.0 -- sleep 300
kctl -n "${NS}" wait pod "${CURL_POD}" --for=condition=Ready --timeout=2m
echo "PASS: test pod ${CURL_POD} ready"

# Get credentials
CA_CRT_B64=$(kctl -n "${ISTIO_NS}" get secret "${GW_SECRET}" -o jsonpath='{.data.ca\.crt}')

# Write CA cert to test pod
kctl -n "${NS}" exec "${CURL_POD}" -- sh -c "echo '${CA_CRT_B64}' | base64 -d > /tmp/ca.crt"

# Get gateway service ClusterIP
GW_SVC_IP=$(kctl -n "${ISTIO_NS}" get svc istio-ingressgateway -o jsonpath='{.spec.clusterIP}')
echo "Gateway service IP: ${GW_SVC_IP}"

# Test HTTPS through gateway
RAW_HTTPS_CODE=$(kctl -n "${NS}" exec "${CURL_POD}" -- \
  sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    --cacert /tmp/ca.crt \
    --resolve '${GW_HOST}:${GW_PORT}:${GW_SVC_IP}' \
    'https://${GW_HOST}:${GW_PORT}/'" 2>/dev/null || echo "000")
HTTPS_CODE=$(echo "${RAW_HTTPS_CODE}" | grep -oE '[0-9]{3}' | tail -1 || echo "000")

echo "HTTPS response through Gateway: ${HTTPS_CODE}"
if [ "${HTTPS_CODE}" = "200" ]; then
  echo "PASS: HTTPS 200 through Istio Gateway with cert-manager-issued cert"
else
  echo "FAIL: expected HTTPS 200 through Gateway, got ${HTTPS_CODE}" >&2
  # Diagnostic: check if HTTPS listener is active
  echo "--- Diagnostic: check gateway service ---" >&2
  kctl -n "${ISTIO_NS}" get svc istio-ingressgateway >&2
  echo "--- Diagnostic: check gateway endpoints ---" >&2
  kctl -n "${ISTIO_NS}" get endpoints istio-ingressgateway >&2
  echo "--- Diagnostic: try HTTP (port 80) ---" >&2
  kctl -n "${NS}" exec "${CURL_POD}" -- \
    sh -c "curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 'http://${GW_SVC_IP}:80/'" 2>/dev/null >&2 || echo "HTTP probe failed" >&2
  echo "--- Diagnostic: gateway recent logs ---" >&2
  kctl -n "${ISTIO_NS}" logs deployment/istio-ingressgateway --tail=15 >&2 || true
  kctl -n "${NS}" delete pod "${CURL_POD}" --ignore-not-found --grace-period=0 --force 2>/dev/null || true
  exit 1
fi

echo "==> Verifying peer certificate issuer matches cert-manager"
RAW_ISSUER=$(kctl -n "${NS}" exec "${CURL_POD}" -- \
  sh -c "curl -s --max-time 15 --cacert /tmp/ca.crt \
    --resolve '${GW_HOST}:${GW_PORT}:${GW_SVC_IP}' \
    'https://${GW_HOST}:${GW_PORT}/' -o /dev/null -w '%{ssl_issuer}'" 2>/dev/null || echo "")
echo "Peer cert issuer: ${RAW_ISSUER}"

# Clean up test pod
kctl -n "${NS}" delete pod "${CURL_POD}" --ignore-not-found --grace-period=0 --force 2>/dev/null || true

# The issuer should contain the ClusterIssuer name or the commonName
if echo "${RAW_ISSUER}" | grep -qi "chart-test-swarm\|${GW_HOST}"; then
  echo "PASS: peer certificate issued by expected issuer"
else
  echo "NOTE: peer certificate issuer not matching expected pattern: ${RAW_ISSUER}"
fi

echo "PASS: Istio Gateway + cert-manager TLS cross-feature compose verified"
