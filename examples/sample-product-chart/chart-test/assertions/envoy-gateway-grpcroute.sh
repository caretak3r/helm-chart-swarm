#!/usr/bin/env bash
# Envoy Gateway GRPCRoute smoke assertion.
# Verifies: GRPCRoute Accepted=True, in-cluster grpcurl reflection probe lists >=1 service.
# gRPC backend is deployed via raw_manifest preinstall (grpc-backend fixture).
# GatewayClass + Gateway + GRPCRoute are applied from a fixture.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
GW_NS="${GW_NAMESPACE:-envoy-gateway-system}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for gRPC backend pod Ready (3m max)"
kctl -n "${NS}" wait pod -l app=grpc-backend --for=condition=Ready --timeout=3m
echo "PASS: gRPC backend pod Ready"

echo "==> Waiting for envoy gateway pod Ready (3m max)"
kctl -n "${GW_NS}" wait pod -l app.kubernetes.io/name=gateway-helm --for=condition=Ready --timeout=3m
echo "PASS: envoy gateway pod Ready"

echo "==> Applying GatewayClass + Gateway + GRPCRoute"
kctl apply -f "${PROJECT_DIR}/chart-test/fixtures/gateway-api/envoy-gateway-grpcroute-gateway.yaml"

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

echo "==> Verifying GRPCRoute sample-grpc-route Accepted=True"
for i in $(seq 1 20); do
  accepted=$(kctl -n "${NS}" get grpcroute sample-grpc-route -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$accepted" = "True" ]; then
    echo "PASS: GRPCRoute sample-grpc-route Accepted=True"
    break
  fi
  if [ "$i" -eq 20 ]; then
    echo "FAIL: GRPCRoute sample-grpc-route not Accepted after 2m" >&2
    kctl -n "${NS}" get grpcroute sample-grpc-route -o yaml >&2
    exit 1
  fi
  sleep 6
done

echo "==> Getting envoy data-plane Service ClusterIP"
GW_SVC_IP=$(kctl -n "${GW_NS}" get svc -l gateway.envoyproxy.io/owning-gateway-name=sample-gw -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
echo "Gateway Service IP: ${GW_SVC_IP}"

# Probe via grpcurl through the gateway (retry up to 2m for data-plane ready)
echo "==> Probing gRPC backend via gateway (grpcurl reflection)"
GRPC_OUT="FAIL"
for attempt in $(seq 1 20); do
  GRPC_OUT=$(kctl -n "${NS}" run "ct-grpc-${attempt}" --rm -i --restart=Never --quiet \
    --image=fullstorydev/grpcurl:v1.9.1 --timeout=60s -- \
    -plaintext -authority "grpc-backend.sample.svc.cluster.local" \
    "${GW_SVC_IP}:80" list 2>/dev/null) || true
  if echo "${GRPC_OUT}" | grep -q 'grpc.'; then
    echo "grpcurl output: ${GRPC_OUT} (attempt ${attempt})"
    break
  fi
  [ "$attempt" -lt 20 ] && sleep 6
done

echo "grpcurl output: ${GRPC_OUT}"
if [ "${GRPC_OUT}" = "FAIL" ]; then
  echo "FAIL: grpcurl reflection probe failed" >&2
  exit 1
fi

# The echo server should list at least one gRPC service
SERVICE_COUNT=$(echo "${GRPC_OUT}" | grep -c '.' || echo "0")
if [ "${SERVICE_COUNT}" -ge 1 ]; then
  echo "PASS: grpcurl reflection listed ${SERVICE_COUNT} service(s)"
else
  echo "FAIL: grpcurl reflection listed 0 services" >&2
  exit 1
fi

echo "PASS: envoy-gateway GRPCRoute integration verified"
