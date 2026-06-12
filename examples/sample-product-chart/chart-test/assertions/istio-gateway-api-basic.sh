#!/usr/bin/env bash
# Istio Gateway API basic smoke assertion.
# Verifies: GatewayClass istio Accepted=True, Gateway Programmed=True,
#           auto-provisioned Deployment, HTTPRoute Accepted=True, HTTP 200.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Applying GatewayClass + Gateway + HTTPRoute"
kctl apply -f "${PROJECT_DIR}/chart-test/fixtures/gateway-api/istio-gateway-api-basic-gateway.yaml"

echo "==> Waiting for GatewayClass istio Accepted=True (3m max)"
for i in $(seq 1 30); do
  accepted=$(kctl get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: GatewayClass istio Accepted=True"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: GatewayClass istio not Accepted after 3m" >&2
    kctl get gatewayclass istio -o yaml >&2
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

echo "==> Verifying auto-provisioned Deployment in sample namespace"
for i in $(seq 1 10); do
  dep_count=$(kctl -n "${NS}" get deploy -l gateway.networking.k8s.io/gateway-name=sample-gw -o name 2>/dev/null | wc -l | tr -d ' ')
  if [ "$dep_count" -ge 1 ]; then
    echo "PASS: auto-provisioned Deployment found (${dep_count})"
    break
  fi
  if [ "$i" -eq 10 ]; then
    echo "FAIL: no auto-provisioned Deployment with label gateway.networking.k8s.io/gateway-name=sample-gw after 1m" >&2
    echo "Deployments in ${NS}:" >&2
    kctl -n "${NS}" get deploy -o wide >&2
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

echo "==> Getting Istio data-plane Service ClusterIP"
GW_SVC_NAME=$(kctl -n "${NS}" get svc -l gateway.networking.k8s.io/gateway-name=sample-gw -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
GW_SVC_IP=$(kctl -n "${NS}" get svc -l gateway.networking.k8s.io/gateway-name=sample-gw -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
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
  echo "PASS: HTTP 200 through Istio Gateway API"
else
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: istio-gateway-api basic integration verified"
