#!/usr/bin/env bash
# Traefik TLS passthrough smoke assertion.
# Verifies: Traefik pod Ready, IngressRouteTCP with tls.passthrough=true,
#           HTTPS curl returns 200, served cert matches backend cert (not Traefik default).
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
TRAEFIK_NS="traefik"
HOST="sample.test.local"
TLS_SECRET="manual-tls-basic"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for Traefik pod Ready (3m max)"
kctl -n "${TRAEFIK_NS}" wait pod -l app.kubernetes.io/name=traefik --for=condition=Ready --timeout=3m
echo "PASS: Traefik pod Ready"

echo "==> Waiting for product pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: product pods Ready"

echo "==> Getting Traefik pod IP"
TRAEFIK_IP=$(kctl -n "${TRAEFIK_NS}" get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.podIP}')
echo "Traefik pod IP: ${TRAEFIK_IP}"

echo "==> Verifying IngressRouteTCP exists with tls.passthrough=true"
IRTCP=$(kctl -n "${NS}" get ingressroutetcp sample-tls-passthrough -o json 2>/dev/null)
if [ -z "${IRTCP}" ]; then
  echo "FAIL: IngressRouteTCP sample-tls-passthrough not found" >&2
  exit 1
fi
PASSTHROUGH=$(echo "${IRTCP}" | jq -r '.spec.tls.passthrough')
if [ "${PASSTHROUGH}" != "true" ]; then
  echo "FAIL: IngressRouteTCP tls.passthrough is '${PASSTHROUGH}', expected 'true'" >&2
  exit 1
fi
echo "PASS: IngressRouteTCP tls.passthrough=true"

echo "==> Extracting backend certificate subject"
kctl -n "${NS}" get secret "${TLS_SECRET}" -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/backend-cert.crt
BACKEND_SUBJECT=$(openssl x509 -in /tmp/backend-cert.crt -noout -subject 2>/dev/null || echo "unknown")
echo "Backend cert subject: ${BACKEND_SUBJECT}"

echo "==> Probing HTTPS through Traefik (expect 200, backend cert)"
HTTP_CODE=$(kctl -n "${NS}" run ct-probe-tls --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  sh -c "curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
    --resolve '${HOST}:8443:${TRAEFIK_IP}' \
    'https://${HOST}:8443/'" 2>/dev/null || echo "000")

echo "HTTPS response: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTPS 200 through Traefik"
else
  echo "FAIL: expected HTTPS 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "==> Verifying served cert matches backend cert (not Traefik default)"
SERVED_SUBJECT=$(kctl -n "${NS}" run ct-probe-cert --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  sh -c "curl -skv --resolve '${HOST}:8443:${TRAEFIK_IP}' 'https://${HOST}:8443/' -o /dev/null 2>&1 | grep 'subject:' | head -1" 2>/dev/null || echo "subject: unknown")

echo "Served cert subject: ${SERVED_SUBJECT}"

# Both subjects should contain the same CN
BACKEND_CN=$(echo "${BACKEND_SUBJECT}" | grep -o 'CN *= *[^ ,]\+' | head -1 | sed 's/CN *= *//')
SERVED_CN=$(echo "${SERVED_SUBJECT}" | grep -o 'CN *= *[^ ,]\+' | head -1 | sed 's/CN *= *//')

if [ "${BACKEND_CN}" = "${SERVED_CN}" ] && [ -n "${BACKEND_CN}" ]; then
  echo "PASS: served cert subject matches backend cert (CN=${BACKEND_CN})"
else
  echo "FAIL: served cert CN='${SERVED_CN}' does not match backend CN='${BACKEND_CN}'" >&2
  exit 1
fi

echo "PASS: Traefik TLS passthrough integration verified"
