#!/usr/bin/env bash
# Istio ingress gateway basic smoke assertion.
# Verifies: Gateway + VirtualService applied, traffic routed through
# the istio-ingressgateway pod to the product Service with HTTP 200.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SVC_PORT="${SERVICE_PORT:-80}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

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

echo "==> Waiting for istiod to reconcile Gateway (15s)"
sleep 15

echo "==> Verifying Gateway resource is admitted"
if kctl -n "${NS}" get gateway "${RELEASE}-igw" > /dev/null 2>&1; then
  echo "  ✓ Gateway ${RELEASE}-igw exists"
else
  echo "FAIL: Gateway ${RELEASE}-igw not found" >&2
  echo "  Available CRDs:" >&2
  kctl get crd | grep istio.io || true >&2
  exit 1
fi

echo "==> Verifying VirtualService resource exists"
if kctl -n "${NS}" get virtualservice "${RELEASE}-vs" > /dev/null 2>&1; then
  echo "  ✓ VirtualService ${RELEASE}-vs exists"
else
  echo "FAIL: VirtualService ${RELEASE}-vs not found" >&2
  exit 1
fi

echo "==> Getting istio-ingressgateway pod IP"
GW_POD_IP=$(kctl -n istio-system get pod \
  -l app=istio-ingressgateway \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")
if [ -z "${GW_POD_IP}" ]; then
  echo "FAIL: Could not find istio-ingressgateway pod" >&2
  kctl -n istio-system get pods -l app=istio-ingressgateway >&2 || true
  exit 1
fi
echo "  Gateway pod IP: ${GW_POD_IP}"

echo "==> Probing product through istio ingress gateway"
HTTP_CODE=$(kctl -n "${NS}" run ct-igw-probe --restart=Never --rm -i \
  --image=quay.io/curl/curl:8.20.0 --timeout=60s \
  -- sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'Host: ${RELEASE}.test.local' \
    'http://${GW_POD_IP}:80/'" 2>/dev/null || echo "000")
HTTP_CODE=$(echo "$HTTP_CODE" | grep -oE '[0-9]{3}' | tail -1 || echo "000")

echo "HTTP response through gateway: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: traffic routed through istio ingress gateway"
else
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  # Debug: try verbose curl
  kctl -n "${NS}" run ct-igw-debug --restart=Never --rm -i \
    --image=quay.io/curl/curl:8.20.0 --timeout=30s \
    -- sh -c "curl -v --max-time 15 -H 'Host: ${RELEASE}.test.local' \
      'http://${GW_POD_IP}:80/'" 2>&1 || true
  exit 1
fi

echo "PASS: istio ingress gateway basic integration verified"
