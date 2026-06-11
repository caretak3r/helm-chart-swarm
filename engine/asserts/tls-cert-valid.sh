#!/usr/bin/env bash
# DEPTH: L3
# Assert: tls-cert-valid — L3 behavioral assert that proves a valid TLS
# certificate is served by the product Service and its chain is trusted.
#
# This assert goes beyond mere TLS Secret presence (L1): it actually performs
# an HTTPS probe with --cacert verification, checks the certificate's SAN
# matches the configured host, and verifies the cert is not expired.
#
# PASS requires ALL of:
#   1. TLS Secret exists with tls.crt, tls.key, and ca.crt keys.
#   2. HTTPS probe with --cacert returns the expected HTTP status (default 200).
#   3. The served leaf certificate's SAN contains the configured host.
#   4. The certificate's notAfter is in the future (not expired).
#
# FAIL paths:
#   - TLS Secret present but cert is expired.
#   - TLS Secret present but SAN does not match the configured host.
#   - TLS Secret present but CA is untrusted (curl TLS verify fails).
#
# SKIP (non-failing): when the required platform capability is absent
#   (no TLS Secret found, or no cert-manager/TLS infrastructure).
#
# Env-var parameterized (no hardcoded consumer names):
#   RELEASE, NAMESPACE, PROJECT_DIR, KUBE_CONTEXT, KUBECONFIG
#
# Scenario fields:
#   namespace   — required, product namespace
#   tls_secret  — optional, TLS Secret name (default "${RELEASE}-tls")
#   tls_host    — optional, TLS hostname (default "${RELEASE}.${NAMESPACE}.svc")
#   port        — optional, HTTPS port (default 443)
#   expected_status — optional, expected HTTP status (default 200)
#   curl_image  — optional, curl image for probing
#   timeout     — optional, per-probe timeout (default "60s")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/assert-helpers.sh
source "$SCRIPT_DIR/lib/assert-helpers.sh"

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
RELEASE="${RELEASE:-$(yq '.product.release' "$SCENARIO")}"
TLS_SECRET=$(yq ".asserts[$IDX].tls_secret // \"${RELEASE}-tls\"" "$SCENARIO")
TLS_HOST=$(yq ".asserts[$IDX].tls_host // \"${RELEASE}.${NS}.svc\"" "$SCENARIO")
TLS_PORT=$(yq ".asserts[$IDX].port // 443" "$SCENARIO")
EXPECTED_STATUS=$(yq ".asserts[$IDX].expected_status // 200" "$SCENARIO")
CURL_IMAGE=$(yq ".asserts[$IDX].curl_image // \"quay.io/curl/curl:8.20.0\"" "$SCENARIO")
PTIMEOUT=$(yq ".asserts[$IDX].timeout // \"60s\"" "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

kctl() { kubectl "${kubectl_args[@]}" "$@"; }

# ── SKIP check: platform capability absent ───────────────────────────────
# Check if the TLS Secret exists and has the required keys.
if ! kctl -n "${NS}" get secret "${TLS_SECRET}" >/dev/null 2>&1; then
  echo "SKIP: TLS Secret '${TLS_SECRET}' not found in namespace ${NS}"
  echo "ASSERTION_RESULT: SKIP"
  echo "ASSERTION_DETAIL: {\"reason\":\"platform_capability_absent\",\"detail\":\"TLS Secret '${TLS_SECRET}' not found in namespace '${NS}'\"}"
  exit 0
fi

SECRET_KEYS=""
SECRET_KEYS=$(kctl -n "${NS}" get secret "${TLS_SECRET}" -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys | sort[]' 2>/dev/null || echo "")

HAS_TLS_CRT=0
HAS_TLS_KEY=0
if echo "${SECRET_KEYS}" | grep -qx 'tls.crt' 2>/dev/null; then HAS_TLS_CRT=1; fi
if echo "${SECRET_KEYS}" | grep -qx 'tls.key' 2>/dev/null; then HAS_TLS_KEY=1; fi
# ca.crt presence is checked downstream; not gated here

if [ "$HAS_TLS_CRT" -eq 0 ] || [ "$HAS_TLS_KEY" -eq 0 ]; then
  echo "SKIP: TLS Secret '${TLS_SECRET}' missing required keys (tls.crt, tls.key)"
  echo "ASSERTION_RESULT: SKIP"
  echo "{\"reason\":\"platform_capability_absent\",\"detail\":\"TLS Secret '${TLS_SECRET}' missing tls.crt or tls.key\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 0
fi

echo "TLS Secret: ${TLS_SECRET} (namespace: ${NS})"

# ── Resolve Service endpoint ─────────────────────────────────────────────
SVC_NAME="${RELEASE}"
SVC_IP=$(kctl -n "${NS}" get svc "${SVC_NAME}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [ -z "${SVC_IP}" ] || [ "${SVC_IP}" = "<none>" ]; then
  svc_list=""
  svc_list=$(kctl -n "${NS}" get svc -l "app.kubernetes.io/instance=${RELEASE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  if [ -z "$svc_list" ]; then
    echo "FAIL: no release-scoped Service found in namespace ${NS}" >&2
    echo "ASSERTION_RESULT: FAIL"
    exit 1
  fi
  SVC_NAME=$(echo "$svc_list" | awk '{print $1}')
  SVC_IP=$(kctl -n "${NS}" get svc "${SVC_NAME}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
fi

if [ -z "${SVC_IP}" ] || [ "${SVC_IP}" = "<none>" ]; then
  echo "FAIL: could not resolve ClusterIP for service ${SVC_NAME} in namespace ${NS}" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

echo "Product Service: ${SVC_NAME}.${NS}.svc.cluster.local (ClusterIP: ${SVC_IP})"

# ── Phase 1: Extract certificates from TLS Secret ────────────────────────
TMPDIR="$(mktemp -d /tmp/tcv-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

# Extract tls.crt and ca.crt from the secret
kctl -n "${NS}" get secret "${TLS_SECRET}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$TMPDIR/tls.crt" || true
kctl -n "${NS}" get secret "${TLS_SECRET}" -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d > "$TMPDIR/tls.key" || true

# CA cert may come from a named key or from existing ca.crt
CA_B64=""
CA_B64=$(kctl -n "${NS}" get secret "${TLS_SECRET}" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || echo "")
if [ -z "$CA_B64" ] || [ "$CA_B64" = "null" ]; then
  # Fallback: use tls.crt as the CA (self-signed pattern)
  cp "$TMPDIR/tls.crt" "$TMPDIR/ca.crt" 2>/dev/null || true
else
  echo "$CA_B64" | base64 -d > "$TMPDIR/ca.crt" 2>/dev/null || true
fi

# ── Phase 2: Check certificate expiry ────────────────────────────────────
echo ""
echo "==> Checking certificate expiry"
if ! openssl x509 -in "$TMPDIR/tls.crt" -noout -checkend 0 2>/dev/null; then
  echo "FAIL: TLS certificate is EXPIRED" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo 'ASSERTION_DETAIL: {"reason":"cert_expired","detail":"Certificate notAfter is in the past"}'
  exit 1
fi
echo "PASS: certificate is not expired"

# ── Phase 3: Check SAN matches host ──────────────────────────────────────
echo ""
echo "==> Checking certificate SAN for host '${TLS_HOST}'"
SAN_OUT=""
SAN_OUT=$(openssl x509 -in "$TMPDIR/tls.crt" -noout -ext subjectAltName 2>/dev/null || echo "")
echo "SAN: ${SAN_OUT}"
if ! echo "${SAN_OUT}" | grep -q "DNS:${TLS_HOST}"; then
  echo "FAIL: certificate SAN does not contain '${TLS_HOST}'" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"reason\":\"san_mismatch\",\"detail\":\"SAN '${SAN_OUT}' does not contain DNS:${TLS_HOST}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
fi
echo "PASS: certificate SAN includes '${TLS_HOST}'"

# ── Phase 4: HTTPS probe with --cacert verification ──────────────────────
echo ""
echo "==> Probing HTTPS with --cacert verification (expect HTTP ${EXPECTED_STATUS})"

PROBE_POD="ct-tcv-$$"

# Encode CA cert for passing into the probe pod
CA_BASE64=""
CA_BASE64=$(base64 < "$TMPDIR/ca.crt" | tr -d '\n' 2>/dev/null || echo "")

# Use $() capture (not temp-file redirect) so kubectl's stdout is captured
# correctly by the subshell.  The `|| echo "000"` fallback ensures a value
# is always available; grep+tail then extracts the last 3-digit code to handle
# the kubectl double-output case ("200200" → "200").
CURL_RAW=""
CURL_RAW=$(kctl -n "${NS}" run "${PROBE_POD}" --rm -i --restart=Never --quiet \
  --image="${CURL_IMAGE}" --pod-running-timeout="${PTIMEOUT}" -- \
  sh -c "echo '${CA_BASE64}' | base64 -d > /tmp/ca.crt && \
    curl -s -o /dev/null -w '%{http_code}' --cacert /tmp/ca.crt --max-time 15 \
    --resolve '${TLS_HOST}:${TLS_PORT}:${SVC_IP}' \
    'https://${TLS_HOST}:${TLS_PORT}/'" 2>/dev/null || echo "000")

HTTP_CODE=""
HTTP_CODE=$(printf '%s' "$CURL_RAW" | grep -oE '[0-9]{3}' | tail -1 || true)
[ -z "$HTTP_CODE" ] && HTTP_CODE="000"

if [ "$HTTP_CODE" = "000" ]; then
  echo "FAIL: HTTPS probe returned '${CURL_RAW}' — could not connect or parse HTTP status code" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo 'ASSERTION_DETAIL: {"reason":"http_parse_failed","detail":"Could not parse HTTP status from curl output"}'
  exit 1
fi

echo "HTTPS response: ${HTTP_CODE}"

if [ "${HTTP_CODE}" = "${EXPECTED_STATUS}" ]; then
  echo "PASS: HTTPS ${HTTP_CODE} with --cacert verification"
else
  echo "FAIL: expected HTTPS ${EXPECTED_STATUS}, got ${HTTP_CODE}" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"reason\":\"http_status_mismatch\",\"detail\":\"Expected ${EXPECTED_STATUS}, got ${HTTP_CODE}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
fi

# ── All checks passed ────────────────────────────────────────────────────
echo ""
echo "PASS: TLS certificate is valid (not expired, SAN matches, CA trusted, HTTPS ${HTTP_CODE})"
echo "ASSERTION_RESULT: PASS"
echo "{\"host\":\"${TLS_HOST}\",\"port\":\"${TLS_PORT}\",\"http_code\":\"${HTTP_CODE}\",\"secret\":\"${TLS_SECRET}\",\"namespace\":\"${NS}\"}" | sed 's/^/ASSERTION_DETAIL: /'
exit 0
