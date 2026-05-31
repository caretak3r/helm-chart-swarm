#!/usr/bin/env bash
# Contour Gateway API response-header-modifier smoke assertion.
# Verifies: GatewayClass contour Accepted=True, Gateway Programmed=True,
#           HTTPRoute Accepted=True, ResponseHeaderModifier filter applied,
#           curl response includes the configured header.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Applying GatewayClass contour + Gateway + HTTPRoute (with ResponseHeaderModifier)"
kctl apply -f "${PROJECT_DIR}/chart-test/fixtures/gateway-api/contour-gateway-api-response-header-modifier-gateway.yaml"

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

echo "==> Verifying HTTPRoute sample-route Accepted=True"
for i in $(seq 1 20); do
  accepted=$(kctl -n "${NS}" get httproute sample-route -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: HTTPRoute sample-route Accepted=True"
    break
  fi
  if [ "$i" -eq 20 ]; then
    echo "FAIL: HTTPRoute sample-route not Accepted after 2m" >&2
    kctl -n "${NS}" get httproute sample-route -o yaml >&2
    exit 1
  fi
  sleep 6
done

echo "==> Verifying ResponseHeaderModifier filter is configured on HTTPRoute"
FILTER_TYPE=$(kctl -n "${NS}" get httproute sample-route -o jsonpath='{.spec.rules[0].filters[0].type}' 2>/dev/null || echo "MISSING")
echo "Filter type: ${FILTER_TYPE}"
if [ "${FILTER_TYPE}" = "ResponseHeaderModifier" ]; then
  echo "PASS: ResponseHeaderModifier filter configured on HTTPRoute"
else
  echo "FAIL: expected ResponseHeaderModifier filter, got ${FILTER_TYPE}" >&2
  exit 1
fi

echo "==> Getting Envoy Service ClusterIP in ${NS}"
GW_SVC_IP=$(kctl -n "${NS}" get svc -l gateway.networking.k8s.io/gateway-name=sample-gw -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
echo "Envoy Service IP: ${GW_SVC_IP}"

echo "==> Probing backend via gateway (retry up to 2m for data-plane ready)"
HTTP_CODE="000"
X_POWERED_BY=""
for attempt in $(seq 1 20); do
  RESPONSE=$(kctl -n "${NS}" run "ct-probe-${attempt}" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.6.0 --timeout=30s -- \
    curl -s -D /dev/stderr -o /dev/null --max-time 15 \
      -H "Host: sample.sample.svc.cluster.local" \
      "http://${GW_SVC_IP}:80/" 2>&1) || true

  HTTP_CODE=$(echo "$RESPONSE" | grep -i '^HTTP/' | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  X_POWERED_BY=$(echo "$RESPONSE" | grep -i '^x-powered-by:' | head -1 | sed 's/\r$//' || echo "")

  if [ "${HTTP_CODE}" = "200" ] && [ -n "${X_POWERED_BY}" ]; then
    echo "HTTP response: ${HTTP_CODE} (attempt ${attempt})"
    break
  fi
  [ "$attempt" -lt 20 ] && sleep 6
done

echo "HTTP response: ${HTTP_CODE}"
echo "X-Powered-By header: ${X_POWERED_BY}"

if [ "${HTTP_CODE}" != "200" ]; then
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi

if echo "${X_POWERED_BY}" | grep -qi "chart-test-swarm"; then
  echo "PASS: X-Powered-By header includes chart-test-swarm as configured"
else
  echo "FAIL: X-Powered-By header not found or does not contain 'chart-test-swarm'" >&2
  exit 1
fi

echo "PASS: contour-gateway-api response-header-modifier integration verified"
