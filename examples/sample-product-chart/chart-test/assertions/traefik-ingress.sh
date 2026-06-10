#!/usr/bin/env bash
# Traefik Ingress (className=traefik) smoke assertion.
# Verifies: Traefik pod Ready, IngressClass traefik registered,
#           chart Ingress has spec.ingressClassName=traefik,
#           HTTP 200 with matching Host, 404 with non-matching Host.
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

echo "==> Verifying IngressClass traefik is registered"
INGRESS_CLASS=$(kctl get ingressclass traefik -o name 2>/dev/null || echo "")
if [ "${INGRESS_CLASS}" = "ingressclass.networking.k8s.io/traefik" ]; then
  echo "PASS: IngressClass traefik registered"
else
  echo "FAIL: IngressClass traefik not found (got: ${INGRESS_CLASS})" >&2
  exit 1
fi

echo "==> Waiting for product pod Ready (5m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=5m
echo "PASS: product pods Ready"

echo "==> Verifying Ingress has spec.ingressClassName=traefik"
CLASS_NAME=$(kctl -n "${NS}" get ingress "${RELEASE}" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null || echo "")
if [ "${CLASS_NAME}" = "traefik" ]; then
  echo "PASS: Ingress ingressClassName=traefik"
else
  echo "FAIL: Expected ingressClassName=traefik, got '${CLASS_NAME}'" >&2
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

echo "==> Getting Traefik pod IP (probe via pod IP)"
TRAEFIK_IP=$(kctl -n "${TRAEFIK_NS}" get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.podIP}')
echo "Traefik pod IP: ${TRAEFIK_IP}"

echo "==> Probing HTTP with matching Host header (expect 200) on container port 8000"
RAW_HTTP=$(kctl -n "${NS}" run ct-probe-host --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: ${HOST}" \
    "http://${TRAEFIK_IP}:8000/" 2>/dev/null || echo "000")
HTTP_CODE=$(echo "${RAW_HTTP}" | grep -oE '[0-9]{3}' | tail -1)

echo "HTTP response (with Host): ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTP 200 with matching Host header"
else
  echo "FAIL: expected HTTP 200 with matching Host header, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "==> Probing HTTP with non-matching Host header (expect 404) on container port 8000"
RAW_NO_HOST=$(kctl -n "${NS}" run ct-probe-no-host --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.20.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: wrong.test.local" \
    "http://${TRAEFIK_IP}:8000/" 2>/dev/null || echo "000")
NO_HOST_CODE=$(echo "${RAW_NO_HOST}" | grep -oE '[0-9]{3}' | tail -1)

echo "HTTP response (non-matching Host): ${NO_HOST_CODE}"
if [ "${NO_HOST_CODE}" = "404" ]; then
  echo "PASS: HTTP 404 with non-matching Host header"
else
  echo "FAIL: expected HTTP 404 with non-matching Host header, got ${NO_HOST_CODE}" >&2
  exit 1
fi

echo "PASS: Traefik Ingress (className=traefik) integration verified end-to-end"
