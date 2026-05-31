#!/usr/bin/env bash
# Contour Gateway API route-precedence smoke assertion.
# Verifies: Two HTTPRoutes for the same host with overlapping prefixes:
#   more specific (/api/v2) wins, less specific (/api) wins for non-overlapping.
#   Response headers identify which route handled the request.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Applying GatewayClass contour + Gateway + two HTTPRoutes"
kctl apply -f "${PROJECT_DIR}/chart-test/fixtures/gateway-api/contour-gateway-api-route-precedence-gateway.yaml"

echo "==> Waiting for GatewayClass contour Accepted=True (3m max)"
for i in $(seq 1 30); do
  accepted=$(kctl get gatewayclass contour -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: GatewayClass contour Accepted=True"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: GatewayClass contour not Accepted after 3m" >&2
    kctl get gatewayclass contour -o yaml >&2
    exit 1
  fi
  sleep 6
done

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

echo "==> Verifying auto-provisioned Envoy Deployment in ${NS} namespace"
for i in $(seq 1 15); do
  dep_count=$(kctl -n "${NS}" get deploy -l gateway.networking.k8s.io/gateway-name=sample-gw -o name 2>/dev/null | wc -l | tr -d ' ')
  if [ "$dep_count" -ge 1 ]; then
    echo "PASS: auto-provisioned Envoy Deployment found (${dep_count})"
    break
  fi
  if [ "$i" -eq 15 ]; then
    echo "FAIL: no auto-provisioned Deployment with label gateway.networking.k8s.io/gateway-name=sample-gw after 90s" >&2
    exit 1
  fi
  sleep 6
done

echo "==> Waiting for Envoy pods Ready (3m max)"
kctl -n "${NS}" wait pod -l gateway.networking.k8s.io/gateway-name=sample-gw --for=condition=Ready --timeout=3m
echo "PASS: Envoy pods Ready"

echo "==> Verifying HTTPRoute sample-route-api Accepted=True"
for i in $(seq 1 20); do
  accepted=$(kctl -n "${NS}" get httproute sample-route-api -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: HTTPRoute sample-route-api Accepted=True"
    break
  fi
  if [ "$i" -eq 20 ]; then
    echo "FAIL: HTTPRoute sample-route-api not Accepted after 2m" >&2
    kctl -n "${NS}" get httproute sample-route-api -o yaml >&2
    exit 1
  fi
  sleep 6
done

echo "==> Verifying HTTPRoute sample-route-api-v2 Accepted=True"
for i in $(seq 1 20); do
  accepted=$(kctl -n "${NS}" get httproute sample-route-api-v2 -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: HTTPRoute sample-route-api-v2 Accepted=True"
    break
  fi
  if [ "$i" -eq 20 ]; then
    echo "FAIL: HTTPRoute sample-route-api-v2 not Accepted after 2m" >&2
    kctl -n "${NS}" get httproute sample-route-api-v2 -o yaml >&2
    exit 1
  fi
  sleep 6
done

echo "==> Getting Envoy Service ClusterIP in ${NS}"
GW_SVC_IP=$(kctl -n "${NS}" get svc -l gateway.networking.k8s.io/gateway-name=sample-gw -o json 2>/dev/null | jq -r '.items[] | select(.spec.ports[].port == 80) | .spec.clusterIP')
echo "Envoy Service IP: ${GW_SVC_IP}"

echo "==> Test 1: /api/v2/foo → expect X-Route: v2 (more specific prefix wins)"
X_ROUTE=""
for attempt in $(seq 1 20); do
  RESPONSE=$(kctl -n "${NS}" run "ct-probe-v2-${attempt}" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.6.0 --timeout=30s -- \
    curl -s -D /dev/stderr -o /dev/null --max-time 15 \
      -H "Host: sample.test.local" \
      "http://${GW_SVC_IP}:80/api/v2/foo" 2>&1) || true

  HTTP_CODE=$(echo "$RESPONSE" | grep -i '^HTTP/' | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  X_ROUTE=$(echo "$RESPONSE" | grep -i '^x-route:' | head -1 | sed 's/\r$//' || echo "")

  if [ "${HTTP_CODE}" = "200" ] && [ -n "${X_ROUTE}" ]; then
    echo "HTTP response: ${HTTP_CODE}, X-Route: ${X_ROUTE} (attempt ${attempt})"
    break
  fi
  [ "$attempt" -lt 20 ] && sleep 6
done

echo "Test /api/v2/foo → X-Route header: ${X_ROUTE}"
if echo "${X_ROUTE}" | grep -qi "v2"; then
  echo "PASS: /api/v2/foo routed to v2 (more specific prefix wins)"
else
  echo "FAIL: expected X-Route: v2 for /api/v2/foo, got ${X_ROUTE}" >&2
  exit 1
fi

echo "==> Test 2: /api/foo → expect X-Route: v1 (less specific prefix wins for non-overlapping paths)"
X_ROUTE=""
for attempt in $(seq 1 20); do
  RESPONSE=$(kctl -n "${NS}" run "ct-probe-v1-${attempt}" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.6.0 --timeout=30s -- \
    curl -s -D /dev/stderr -o /dev/null --max-time 15 \
      -H "Host: sample.test.local" \
      "http://${GW_SVC_IP}:80/api/foo" 2>&1) || true

  HTTP_CODE=$(echo "$RESPONSE" | grep -i '^HTTP/' | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  X_ROUTE=$(echo "$RESPONSE" | grep -i '^x-route:' | head -1 | sed 's/\r$//' || echo "")

  if [ "${HTTP_CODE}" = "200" ] && [ -n "${X_ROUTE}" ]; then
    echo "HTTP response: ${HTTP_CODE}, X-Route: ${X_ROUTE} (attempt ${attempt})"
    break
  fi
  [ "$attempt" -lt 20 ] && sleep 6
done

echo "Test /api/foo → X-Route header: ${X_ROUTE}"
if echo "${X_ROUTE}" | grep -qi "v1"; then
  echo "PASS: /api/foo routed to v1 (less specific prefix wins for non-overlapping)"
else
  echo "FAIL: expected X-Route: v1 for /api/foo, got ${X_ROUTE}" >&2
  exit 1
fi

echo "PASS: contour-gateway-api route-precedence integration verified"
