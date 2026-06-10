#!/usr/bin/env bash
# DEPTH: L3
# Assert: gateway-routes-traffic — L3 behavioral assert that proves Gateway
# API route actually serves traffic through the data plane.
#
# This assert goes beyond mere Gateway/HTTPRoute object presence: it verifies
# the GatewayClass is Accepted, the Gateway listener is Programmed, the
# HTTPRoute is Accepted, and actual traffic through the gateway data-plane
# returns the expected HTTP status.
#
# PASS requires ALL of:
#   1. GatewayClass is Accepted=True.
#   2. Gateway listener is Programmed=True.
#   3. HTTPRoute is Accepted=True (or equivalent).
#   4. Probe through the gateway data-plane Service returns the expected HTTP status.
#
# FAIL paths:
#   - Gateway/HTTPRoute present but GatewayClass not Accepted.
#   - Gateway/HTTPRoute present but listener not Programmed.
#   - Gateway/HTTPRoute present but HTTPRoute not Accepted.
#   - Gateway/HTTPRoute present but traffic returns 503 or connection failure.
#
# SKIP (non-failing): when the required platform capability is absent
#   (no Gateway API CRDs in the cluster).
#
# Env-var parameterized (no hardcoded consumer names):
#   RELEASE, NAMESPACE, PROJECT_DIR, KUBE_CONTEXT, KUBECONFIG
#
# Scenario fields:
#   namespace            — required, product namespace
#   gateway_host         — optional, Host header value (default "${RELEASE}.${NAMESPACE}.svc")
#   gateway_class        — optional, GatewayClass name (default "envoy")
#   gateway_name         — optional, Gateway name (default "${RELEASE}-gw")
#   route_name           — optional, HTTPRoute name (default "${RELEASE}-route")
#   controller_namespace — optional, namespace of the gateway controller (default "envoy-gateway-system")
#   expected_status      — optional, expected HTTP status (default 200)
#   curl_image           — optional, curl image for probing
#   timeout              — optional, per-probe timeout (default "120s")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/assert-helpers.sh
source "$SCRIPT_DIR/lib/assert-helpers.sh"

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
RELEASE="${RELEASE:-$(yq '.product.release' "$SCENARIO")}"
GW_HOST=$(yq ".asserts[$IDX].gateway_host // \"${RELEASE}.${NS}.svc\"" "$SCENARIO")
GW_CLASS=$(yq ".asserts[$IDX].gateway_class // \"envoy\"" "$SCENARIO")
GW_NAME=$(yq ".asserts[$IDX].gateway_name // \"${RELEASE}-gw\"" "$SCENARIO")
ROUTE_NAME=$(yq ".asserts[$IDX].route_name // \"${RELEASE}-route\"" "$SCENARIO")
CTRL_NS=$(yq ".asserts[$IDX].controller_namespace // \"envoy-gateway-system\"" "$SCENARIO")
EXPECTED_STATUS=$(yq ".asserts[$IDX].expected_status // 200" "$SCENARIO")
CURL_IMAGE=$(yq ".asserts[$IDX].curl_image // \"quay.io/curl/curl:8.20.0\"" "$SCENARIO")
PTIMEOUT=$(yq ".asserts[$IDX].timeout // \"120s\"" "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

kctl() { kubectl "${kubectl_args[@]}" "$@"; }

# ── SKIP check: platform capability absent ───────────────────────────────
# Check if the Gateway API CRDs exist in the cluster.
if ! kctl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  echo "SKIP: Gateway API platform capability not detected (no gateways.gateway.networking.k8s.io CRD)"
  echo "ASSERTION_RESULT: SKIP"
  echo 'ASSERTION_DETAIL: {"reason":"platform_capability_absent","detail":"No gateways.gateway.networking.k8s.io CRD found"}'
  exit 0
fi

# ── Phase 1: Verify GatewayClass Accepted ────────────────────────────────
echo "==> Checking GatewayClass '${GW_CLASS}' Accepted"
GWCLASS_ACCEPTED=""
GWCLASS_ACCEPTED=$(kctl get gatewayclass "${GW_CLASS}" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")

if [ "${GWCLASS_ACCEPTED}" != "True" ]; then
  echo "FAIL: GatewayClass '${GW_CLASS}' is not Accepted (status: '${GWCLASS_ACCEPTED}')" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"reason\":\"gatewayclass_not_accepted\",\"detail\":\"GatewayClass '${GW_CLASS}' Accepted=${GWCLASS_ACCEPTED}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
fi
echo "PASS: GatewayClass '${GW_CLASS}' Accepted=True"

# ── Phase 2: Verify Gateway listener Programmed ──────────────────────────
echo ""
echo "==> Checking Gateway '${GW_NAME}' listener Programmed"
GW_PROGRAMMED=""
GW_PROGRAMMED=$(kctl -n "${NS}" get gateway "${GW_NAME}" -o jsonpath='{.status.listeners[0].conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "False")

# Also try release-scoped gateway lookup
if [ -z "${GW_PROGRAMMED}" ] || [ "${GW_PROGRAMMED}" = "False" ]; then
  GW_LIST=""
  GW_LIST=$(kctl -n "${NS}" get gateway -l "app.kubernetes.io/instance=${RELEASE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "${GW_LIST}" ]; then
    GW_NAME=$(echo "$GW_LIST" | awk '{print $1}')
    echo "Found release-scoped Gateway: ${GW_NAME}"
    GW_PROGRAMMED=$(kctl -n "${NS}" get gateway "${GW_NAME}" -o jsonpath='{.status.listeners[0].conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "False")
  fi
fi

if [ "${GW_PROGRAMMED}" != "True" ]; then
  echo "FAIL: Gateway '${GW_NAME}' listener is not Programmed (status: '${GW_PROGRAMMED}')" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"reason\":\"gateway_not_programmed\",\"detail\":\"Gateway '${GW_NAME}' Programmed=${GW_PROGRAMMED}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
fi
echo "PASS: Gateway '${GW_NAME}' listener Programmed=True"

# ── Phase 3: Verify HTTPRoute Accepted ───────────────────────────────────
echo ""
echo "==> Checking HTTPRoute '${ROUTE_NAME}' Accepted"
ROUTE_ACCEPTED=""
ROUTE_ACCEPTED=$(kctl -n "${NS}" get httproute "${ROUTE_NAME}" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")

# Fallback: release-scoped HTTPRoute lookup
if [ -z "${ROUTE_ACCEPTED}" ]; then
  ROUTE_LIST=""
  ROUTE_LIST=$(kctl -n "${NS}" get httproute -l "app.kubernetes.io/instance=${RELEASE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "${ROUTE_LIST}" ]; then
    ROUTE_NAME=$(echo "$ROUTE_LIST" | awk '{print $1}')
    echo "Found release-scoped HTTPRoute: ${ROUTE_NAME}"
    ROUTE_ACCEPTED=$(kctl -n "${NS}" get httproute "${ROUTE_NAME}" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  fi
fi

if [ "${ROUTE_ACCEPTED}" != "True" ]; then
  echo "FAIL: HTTPRoute '${ROUTE_NAME}' is not Accepted (status: '${ROUTE_ACCEPTED}')" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"reason\":\"httproute_not_accepted\",\"detail\":\"HTTPRoute '${ROUTE_NAME}' Accepted=${ROUTE_ACCEPTED}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
fi
echo "PASS: HTTPRoute '${ROUTE_NAME}' Accepted=True"

# ── Phase 4: Find gateway data-plane Service ─────────────────────────────
echo ""
echo "==> Resolving gateway data-plane Service (namespace ${CTRL_NS})"

GW_SVC_NAME=""
GW_SVC_IP=""

# Common label patterns for gateway data-plane services:
# Envoy Gateway: gateway.envoyproxy.io/owning-gateway-name=<gw>
# Istio: istio.io/gateway-name=<gw> or app=istio-ingressgateway
# Generic: gateway.networking.k8s.io/gateway-name=<gw>

# Try specific label first
GW_SVC_NAME=$(kctl -n "${CTRL_NS}" get svc -l "gateway.envoyproxy.io/owning-gateway-name=${GW_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "${GW_SVC_NAME}" ]; then
  # Try istio gateway label
  GW_SVC_NAME=$(kctl -n "${CTRL_NS}" get svc -l "istio.io/gateway-name=${GW_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [ -z "${GW_SVC_NAME}" ]; then
  # Try generic label
  GW_SVC_NAME=$(kctl -n "${CTRL_NS}" get svc -l "gateway.networking.k8s.io/gateway-name=${GW_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [ -z "${GW_SVC_NAME}" ]; then
  echo "FAIL: could not find gateway data-plane Service for Gateway '${GW_NAME}' in namespace ${CTRL_NS}" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

GW_SVC_IP=$(kctl -n "${CTRL_NS}" get svc "${GW_SVC_NAME}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [ -z "${GW_SVC_IP}" ]; then
  echo "FAIL: could not resolve ClusterIP for gateway Service '${GW_SVC_NAME}'" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

echo "Gateway Service: ${GW_SVC_NAME} (ClusterIP: ${GW_SVC_IP})"

# ── Phase 5: Probe through gateway data-plane ────────────────────────────
echo ""
echo "==> Probing through gateway with Host: ${GW_HOST}"

PROBE_POD="ct-grt-$$"
curl_raw=""

curl_raw=$(kctl -n "${NS}" run "${PROBE_POD}" --rm -i --restart=Never --quiet \
  --image="${CURL_IMAGE}" --pod-running-timeout="${PTIMEOUT}" -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: ${GW_HOST}" \
    "http://${GW_SVC_IP}:80/" 2>/dev/null || echo "000")

# Use anchored HTTP status-code parser
HTTP_CODE=""
if ! HTTP_CODE=$(parse_http_code "$curl_raw" 2>/dev/null); then
  echo "FAIL: gateway probe returned '${curl_raw}' — could not parse HTTP status code" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

echo "Gateway HTTP response: ${HTTP_CODE}"

# ── Evaluate ─────────────────────────────────────────────────────────────
if [ "${HTTP_CODE}" = "${EXPECTED_STATUS}" ]; then
  echo "PASS: Gateway route served traffic successfully (HTTP ${HTTP_CODE})"
  echo "ASSERTION_RESULT: PASS"
  echo "{\"gateway\":\"${GW_NAME}\",\"route\":\"${ROUTE_NAME}\",\"host\":\"${GW_HOST}\",\"http_code\":\"${HTTP_CODE}\",\"namespace\":\"${NS}\",\"svc\":\"${GW_SVC_NAME}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 0
elif [ "${HTTP_CODE}" = "503" ] || [ "${HTTP_CODE}" = "000" ] || [ "${HTTP_CODE}" = "028" ]; then
  echo "FAIL: Gateway/HTTPRoute present but traffic not served (HTTP ${HTTP_CODE})" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"reason\":\"traffic_not_served\",\"detail\":\"Gateway/HTTPRoute present but probe returned HTTP ${HTTP_CODE}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
else
  echo "FAIL: expected HTTP ${EXPECTED_STATUS}, got ${HTTP_CODE}" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"reason\":\"http_status_mismatch\",\"detail\":\"Expected ${EXPECTED_STATUS}, got ${HTTP_CODE}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
fi
