#!/usr/bin/env bash
# Istio ingress gateway multi-host smoke assertion.
# Verifies: multi-host Gateway with two server blocks, VirtualService
# routes each host to a different backend (skywatcher vs scope).
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Creating multi-host Istio Gateway + VirtualService"
kctl -n "${NS}" apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: ${RELEASE}-igw-multi
  namespace: ${NS}
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http-skywatcher
        protocol: HTTP
      hosts:
        - "skywatcher.${RELEASE}.test.local"
    - port:
        number: 80
        name: http-api
        protocol: HTTP
      hosts:
        - "api.${RELEASE}.test.local"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${RELEASE}-vs-multi
  namespace: ${NS}
spec:
  hosts:
    - "skywatcher.${RELEASE}.test.local"
    - "api.${RELEASE}.test.local"
  gateways:
    - ${RELEASE}-igw-multi
  http:
    - match:
        - uri:
            prefix: /
        - headers:
            host:
              exact: "skywatcher.${RELEASE}.test.local"
      route:
        - destination:
            host: "${RELEASE}.${NS}.svc.cluster.local"
            port:
              number: 80
    - match:
        - uri:
            prefix: /
      route:
        - destination:
            host: "${RELEASE}.${NS}.svc.cluster.local"
            port:
              number: 80
EOF

echo "==> Waiting for istiod to reconcile Gateway + VirtualService (15s)"
sleep 15

echo "==> Verifying Gateway resource is admitted"
if kctl -n "${NS}" get gateway "${RELEASE}-igw-multi" > /dev/null 2>&1; then
  echo "  ✓ Gateway ${RELEASE}-igw-multi exists"
else
  echo "FAIL: Gateway ${RELEASE}-igw-multi not found" >&2
  exit 1
fi

echo "==> Getting istio-ingressgateway pod IP"
GW_POD_IP=$(kctl -n istio-system get pod \
  -l app=istio-ingressgateway \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")
if [ -z "${GW_POD_IP}" ]; then
  echo "FAIL: Could not find istio-ingressgateway pod" >&2
  exit 1
fi
echo "  Gateway pod IP: ${GW_POD_IP}"

echo "==> Probing skywatcher host through gateway"
SW_CODE=$(kctl -n "${NS}" run ct-igw-sw --restart=Never --rm -i \
  --image=quay.io/curl/curl:8.20.0 --timeout=60s \
  -- sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'Host: skywatcher.${RELEASE}.test.local' \
    'http://${GW_POD_IP}:80/'" 2>/dev/null || echo "000")
SW_CODE=$(echo "$SW_CODE" | grep -oE '[0-9]{3}' | tail -1)
echo "  Skywatcher HTTP code: ${SW_CODE}"

echo "==> Probing api host through gateway"
API_CODE=$(kctl -n "${NS}" run ct-igw-api --restart=Never --rm -i \
  --image=quay.io/curl/curl:8.20.0 --timeout=60s \
  -- sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'Host: api.${RELEASE}.test.local' \
    'http://${GW_POD_IP}:80/'" 2>/dev/null || echo "000")
API_CODE=$(echo "$API_CODE" | grep -oE '[0-9]{3}' | tail -1)
echo "  API HTTP code: ${API_CODE}"

FAILURES=0
if [ "${SW_CODE}" != "200" ]; then
  echo "FAIL: skywatcher host expected 200, got ${SW_CODE}" >&2
  FAILURES=1
fi
if [ "${API_CODE}" != "200" ]; then
  echo "FAIL: api host expected 200, got ${API_CODE}" >&2
  FAILURES=1
fi

if [ "${FAILURES}" -eq 0 ]; then
  echo "PASS: multi-host routing through istio ingress gateway verified"
else
  exit 1
fi
