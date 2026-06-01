#!/usr/bin/env bash
# Istio ingress gateway RequestAuthentication (no deny) smoke assertion.
# Verifies: RequestAuthentication validates JWT but does NOT enforce.
# - No Bearer token → still passes through (HTTP 200)
# - Valid JWT → HTTP 200
# - Invalid JWT (wrong issuer) → still passes through (HTTP 200) since
#   there is no AuthorizationPolicy DENY rule — only validation, not enforcement.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SVC_PORT="${SERVICE_PORT:-80}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

# Generate ephemeral RSA 2048-bit key and JWKS at runtime (no committed private key)
echo "==> Generating ephemeral RSA 2048-bit JWT signing key"
TMPDIR=$(mktemp -d)
trap 'rm -rf ${TMPDIR}' EXIT

JWT_KEY_FILE="${TMPDIR}/jwt-key.pem"
JWT_PUB_FILE="${TMPDIR}/jwt-key.pub"
JWKS_FILE="${TMPDIR}/jwks.json"

openssl genpkey -algorithm RSA -out "${JWT_KEY_FILE}" -pkeyopt rsa_keygen_bits:2048 2>/dev/null
openssl rsa -in "${JWT_KEY_FILE}" -pubout -out "${JWT_PUB_FILE}" 2>/dev/null

# Generate JWKS from the public key
python3 -c "
import json, base64, subprocess

# Extract modulus using openssl
result = subprocess.run(['openssl', 'rsa', '-in', '${JWT_PUB_FILE}', '-pubin', '-noout', '-modulus'],
                       capture_output=True, text=True)
modulus_hex = result.stdout.strip().replace('Modulus=', '').replace('\n', '').replace(':', '')
n_bytes = bytes.fromhex(modulus_hex)

def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode()

jwks = {
    'keys': [{
        'kty': 'RSA',
        'use': 'sig',
        'alg': 'RS256',
        'kid': 'test-issuer-key',
        'n': b64url(n_bytes),
        'e': 'AQAB'
    }]
}
with open('${JWKS_FILE}', 'w') as f:
    json.dump(jwks, f, indent=2)
" 2>/dev/null || {
  echo "FAIL: Could not generate JWKS (Python unavailable)" >&2
  exit 1
}

echo "==> JWT key generated at: ${JWT_KEY_FILE}"

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

echo "==> Creating RequestAuthentication (JWT validation ONLY, no deny)"
# Policy must be in istio-system because ingressgateway pods run there
GW_NS="istio-system"
JWKS_CONTENT=$(cat "${JWKS_FILE}")
kctl -n "${GW_NS}" apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: ${RELEASE}-jwt-validate
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

# JWT signing helper
jwt_sign() {
  local issuer="$1"
  local header='{"alg":"RS256","typ":"JWT","kid":"test-issuer-key"}'
  local now
  now=$(date +%s)
  local exp=$((now + 3600))
  local payload="{\"iss\":\"${issuer}\",\"sub\":\"test-user\",\"iat\":${now},\"exp\":${exp}}"

  local header_b64
  header_b64=$(echo -n "$header" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  local payload_b64
  payload_b64=$(echo -n "$payload" | openssl base64 -A | tr '+/' '-_' | tr -d '=')

  local signing_input="${header_b64}.${payload_b64}"

  local signature
  signature=$(echo -n "$signing_input" | openssl dgst -sha256 -sign "${JWT_KEY_FILE}" -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')

  echo "${signing_input}.${signature}"
}

VALID_JWT=$(jwt_sign "https://test-issuer.local")
# Create an invalid JWT with wrong issuer (but valid signature from same key)
INVALID_JWT=$(jwt_sign "https://wrong-issuer.local")

echo "==> Test 1: Request WITHOUT Bearer token → should pass (no deny rule)"
NOAUTH_CODE=$(kctl -n "${NS}" run ct-ra-noauth --restart=Never --rm -i \
  --image=quay.io/curl/curl:8.6.0 --timeout=60s \
  -- sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'Host: ${RELEASE}.test.local' \
    'http://${GW_POD_IP}:80/'" 2>/dev/null || echo "000")
NOAUTH_CODE=$(echo "$NOAUTH_CODE" | grep -oE '[0-9]{3}' | tail -1)
echo "  HTTP code (no auth): ${NOAUTH_CODE}"
if [ "${NOAUTH_CODE}" = "200" ]; then
  echo "  ✓ Request without token passes through (no enforcement)"
else
  echo "FAIL: expected 200 without token, got ${NOAUTH_CODE}" >&2
  exit 1
fi

echo "==> Test 2: Request WITH valid JWT → should succeed"
AUTH_CODE=$(kctl -n "${NS}" run ct-ra-valid --restart=Never --rm -i \
  --image=quay.io/curl/curl:8.6.0 --timeout=60s \
  -- sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'Host: ${RELEASE}.test.local' \
    -H 'Authorization: Bearer ${VALID_JWT}' \
    'http://${GW_POD_IP}:80/'" 2>/dev/null || echo "000")
AUTH_CODE=$(echo "$AUTH_CODE" | grep -oE '[0-9]{3}' | tail -1)
echo "  HTTP code (valid JWT): ${AUTH_CODE}"
if [ "${AUTH_CODE}" = "200" ]; then
  echo "  ✓ Request with valid JWT succeeds"
else
  echo "FAIL: expected 200 with valid JWT, got ${AUTH_CODE}" >&2
  exit 1
fi

echo "==> Test 3: Request WITH invalid JWT (wrong issuer) → should be rejected"
# RequestAuthentication validates JWTs even without AuthorizationPolicy.
# Invalid tokens (wrong issuer) are rejected with 401.
INV_CODE=$(kctl -n "${NS}" run ct-ra-invalid --restart=Never --rm -i \
  --image=quay.io/curl/curl:8.6.0 --timeout=60s \
  -- sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'Host: ${RELEASE}.test.local' \
    -H 'Authorization: Bearer ${INVALID_JWT}' \
    'http://${GW_POD_IP}:80/'" 2>/dev/null || echo "000")
INV_CODE=$(echo "$INV_CODE" | grep -oE '[0-9]{3}' | tail -1)
echo "  HTTP code (invalid JWT): ${INV_CODE}"
if [ "${INV_CODE}" = "401" ]; then
  echo "  ✓ Invalid JWT correctly rejected (RequestAuthentication validates)"
else
  echo "FAIL: expected 401 with invalid JWT, got ${INV_CODE}" >&2
  exit 1
fi

echo "PASS: istio ingress gateway RequestAuthentication (validate-only, no deny) verified"
