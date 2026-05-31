#!/usr/bin/env bash
# Istio Gateway API BackendTLSPolicy smoke assertion.
# Verifies: Gateway routing (HTTP 200), then applies BackendTLSPolicy,
#           verifies Policy Accepted=True (TLS enforcement is expected).
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Applying GatewayClass + Gateway + HTTPRoute"
kctl apply -f "${PROJECT_DIR}/chart-test/fixtures/gateway-api/istio-gateway-api-backend-tls-gateway.yaml"

echo "==> Waiting for GatewayClass istio Accepted=True (3m max)"
for i in $(seq 1 30); do
  accepted=$(kctl get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: GatewayClass istio Accepted=True"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: GatewayClass istio not Accepted after 3m" >&2
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

echo "==> Getting Istio data-plane Service ClusterIP"
GW_SVC_IP=$(kctl -n "${NS}" get svc -l gateway.networking.k8s.io/gateway-name=sample-gw -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
echo "Gateway Service IP: ${GW_SVC_IP}"

echo "==> Probing backend via gateway (before BackendTLSPolicy, retry up to 2m)"
HTTP_CODE="000"
for attempt in $(seq 1 20); do
  HTTP_CODE=$(kctl -n "${NS}" run "ct-probe-${attempt}" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.6.0 --timeout=30s -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      -H "Host: sample.${NS}.svc.cluster.local" \
      "http://${GW_SVC_IP}:80/" 2>/dev/null) || true
  if [ "${HTTP_CODE}" = "200" ]; then
    echo "HTTP response: ${HTTP_CODE} (attempt ${attempt})"
    break
  fi
  [ "$attempt" -lt 20 ] && sleep 6
done

echo "HTTP response: ${HTTP_CODE}"
if [ "${HTTP_CODE}" != "200" ]; then
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi
echo "PASS: HTTP 200 through Istio Gateway API"

echo "==> Applying BackendTLSPolicy"
kctl apply -f "${PROJECT_DIR}/chart-test/fixtures/gateway-api/istio-gateway-api-backend-tls-policy.yaml"

echo "==> Waiting for BackendTLSPolicy Accepted=True (2m max)"
for i in $(seq 1 20); do
  accepted=$(kctl -n "${NS}" get backendtlspolicy sample-backend-tls -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: BackendTLSPolicy sample-backend-tls Accepted=True"
    break
  fi
  if [ "$i" -eq 20 ]; then
    echo "FAIL: BackendTLSPolicy not Accepted after 2m" >&2
    echo "BackendTLSPolicy status:" >&2
    kctl -n "${NS}" get backendtlspolicy sample-backend-tls -o yaml >&2
    exit 1
  fi
  sleep 6
done

echo "PASS: istio-gateway-api BackendTLSPolicy integration verified"
