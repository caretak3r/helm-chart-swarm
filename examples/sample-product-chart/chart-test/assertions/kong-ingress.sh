#!/usr/bin/env bash
# Kong Ingress (className=kong) smoke assertion.
# Verifies: Kong controller+proxy pods Running, IngressClass kong registered,
#           chart Ingress has spec.ingressClassName=kong,
#           HTTP 200 with matching Host through Kong proxy,
#           KongPlugin gap-probe: chart exposes no konghq.com/plugins annotation.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
KONG_NS="kong"
HOST="sample.test.local"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for Kong controller pod Ready (5m max)"
kctl -n "${KONG_NS}" wait pod -l app.kubernetes.io/instance=kong,app.kubernetes.io/name=controller --for=condition=Ready --timeout=5m
echo "PASS: Kong controller pod Ready"

echo "==> Waiting for Kong gateway (proxy) pod Ready (5m max)"
kctl -n "${KONG_NS}" wait pod -l app.kubernetes.io/instance=kong,app.kubernetes.io/name=gateway --for=condition=Ready --timeout=5m
echo "PASS: Kong gateway (proxy) pod Ready"

echo "==> Verifying IngressClass kong is registered"
INGRESS_CLASS=$(kctl get ingressclass kong -o name 2>/dev/null || echo "")
if [ "${INGRESS_CLASS}" = "ingressclass.networking.k8s.io/kong" ]; then
  echo "PASS: IngressClass kong registered"
else
  echo "FAIL: IngressClass kong not found (got: ${INGRESS_CLASS})" >&2
  exit 1
fi

echo "==> Waiting for product pod Ready (5m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=5m
echo "PASS: product pods Ready"

echo "==> Verifying Ingress has spec.ingressClassName=kong"
CLASS_NAME=$(kctl -n "${NS}" get ingress "${RELEASE}" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null || echo "")
if [ "${CLASS_NAME}" = "kong" ]; then
  echo "PASS: Ingress ingressClassName=kong"
else
  echo "FAIL: Expected ingressClassName=kong, got '${CLASS_NAME}'" >&2
  exit 1
fi

echo "==> Verifying Ingress backend points at the product Service"
BACKEND_SVC=$(kctl -n "${NS}" get ingress "${RELEASE}" -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}' 2>/dev/null || echo "")
if [ "${BACKEND_SVC}" = "${RELEASE}" ]; then
  echo "PASS: Ingress backend service=${RELEASE}"
else
  echo "FAIL: Expected backend service=${RELEASE}, got '${BACKEND_SVC}'" >&2
  exit 1
fi

echo "==> Getting Kong proxy (gateway) pod IP"
# Kong proxy runs in the gateway pod (labelled app.kubernetes.io/name=gateway) in the kong namespace.
# The proxy container listens on port 8000 for HTTP.
KONG_IP=$(kctl -n "${KONG_NS}" get pod -l app.kubernetes.io/instance=kong,app.kubernetes.io/name=gateway -o jsonpath='{.items[0].status.podIP}')
echo "Kong proxy pod IP: ${KONG_IP}"

echo "==> Probing HTTP with matching Host header (expect 200, retry up to 2m for Kong route sync)"
HTTP_CODE="000"
_PROBE_POD="ct-kong-host-$$"
kctl -n "${NS}" delete pod "${_PROBE_POD}" --now --ignore-not-found >/dev/null 2>&1 || true

