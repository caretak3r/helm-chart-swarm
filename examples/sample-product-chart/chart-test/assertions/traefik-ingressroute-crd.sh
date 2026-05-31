#!/usr/bin/env bash
# Traefik IngressRoute CRD smoke assertion.
# Verifies: Traefik pod Ready, IngressRoute.traefik.io/v1alpha1 exists,
#           no classic Ingress, HTTP routing works.
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

echo "==> Verifying IngressRoute CRD is used (not classic Ingress)"
IR_COUNT=$(kctl -n "${NS}" get ingressroute.traefik.io -o name 2>/dev/null | wc -l | tr -d ' ')
echo "IngressRoute count: ${IR_COUNT}"

if [ "${IR_COUNT}" -eq 0 ]; then
  echo "FAIL: no IngressRoute.traefik.io resources found in namespace ${NS}" >&2
  exit 1
fi
echo "PASS: IngressRoute.traefik.io/v1alpha1 resources present"

echo "==> Verifying no classic Ingress resources exist"
ING_COUNT=$(kctl -n "${NS}" get ingress -o name 2>/dev/null | wc -l | tr -d ' ')
echo "Classic Ingress count: ${ING_COUNT}"

if [ "${ING_COUNT}" -ne 0 ]; then
  echo "FAIL: found ${ING_COUNT} classic Ingress resource(s) in namespace ${NS} — expected 0 (CRD-only mode)" >&2
  exit 1
fi
echo "PASS: no classic Ingress resources (CRD-only routing)"

echo "==> Getting Traefik pod IP"
TRAEFIK_IP=$(kctl -n "${TRAEFIK_NS}" get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.podIP}')
echo "Traefik pod IP: ${TRAEFIK_IP}"

echo "==> Probing HTTP with Host header (expect 200)"
RAW_HTTP_CODE=$(kctl -n "${NS}" run ct-probe-crd --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: ${HOST}" \
    "http://${TRAEFIK_IP}:8000/" 2>/dev/null || echo "000")
HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1)

echo "HTTP response: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTP 200 through IngressRoute CRD"
else
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: Traefik IngressRoute CRD integration verified"
