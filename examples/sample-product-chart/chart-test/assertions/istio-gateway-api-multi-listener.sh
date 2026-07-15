#!/usr/bin/env bash
# Istio Gateway API multi-listener smoke assertion.
# Verifies: Gateway with HTTP:80 + HTTPS:443 listeners, both Programmed=True,
#           HTTP curl returns 200, HTTPS curl returns 200.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Generating self-signed TLS cert for Gateway"
TMPDIR=$(mktemp -d)
trap 'rm -rf ${TMPDIR}' EXIT

HOST="sample.sample.svc.cluster.local"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${TMPDIR}/tls.key" \
  -out "${TMPDIR}/tls.crt" \
  -subj "/CN=${HOST}" \
  -addext "subjectAltName=DNS:${HOST}" 2>/dev/null

echo "==> Creating TLS Secret with generated cert (before Gateway)"
kctl -n "${NS}" create secret tls gateway-tls-cert \
  --cert="${TMPDIR}/tls.crt" \
  --key="${TMPDIR}/tls.key" \
  --dry-run=client -o yaml | kctl apply -f -
echo "PASS: TLS Secret gateway-tls-cert created"

echo "==> Applying GatewayClass + Gateway + HTTPRoutes"
# The fixture Secret has REPLACE_AT_RUNTIME (invalid base64) — we already have a valid one.
# kubectl apply creates non-Secret resources; the Secret error is expected.
kctl apply -f "${PROJECT_DIR}/chart-test/fixtures/gateway-api/istio-gateway-api-multi-listener-gateway.yaml" 2>/dev/null || true

# Verify the Gateway and HTTPRoute were created
kctl -n "${NS}" get gateway sample-gw >/dev/null 2>&1 || { echo "FAIL: Gateway sample-gw not created" >&2; exit 1; }
kctl -n "${NS}" get httproute sample-route >/dev/null 2>&1 || { echo "FAIL: HTTPRoute sample-route not created" >&2; exit 1; }
echo "PASS: Gateway resources applied"

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

echo "==> Verifying Gateway has >= 2 listeners"
listener_names=$(kctl -n "${NS}" get gateway sample-gw -o jsonpath='{.status.listeners[*].name}' 2>/dev/null || echo "")
listener_count=$(echo "${listener_names}" | wc -w | tr -d ' ')
if [ "${listener_count}" -ge 2 ]; then
  echo "PASS: Gateway has ${listener_count} listeners: ${listener_names}"
else
  echo "FAIL: Gateway has only ${listener_count} listener(s), expected >= 2" >&2
  exit 1
fi

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

echo "==> Waiting for Gateway listener https Programmed=True (5m max)"
for i in $(seq 1 50); do
  programmed=$(kctl -n "${NS}" get gateway sample-gw -o jsonpath='{.status.listeners[?(@.name=="https")].conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
  if [ "$programmed" = "True" ]; then
    echo "PASS: Gateway listener https Programmed=True"
    break
  fi
  if [ "$i" -eq 50 ]; then
    echo "FAIL: Gateway listener https not Programmed after 5m" >&2
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
    exit 1
  fi
  sleep 6
done

echo "==> Getting Istio data-plane Service ClusterIP"
GW_SVC_IP=$(kctl -n "${NS}" get svc -l gateway.networking.k8s.io/gateway-name=sample-gw -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
echo "Gateway Service IP: ${GW_SVC_IP}"

echo "==> Probing HTTP backend via gateway (retry up to 2m)"
HTTP_CODE="000"
for attempt in $(seq 1 20); do
  RAW_HTTP_CODE=$(kctl -n "${NS}" run "ct-http-${attempt}" --rm -i --restart=Never --quiet \
    --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      -H "Host: sample.sample.svc.cluster.local" \
      "http://${GW_SVC_IP}:80/" 2>/dev/null) || true
  HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  [ -z "$HTTP_CODE" ] && HTTP_CODE="000"
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
echo "PASS: HTTP 200 on port 80"

echo "==> Probing HTTPS backend via gateway (retry up to 2m)"
HTTPS_CODE="000"
for attempt in $(seq 1 20); do
  RAW_HTTPS_CODE=$(kctl -n "${NS}" run "ct-https-${attempt}" --rm -i --restart=Never --quiet \
    --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
    curl -s -o /dev/null -w '%{http_code}' --insecure --max-time 15 \
      --resolve "sample.sample.svc.cluster.local:443:${GW_SVC_IP}" \
      "https://sample.sample.svc.cluster.local:443/" 2>/dev/null) || true
  HTTPS_CODE=$(echo "$RAW_HTTPS_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  [ -z "$HTTPS_CODE" ] && HTTPS_CODE="000"
  if [ "${HTTPS_CODE}" = "200" ]; then
    echo "HTTPS response: ${HTTPS_CODE} (attempt ${attempt})"
    break
  fi
  [ "$attempt" -lt 20 ] && sleep 6
done

echo "HTTPS response: ${HTTPS_CODE}"
if [ "${HTTPS_CODE}" != "200" ]; then
  echo "FAIL: expected HTTPS 200, got ${HTTPS_CODE}" >&2
  exit 1
fi
echo "PASS: HTTPS 200 on port 443"

echo "PASS: istio-gateway-api multi-listener integration verified"
