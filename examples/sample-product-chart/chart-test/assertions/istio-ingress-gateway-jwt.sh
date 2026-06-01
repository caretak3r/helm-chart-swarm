#!/usr/bin/env bash
# Istio ingress gateway JWT authentication smoke assertion.
# Verifies: RequestAuthentication + AuthorizationPolicy require valid JWT.
# - No Bearer token → HTTP 401 or 403
# - Valid JWT signed with test issuer key → HTTP 200
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SVC_PORT="${SERVICE_PORT:-80}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

# Extract the JWT private key from fixtures (PROJECT_DIR is chart root)
JWT_KEY_FILE="${PROJECT_DIR}/chart-test/fixtures/service-mesh/jwt/jwt-key.pem"
if [ ! -f "${JWT_KEY_FILE}" ]; then
  JWT_KEY_FILE="${PROJECT_DIR}/fixtures/service-mesh/jwt/jwt-key.pem"
fi
echo "==> JWT key path: ${JWT_KEY_FILE}"

echo "==> Creating Istio Gateway + VirtualService"
kctl -n "${NS}" apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: ${RELEASE}-igw
  namespace: ${NS}
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "${RELEASE}.test.local"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${RELEASE}-vs
  namespace: ${NS}
spec:
  hosts:
    - "${RELEASE}.test.local"
  gateways:
    - ${RELEASE}-igw
  http:
    - match:
        - uri:
            prefix: /
      route:
        - destination:
            host: "${RELEASE}.${NS}.svc.cluster.local"
            port:
              number: ${SVC_PORT}
EOF

echo "==> Creating RequestAuthentication (JWT validation)"
JWKS_CONTENT=$(cat "${PROJECT_DIR}/chart-test/fixtures/service-mesh/jwt/jwks.json" 2>/dev/null || \
  cat "${PROJECT_DIR}/fixtures/service-mesh/jwt/jwks.json" 2>/dev/null || echo "")
if [ -z "${JWKS_CONTENT}" ]; then
  echo "FAIL: Could not read jwks.json fixture" >&2
  exit 1
fi

# Policies must be in istio-system because ingressgateway pods run there
GW_NS="istio-system"

# Create ConfigMap with JWKS for RequestAuthentication reference
kctl -n "${GW_NS}" create configmap jwt-jwks \
  --from-literal=jwks.json="${JWKS_CONTENT}" \
  --dry-run=client -o yaml | kctl -n "${GW_NS}" apply -f -

kctl -n "${GW_NS}" apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: ${RELEASE}-jwt-auth
  namespace: ${GW_NS}
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  jwtRules:
    - issuer: "https://test-issuer.local"
      jwks: |
$(echo "${JWKS_CONTENT}" | sed 's/^/        /')
EOF

echo "==> Creating AuthorizationPolicy (require JWT via ALLOW)"
kctl -n "${GW_NS}" apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: ${RELEASE}-require-jwt
  namespace: ${GW_NS}
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  action: ALLOW
  rules:
    - from:
        - source:
            requestPrincipals: ["*"]
EOF

echo "==> Waiting for istiod to reconcile policies (15s)"
sleep 15

echo "==> Getting istio-ingressgateway pod IP"
GW_POD_IP=$(kctl -n istio-system get pod \
  -l app=istio-ingressgateway \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")
if [ -z "${GW_POD_IP}" ]; then
  echo "FAIL: Could not find istio-ingressgateway pod" >&2
  exit 1
fi
echo "  Gateway pod IP: ${GW_POD_IP}"

# Sign a JWT using openssl
echo "==> Signing JWT with test issuer key"

jwt_sign() {
  local header='{"alg":"RS256","typ":"JWT","kid":"test-issuer-key"}'
  local now
  now=$(date +%s)
  local exp=$((now + 3600))
  local payload="{\"iss\":\"https://test-issuer.local\",\"sub\":\"test-user\",\"iat\":${now},\"exp\":${exp}}"

  local header_b64
  header_b64=$(echo -n "$header" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  local payload_b64
  payload_b64=$(echo -n "$payload" | openssl base64 -A | tr '+/' '-_' | tr -d '=')

  local signing_input="${header_b64}.${payload_b64}"

  local signature
  signature=$(echo -n "$signing_input" | openssl dgst -sha256 -sign "${JWT_KEY_FILE}" -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')

  echo "${signing_input}.${signature}"
}

VALID_JWT=$(jwt_sign)
echo "  JWT generated (expires in 1h)"

echo "==> Test 1: Request WITHOUT Bearer token → expect 401 or 403"
NOAUTH_CODE=$(kctl -n "${NS}" run ct-jwt-noauth --restart=Never --rm -i \
  --image=quay.io/curl/curl:8.6.0 --timeout=60s \
  -- sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'Host: ${RELEASE}.test.local' \
    'http://${GW_POD_IP}:80/'" 2>/dev/null || echo "000")
NOAUTH_CODE=$(echo "$NOAUTH_CODE" | grep -oE '[0-9]{3}' | tail -1)
echo "  HTTP code (no auth): ${NOAUTH_CODE}"

if [ "${NOAUTH_CODE}" = "401" ] || [ "${NOAUTH_CODE}" = "403" ]; then
  echo "  ✓ Request without token correctly rejected"
else
  echo "FAIL: expected 401 or 403 without token, got ${NOAUTH_CODE}" >&2
  exit 1
fi

echo "==> Test 2: Request WITH valid Bearer token → expect 200"
AUTH_CODE=$(kctl -n "${NS}" run ct-jwt-auth --restart=Never --rm -i \
  --image=quay.io/curl/curl:8.6.0 --timeout=60s \
  -- sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'Host: ${RELEASE}.test.local' \
    -H 'Authorization: Bearer ${VALID_JWT}' \
    'http://${GW_POD_IP}:80/'" 2>/dev/null || echo "000")
AUTH_CODE=$(echo "$AUTH_CODE" | grep -oE '[0-9]{3}' | tail -1)
echo "  HTTP code (with valid JWT): ${AUTH_CODE}"

if [ "${AUTH_CODE}" = "200" ]; then
  echo "  ✓ Request with valid JWT succeeds"
else
  echo "FAIL: expected 200 with valid JWT, got ${AUTH_CODE}" >&2
  # Debug: try with verbose
  kctl -n "${NS}" run ct-jwt-debug --restart=Never --rm -i \
    --image=quay.io/curl/curl:8.6.0 --timeout=30s \
    -- sh -c "curl -v --max-time 15 \
      -H 'Host: ${RELEASE}.test.local' \
      -H 'Authorization: Bearer ${VALID_JWT}' \
      'http://${GW_POD_IP}:80/'" 2>&1 || true
  exit 1
fi

echo "PASS: istio ingress gateway JWT authentication verified"
