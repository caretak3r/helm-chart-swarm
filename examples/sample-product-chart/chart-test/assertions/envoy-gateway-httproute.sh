#!/usr/bin/env bash
# Envoy Gateway HTTPRoute smoke assertion.
# Verifies: GatewayClass envoy Accepted=True, Gateway Programmed=True,
#           HTTPRoute Accepted=True, HTTP curl returns 200.
# GatewayClass + Gateway + HTTPRoute are applied from a fixture.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
GW_NS="${GW_NAMESPACE:-envoy-gateway-system}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Applying GatewayClass + Gateway + HTTPRoute"
kctl apply -f "${PROJECT_DIR}/chart-test/fixtures/gateway-api/envoy-gateway-httproute-gateway.yaml"

echo "==> Waiting for GatewayClass envoy Accepted=True (3m max)"
for i in $(seq 1 30); do
  accepted=$(kctl get gatewayclass envoy -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: GatewayClass envoy Accepted=True"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: GatewayClass envoy not Accepted after 3m" >&2
    kctl get gatewayclass envoy -o yaml >&2
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

echo "==> Getting envoy data-plane Service ClusterIP"
# The envoy-gateway controller creates a LoadBalancer Service per Gateway in envoy-gateway-system.
# The Service maps port 80 (HTTP) to the envoy container's actual port (10080).
# Use the Service ClusterIP instead of raw pod IP for correct port mapping.
GW_SVC_NAME=$(kctl -n "${GW_NS}" get svc -l gateway.envoyproxy.io/owning-gateway-name=sample-gw -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
GW_SVC_IP=$(kctl -n "${GW_NS}" get svc -l gateway.envoyproxy.io/owning-gateway-name=sample-gw -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
echo "Gateway Service: ${GW_SVC_NAME} IP: ${GW_SVC_IP}"

echo "==> Probing backend via gateway (retry up to 2m for data-plane ready)"
HTTP_CODE="000"
for attempt in $(seq 1 20); do
  RAW_HTTP_CODE=$(kctl -n "${NS}" run "ct-probe-${attempt}" --rm -i --restart=Never --quiet \
    --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      -H "Host: sample.sample.svc.cluster.local" \
      "http://${GW_SVC_IP}:80/" 2>/dev/null) || true
  HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  if [ "${HTTP_CODE}" = "200" ]; then
    echo "HTTP response: ${HTTP_CODE} (attempt ${attempt})"
    break
  fi
  [ "$attempt" -lt 20 ] && sleep 6
done

echo "HTTP response: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTP 200 through Envoy Gateway"
else
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: envoy-gateway HTTPRoute integration verified"
