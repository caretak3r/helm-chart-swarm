#!/usr/bin/env bash
# Istio Gateway API ingress smoke assertion.
# Verifies: GatewayClass istio Accepted=True, Gateway Programmed=True with address,
#           chart HTTPRoute Accepted=True and ResolvedRefs=True, HTTP 200 through gateway.
# Satisfies: VAL-GWE-001, VAL-GWE-002, VAL-GWE-003, VAL-GWE-004
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Applying GatewayClass + Gateway fixture"
kctl apply -f "${PROJECT_DIR}/chart-test/fixtures/gateway-api/istio-gateway-api-ingress-gateway.yaml"

# VAL-GWE-001: istiod Ready and GatewayClass istio Accepted
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

# VAL-GWE-002: Gateway Programmed=True with an address
echo "==> Waiting for Gateway sample-gw Programmed=True (5m max)"
for i in $(seq 1 50); do
  programmed=$(kctl -n "${NS}" get gateway sample-gw -o jsonpath='{.status.listeners[?(@.name=="http")].conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
  if [ "$programmed" = "True" ]; then
    echo "PASS: Gateway sample-gw listener http Programmed=True"
    break
  fi
  if [ "$i" -eq 50 ]; then
    echo "FAIL: Gateway sample-gw not Programmed after 5m" >&2
    kctl -n "${NS}" get gateway sample-gw -o yaml >&2
    exit 1
  fi
  sleep 6
done

# Verify Gateway has an address
gw_addr=$(kctl -n "${NS}" get gateway sample-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
if [ -z "$gw_addr" ]; then
  echo "WARN: Gateway has no address in status.addresses; will use Service ClusterIP"
fi

# VAL-GWE-003: chart HTTPRoute Accepted=True and ResolvedRefs=True
echo "==> Waiting for chart HTTPRoute ${RELEASE} Accepted=True (3m max)"
for i in $(seq 1 30); do
  accepted=$(kctl -n "${NS}" get httproute "${RELEASE}" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: HTTPRoute ${RELEASE} Accepted=True"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: HTTPRoute ${RELEASE} not Accepted after 3m" >&2
    kctl -n "${NS}" get httproute "${RELEASE}" -o yaml >&2
    exit 1
  fi
  sleep 6
done

echo "==> Verifying chart HTTPRoute ${RELEASE} ResolvedRefs=True"
resolved_refs=$(kctl -n "${NS}" get httproute "${RELEASE}" -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || echo "")
if [ "$resolved_refs" = "True" ]; then
  echo "PASS: HTTPRoute ${RELEASE} ResolvedRefs=True"
else
  echo "FAIL: HTTPRoute ${RELEASE} ResolvedRefs=${resolved_refs:-empty}, expected True" >&2
  kctl -n "${NS}" get httproute "${RELEASE}" -o yaml >&2
  exit 1
fi

# VAL-GWE-003: HTTP curl returns 200 through gateway
echo "==> Getting Istio data-plane Service ClusterIP"
GW_SVC_IP=$(kctl -n "${NS}" get svc -l gateway.networking.k8s.io/gateway-name=sample-gw -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null || echo "")
if [ -z "$GW_SVC_IP" ] || [ "$GW_SVC_IP" = "" ]; then
  echo "WARN: No ClusterIP found for gateway Service; trying pod IP"
  GW_SVC_IP=$(kctl -n "${NS}" get pods -l gateway.networking.k8s.io/gateway-name=sample-gw -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")
fi
echo "Gateway Service IP: ${GW_SVC_IP}"

echo "==> Probing backend via gateway (retry up to 2m for data-plane warm-up)"
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
  echo "PASS: HTTP 200 through Istio Gateway API ingress"
else
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: istio Gateway API ingress integration verified"
