#!/usr/bin/env bash
# manual-tls-secret basic smoke assertion.
# Verifies: TLS Secret exists with tls.crt + tls.key, pods Ready,
# HTTPS serving with --insecure (self-signed), Secret type is kubernetes.io/tls.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SECRET_NAME="${TLS_SECRET_NAME:-manual-tls-basic}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Verifying TLS Secret '${SECRET_NAME}' type"
SECRET_TYPE=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.type}')
echo "Secret type: ${SECRET_TYPE}"
[ "${SECRET_TYPE}" = "kubernetes.io/tls" ] || { echo "FAIL: expected type kubernetes.io/tls, got ${SECRET_TYPE}" >&2; exit 1; }
echo "PASS: Secret type is kubernetes.io/tls"

echo "==> Verifying TLS Secret '${SECRET_NAME}' data keys"
secret_keys=$(kctl -n "${NS}" get secret "${SECRET_NAME}" -o json | jq -r '.data | keys | sort[]')
echo "Secret keys: ${secret_keys}"
echo "${secret_keys}" | grep -qx 'tls.crt' || { echo "FAIL: missing tls.crt" >&2; exit 1; }
echo "${secret_keys}" | grep -qx 'tls.key' || { echo "FAIL: missing tls.key" >&2; exit 1; }
echo "OK: tls.crt, tls.key both present"

echo "==> Verifying tls.crt is valid PEM"
kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject
echo "PASS: tls.crt is a valid certificate"

echo "==> Verifying tls.key is valid PEM"
kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.key}' | base64 -d | openssl rsa -check -noout 2>/dev/null || {
  # may be ECDSA - try that
  kctl -n "${NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.key}' | base64 -d | openssl ec -check -noout 2>/dev/null || {
    echo "FAIL: tls.key is not a valid RSA or ECDSA private key" >&2; exit 1
  }
}
echo "PASS: tls.key is a valid private key"

echo "==> Waiting for pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: chart pods Ready"

echo "==> Verifying HTTPS reachable from in-cluster curl"
SVC_IP=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.clusterIP}')
TLS_PORT=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
TLS_PORT="${TLS_PORT:-443}"
DOMAIN="${RELEASE}.${NS}.svc"
CURL_IMAGE="quay.io/curl/curl:8.20.0"
PROBE_POD="ct-mtb-$$"

# Pre-delete any stale probe pod.
kctl -n "${NS}" delete pod "${PROBE_POD}" --now --ignore-not-found >/dev/null 2>&1 || true

# Run probe pod without -i to avoid stdin-attachment races that lose stdout.
# Use -k (insecure) because the cert is self-signed without a CA in the secret.
kctl -n "${NS}" run "${PROBE_POD}" --restart=Never \
  --image="${CURL_IMAGE}" --pod-running-timeout=90s -- \
  sh -c "curl -s -o /dev/null -w '%{http_code}' -k \
    --max-time 15 \
    --resolve '${DOMAIN}:${TLS_PORT}:${SVC_IP}' \
    'https://${DOMAIN}:${TLS_PORT}/'" >/dev/null 2>&1 || true

# Poll until the pod reaches a terminal phase (up to 120s).
_wait_s=0
while [ "$_wait_s" -lt 120 ]; do
  _phase=$(kctl -n "${NS}" get pod "${PROBE_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  if [ "$_phase" = "Succeeded" ] || [ "$_phase" = "Failed" ]; then
    break
  fi
  sleep 3
  _wait_s=$((_wait_s + 3))
done

# Retrieve pod logs (curl wrote the HTTP code to stdout).
CURL_RAW=""
CURL_RAW=$(kctl -n "${NS}" logs "${PROBE_POD}" 2>/dev/null || echo "")
[ -z "$CURL_RAW" ] && CURL_RAW="000"

# Cleanup probe pod.
kctl -n "${NS}" delete pod "${PROBE_POD}" --now --ignore-not-found >/dev/null 2>&1 || true

HTTP_CODE=""
HTTP_CODE=$(printf '%s' "$CURL_RAW" | grep -oE '[0-9]{3}' | tail -1 || true)
[ -z "$HTTP_CODE" ] && HTTP_CODE="000"

echo "HTTPS response: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTPS 200"
else
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: manual-tls-secret basic scenario verified"
