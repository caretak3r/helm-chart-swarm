#!/usr/bin/env bash
# Envoy Gateway SecurityPolicy (CORS) smoke assertion.
# Verifies: SecurityPolicy Accepted=True, CORS header on preflight OPTIONS request.
# GatewayClass + Gateway + HTTPRoute + SecurityPolicy are applied from a fixture.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
GW_NS="${GW_NAMESPACE:-envoy-gateway-system}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Applying GatewayClass + Gateway (staged)"
kctl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: sample-gw
  namespace: sample
spec:
  gatewayClassName: envoy
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
EOF

echo "==> Waiting for Gateway listener http Programmed=True (5m max)"
for i in $(seq 1 50); do
  programmed=$(kctl -n "${NS}" get gateway sample-gw -o jsonpath='{.status.listeners[?(@.name=="http")].conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
  if [ "$programmed" = "True" ]; then
    echo "PASS: Gateway listener http Programmed=True"
    break
  fi
  if [ "$i" -eq 50 ]; then
    echo "FAIL: Gateway listener http not Programmed after 5m" >&2
    kctl -n "${NS}" get gateway sample-gw -o yaml >&2
    exit 1
  fi
  sleep 6
done

echo "==> Applying HTTPRoute + SecurityPolicy"
kctl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: sample-route
  namespace: sample
spec:
  parentRefs:
    - name: sample-gw
      sectionName: http
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: sample
          port: 80
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: sample-cors-policy
  namespace: sample
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: sample-gw
  cors:
    allowOrigins:
      - "*"
    allowMethods:
      - GET
      - POST
      - OPTIONS
    allowHeaders:
      - "*"
    maxAge: 86400s
EOF

echo "==> Waiting for GatewayClass envoy Accepted=True (3m max)"
for i in $(seq 1 30); do
  accepted=$(kctl get gatewayclass envoy -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: GatewayClass envoy Accepted=True"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: GatewayClass envoy not Accepted after 3m" >&2
    exit 1
  fi
  sleep 6
done

echo "==> Verifying HTTPRoute sample-route Accepted=True"
for i in $(seq 1 20); do
  accepted=$(kctl -n "${NS}" get httproute sample-route -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: HTTPRoute sample-route Accepted=True"
    break
  fi
  if [ "$i" -eq 20 ]; then
    echo "FAIL: HTTPRoute sample-route not Accepted after 2m" >&2
    exit 1
  fi
  sleep 6
done

echo "==> Verifying SecurityPolicy Accepted=True"
for i in $(seq 1 20); do
  accepted=$(kctl -n "${NS}" get securitypolicy.gateway.envoyproxy.io sample-cors-policy -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: SecurityPolicy sample-cors-policy Accepted=True"
    break
  fi
  if [ "$i" -eq 20 ]; then
    echo "FAIL: SecurityPolicy sample-cors-policy not Accepted after 2m" >&2
    kctl -n "${NS}" get securitypolicy.gateway.envoyproxy.io sample-cors-policy -o yaml >&2
    exit 1
  fi
  sleep 6
done

echo "==> Getting envoy data-plane Service ClusterIP"
GW_SVC_IP=$(kctl -n "${GW_NS}" get svc -l gateway.envoyproxy.io/owning-gateway-name=sample-gw -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
echo "Gateway Service IP: ${GW_SVC_IP}"

# Verify CORS policy effect: preflight OPTIONS should return CORS header (retry up to 2m)
echo "==> Probing CORS preflight (OPTIONS request)"
CORS_HEADER=""
for attempt in $(seq 1 20); do
  CORS_HEADER=$(kctl -n "${NS}" run "ct-cors-${attempt}" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.6.0 --timeout=30s -- \
    curl -s -I -X OPTIONS --max-time 15 \
      -H "Host: sample.sample.svc.cluster.local" \
      -H "Origin: http://example.com" \
      -H "Access-Control-Request-Method: GET" \
      "http://${GW_SVC_IP}:80/" 2>/dev/null | grep -i 'access-control-allow-origin') || true
  if [ -n "${CORS_HEADER}" ]; then
    echo "CORS response: ${CORS_HEADER} (attempt ${attempt})"
    break
  fi
  [ "$attempt" -lt 20 ] && sleep 6
done

echo "CORS response: ${CORS_HEADER}"
if echo "${CORS_HEADER}" | grep -qi 'access-control-allow-origin'; then
  echo "PASS: CORS header present on preflight response"
else
  echo "FAIL: expected CORS header on preflight, got none" >&2
  exit 1
fi

echo "PASS: envoy-gateway SecurityPolicy CORS integration verified"
