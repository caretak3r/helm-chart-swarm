#!/usr/bin/env bash
# Traefik basic IngressRoute smoke assertion.
# Verifies: Traefik pod Ready, IngressRoute routes HTTP with Host header,
#           404 without Host header.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
TRAEFIK_NS="traefik"
HOST="sample.test.local"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for Traefik pod Ready (3m max)"
kctl -n "${TRAEFIK_NS}" wait pod -l app.kubernetes.io/name=traefik --for=condition=Ready --timeout=3m
echo "PASS: Traefik pod Ready"

echo "==> Waiting for product pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: product pods Ready"

echo "==> Getting Traefik pod IP (probe via pod IP)"
TRAEFIK_IP=$(kctl -n "${TRAEFIK_NS}" get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.podIP}')
echo "Traefik pod IP: ${TRAEFIK_IP}"

echo "==> Verifying IngressRoute exists"
kctl -n "${NS}" get ingressroute sample-basic -o name || { echo "FAIL: IngressRoute sample-basic not found" >&2; exit 1; }
echo "PASS: IngressRoute sample-basic exists"

echo "==> Probing HTTP with Host header (expect 200) on container port 8000"
RAW_HTTP=""
RAW_HTTP=$(kctl -n "${NS}" run ct-probe --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: ${HOST}" \
    "http://${TRAEFIK_IP}:8000/" 2>/dev/null) || RAW_HTTP="000"
HTTP_CODE=$(echo "${RAW_HTTP}" | grep -oE '[0-9]{3}' | tail -1 || echo "000")

echo "HTTP response (with Host): ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTP 200 with Host header"
else
  echo "FAIL: expected HTTP 200 with Host header, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "==> Probing HTTP without Host header (expect 404) on container port 8000"
RAW_NO_HOST=""
RAW_NO_HOST=$(kctl -n "${NS}" run ct-probe-no-host --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "http://${TRAEFIK_IP}:8000/" 2>/dev/null) || RAW_NO_HOST="000"
NO_HOST_CODE=$(echo "${RAW_NO_HOST}" | grep -oE '[0-9]{3}' | tail -1 || echo "000")

echo "HTTP response (without Host): ${NO_HOST_CODE}"
if [ "${NO_HOST_CODE}" = "404" ]; then
  echo "PASS: HTTP 404 without Host header (Traefik default)"
else
  echo "FAIL: expected HTTP 404 without Host header, got ${NO_HOST_CODE}" >&2
  exit 1
fi

echo "PASS: Traefik basic IngressRoute integration verified"