for _attempt in $(seq 1 24); do
  # Run probe pod without -i to avoid stdin-attachment races that lose stdout.
  kctl -n "${NS}" run "${_PROBE_POD}" --restart=Never \
    --image="quay.io/curl/curl:8.20.0" --pod-running-timeout=90s -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: ${HOST}" \
    "http://${KONG_IP}:8000/" >/dev/null 2>&1 || true

  # Poll until pod reaches terminal phase (up to 60s).
  _wait_s=0
  while [ "$_wait_s" -lt 60 ]; do
    _phase=$(kctl -n "${NS}" get pod "${_PROBE_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    [ "$_phase" = "Succeeded" ] || [ "$_phase" = "Failed" ] && break
    sleep 3; _wait_s=$((_wait_s + 3))
  done

  _RAW=$(kctl -n "${NS}" logs "${_PROBE_POD}" 2>/dev/null || echo "")
  [ -z "$_RAW" ] && _RAW="000"
  kctl -n "${NS}" delete pod "${_PROBE_POD}" --now --ignore-not-found >/dev/null 2>&1 || true

  HTTP_CODE=$(printf '%s' "$_RAW" | grep -oE '[0-9]{3}' | tail -1 || true)
  [ -z "$HTTP_CODE" ] && HTTP_CODE="000"

  [ "$HTTP_CODE" = "200" ] && break
  echo "attempt ${_attempt}/24: HTTP ${HTTP_CODE} — waiting 5s for Kong route sync"
  sleep 5
done

echo "HTTP response (with Host): ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTP 200 with matching Host header through Kong proxy"
else
  echo "FAIL: expected HTTP 200 with matching Host header, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "==> Probing HTTP with non-matching Host header (expect 404) on Kong proxy port 8000"
_NO_HOST_POD="ct-kong-no-host-$$"
kctl -n "${NS}" delete pod "${_NO_HOST_POD}" --now --ignore-not-found >/dev/null 2>&1 || true

# Run probe pod without -i to avoid stdin-attachment races.
kctl -n "${NS}" run "${_NO_HOST_POD}" --restart=Never \
  --image="quay.io/curl/curl:8.20.0" --pod-running-timeout=90s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -H "Host: wrong.test.local" \
  "http://${KONG_IP}:8000/" >/dev/null 2>&1 || true

# Poll until pod reaches terminal phase (up to 60s).
_no_host_wait=0
while [ "$_no_host_wait" -lt 60 ]; do
  _nh_phase=$(kctl -n "${NS}" get pod "${_NO_HOST_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  [ "$_nh_phase" = "Succeeded" ] || [ "$_nh_phase" = "Failed" ] && break
  sleep 3; _no_host_wait=$((_no_host_wait + 3))
done

_NO_HOST_RAW=$(kctl -n "${NS}" logs "${_NO_HOST_POD}" 2>/dev/null || echo "")
[ -z "$_NO_HOST_RAW" ] && _NO_HOST_RAW="000"
kctl -n "${NS}" delete pod "${_NO_HOST_POD}" --now --ignore-not-found >/dev/null 2>&1 || true

NO_HOST_CODE=$(printf '%s' "$_NO_HOST_RAW" | grep -oE '[0-9]{3}' | tail -1 || true)
[ -z "$NO_HOST_CODE" ] && NO_HOST_CODE="000"

echo "HTTP response (non-matching Host): ${NO_HOST_CODE}"
if [ "${NO_HOST_CODE}" = "404" ]; then
  echo "PASS: HTTP 404 with non-matching Host header"
else
  echo "FAIL: expected HTTP 404 with non-matching Host header, got ${NO_HOST_CODE}" >&2
  exit 1
fi

echo "==> KongPlugin gap-probe: checking if chart Ingress has konghq.com/plugins annotation"
PLUGINS_ANNOTATION=$(kctl -n "${NS}" get ingress "${RELEASE}" -o jsonpath='{.metadata.annotations.konghq\.com/plugins}' 2>/dev/null || echo "")
if [ -z "${PLUGINS_ANNOTATION}" ]; then
  echo "GAP: chart Ingress does NOT have konghq.com/plugins annotation (honest gap, red cell)"
else
  echo "INFO: chart Ingress has konghq.com/plugins annotation: ${PLUGINS_ANNOTATION}"
fi

echo "==> KongPlugin gap-probe: checking if any KongPlugin CRD instances exist"
KONG_PLUGINS=$(kctl get kongplugin -n "${NS}" -o name 2>/dev/null || echo "")
if [ -z "${KONG_PLUGINS}" ]; then
  echo "GAP: No KongPlugin CRD instances found in namespace ${NS} (chart exposes no KongPlugin knob, honest gap, red cell)"
else
  echo "INFO: KongPlugin instances found: ${KONG_PLUGINS}"
fi

echo "PASS: Kong Ingress (className=kong) integration verified end-to-end"
echo "NOTE: KongPlugin gap-probe documented honestly — chart does not expose konghq.com/plugins or KongPlugin CRD"
