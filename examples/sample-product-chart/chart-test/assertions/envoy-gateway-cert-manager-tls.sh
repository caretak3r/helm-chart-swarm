#!/usr/bin/env bash
# Envoy Gateway + cert-manager TLS compose smoke assertion.
# Verifies: cert-manager issues a Certificate, Gateway listener tls.certificateRefs
#           points to the cert-manager Secret, listener Programmed=True,
#           HTTPS curl returns 200 with expected cert.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
GW_NS="${GW_NAMESPACE:-envoy-gateway-system}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"
CERT_NAME="gateway-tls"
DOMAIN="sample.sample.svc.cluster.local"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Applying cert-manager Certificate for Gateway TLS"
kctl apply -f "${PROJECT_DIR}/chart-test/fixtures/gateway-api/envoy-gateway-certificate.yaml"

echo "==> Waiting for cert-manager Certificate '${CERT_NAME}' Ready (3m max)"
kctl -n "${NS}" wait certificate "${CERT_NAME}" --for=condition=Ready --timeout=3m
echo "PASS: Certificate Ready=True"

echo "==> Verifying TLS Secret '${CERT_NAME}' keys"
secret_keys=$(kctl -n "${NS}" get secret "${CERT_NAME}" -o json | jq -r '.data | keys | sort[]')
echo "${secret_keys}" | grep -qx 'ca.crt'  || { echo "FAIL: missing ca.crt" >&2; exit 1; }
echo "${secret_keys}" | grep -qx 'tls.crt' || { echo "FAIL: missing tls.crt" >&2; exit 1; }
echo "${secret_keys}" | grep -qx 'tls.key' || { echo "FAIL: missing tls.key" >&2; exit 1; }
echo "OK: tls.crt, tls.key, ca.crt all present in TLS Secret"

echo "==> Applying GatewayClass + Gateway (HTTPS listener) + HTTPRoute"
kctl apply -f "${PROJECT_DIR}/chart-test/fixtures/gateway-api/envoy-gateway-cert-manager-gateway.yaml"

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

echo "==> Waiting for Gateway listener https Programmed=True (5m max)"
# The HTTPS listener must have the TLS cert resolved before Programming
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

echo "==> Verifying gateway listener https is Programmed"
listener_status=$(kctl -n "${NS}" get gateway sample-gw -o jsonpath='{.status.listeners[?(@.name=="https")].conditions[?(@.type=="Programmed")].status}')
if [ "$listener_status" = "True" ]; then
  echo "PASS: Listener https Programmed=True"
else
  echo "FAIL: Listener https not Programmed (status: ${listener_status})" >&2
  exit 1
fi

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

echo "==> Getting envoy data-plane Service ClusterIP"
GW_SVC_IP=$(kctl -n "${GW_NS}" get svc -l gateway.envoyproxy.io/owning-gateway-name=sample-gw -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
echo "Gateway Service IP: ${GW_SVC_IP}"

# Extract ca.crt from the Secret for TLS verification
CA_CRT_B64=$(kctl -n "${NS}" get secret "${CERT_NAME}" -o jsonpath='{.data.ca\.crt}')

echo "==> Probing HTTPS backend via gateway (retry up to 2m)"
HTTP_CODE="000"
for attempt in $(seq 1 20); do
  HTTP_CODE=$(kctl -n "${NS}" run "ct-https-${attempt}" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.6.0 --timeout=30s -- \
    sh -c "echo '${CA_CRT_B64}' | base64 -d > /tmp/ca.crt && \
      curl -s -o /dev/null -w '%{http_code}' --cacert /tmp/ca.crt --max-time 15 \
        --resolve '${DOMAIN}:443:${GW_SVC_IP}' \
        'https://${DOMAIN}:443/'" 2>/dev/null) || true
  if [ "${HTTP_CODE}" = "200" ]; then
    echo "HTTPS response: ${HTTP_CODE} (attempt ${attempt})"
    break
  fi
  [ "$attempt" -lt 20 ] && sleep 6
done

echo "HTTPS response: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTPS 200 through Envoy Gateway with cert-manager TLS"
else
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "==> Verifying peer certificate matches cert-manager issued cert"
SAN_OUT=$(kctl -n "${NS}" get secret "${CERT_NAME}" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName 2>/dev/null || echo "")
echo "SAN: ${SAN_OUT}"
echo "${SAN_OUT}" | grep -q "DNS:${DOMAIN}" || { echo "FAIL: SAN does not contain ${DOMAIN}" >&2; exit 1; }
echo "PASS: cert SAN includes ${DOMAIN}"

echo "PASS: envoy-gateway + cert-manager TLS compose verified"
