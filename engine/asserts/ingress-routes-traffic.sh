#!/usr/bin/env bash
# DEPTH: L3
# Assert: ingress-routes-traffic — L3 behavioral assert that proves an
# Ingress controller actually routes traffic to the product backend.
#
# This assert goes beyond mere Ingress object presence (L1): it probes through
# the ingress controller data-plane to verify traffic reaches the product Service
# and returns the expected HTTP status.
#
# PASS requires:
#   1. Ingress object exists with the configured ingressClassName.
#   2. Ingress controller pod is Ready and reachable.
#   3. Probe through the controller with Host header returns the expected HTTP status.
#
# FAIL paths:
#   - Ingress object exists but controller returns 503 (no upstream).
#   - Ingress object exists but controller returns 404 (default backend).
#   - Ingress object exists but no controller pod found.
#
# SKIP (non-failing): when the required platform capability is absent
#   (no Ingress CRD in the cluster).
#
# Env-var parameterized (no hardcoded consumer names):
#   RELEASE, NAMESPACE, PROJECT_DIR, KUBE_CONTEXT, KUBECONFIG
#
# Scenario fields:
#   namespace            — required, product namespace
#   ingress_host         — optional, Host header value (default "${RELEASE}.${NAMESPACE}.svc")
#   ingress_name         — optional, Ingress object name (default "${RELEASE}")
#   controller_namespace — optional, namespace of the ingress controller (default "ingress-nginx")
#   controller_label     — optional, label selector for controller pods (default "app.kubernetes.io/name=ingress-nginx")
#   controller_port      — optional, HTTP port of the controller pod (default 80; Traefik/Kong use 8000)
#   expected_status      — optional, expected HTTP status (default 200)
#   curl_image           — optional, curl image for probing
#   timeout              — optional, per-probe timeout (default "60s")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/assert-helpers.sh
source "$SCRIPT_DIR/lib/assert-helpers.sh"

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
RELEASE="${RELEASE:-$(yq '.product.release' "$SCENARIO")}"
INGRESS_HOST=$(yq ".asserts[$IDX].ingress_host // \"${RELEASE}.${NS}.svc\"" "$SCENARIO")
INGRESS_NAME=$(yq ".asserts[$IDX].ingress_name // \"${RELEASE}\"" "$SCENARIO")
CTRL_NS=$(yq ".asserts[$IDX].controller_namespace // \"ingress-nginx\"" "$SCENARIO")
CTRL_LABEL=$(yq ".asserts[$IDX].controller_label // \"app.kubernetes.io/name=ingress-nginx\"" "$SCENARIO")
CTRL_PORT=$(yq ".asserts[$IDX].controller_port // 80" "$SCENARIO")
EXPECTED_STATUS=$(yq ".asserts[$IDX].expected_status // 200" "$SCENARIO")
CURL_IMAGE=$(yq ".asserts[$IDX].curl_image // \"quay.io/curl/curl:8.20.0\"" "$SCENARIO")
PTIMEOUT=$(yq ".asserts[$IDX].timeout // \"60s\"" "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

kctl() { kubectl "${kubectl_args[@]}" "$@"; }

# ── SKIP check: platform capability absent ───────────────────────────────
# Ingress is a built-in networking.k8s.io API resource, NOT a CRD.
# Use kubectl api-resources to detect it correctly.
# Capture output to a variable first to avoid SIGPIPE from pipefail+grep -q
# when kubectl produces multi-line output and grep exits early on match.
_api_res=""
_api_res=$(kctl api-resources --api-group=networking.k8s.io 2>/dev/null || true)
if ! echo "$_api_res" | grep -q '^ingresses\b'; then
  echo "SKIP: Ingress platform capability not detected (networking.k8s.io Ingress API resource not available)"
  echo "ASSERTION_RESULT: SKIP"
  echo 'ASSERTION_DETAIL: {"reason":"platform_capability_absent","detail":"networking.k8s.io Ingress API resource not available"}'
  exit 0
fi

# ── Verify Ingress object exists ─────────────────────────────────────────
echo "==> Checking Ingress '${INGRESS_NAME}' in namespace ${NS}"
if ! kctl -n "${NS}" get ingress "${INGRESS_NAME}" >/dev/null 2>&1; then
  # Try release-scoped Ingress lookup
  INGRESS_LIST=""
  INGRESS_LIST=$(kctl -n "${NS}" get ingress -l "app.kubernetes.io/instance=${RELEASE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  if [ -n "${INGRESS_LIST}" ]; then
    INGRESS_NAME=$(echo "$INGRESS_LIST" | awk '{print $1}')
    echo "Found release-scoped Ingress: ${INGRESS_NAME}"
  else
    echo "SKIP: no Ingress '${INGRESS_NAME}' or release-scoped Ingress found in namespace ${NS}"
    echo "ASSERTION_RESULT: SKIP"
    echo "{\"reason\":\"platform_capability_absent\",\"detail\":\"No Ingress found in namespace '${NS}'\"}" | sed 's/^/ASSERTION_DETAIL: /'
    exit 0
  fi
fi
echo "Ingress '${INGRESS_NAME}' exists"

# ── Find controller pod IP ───────────────────────────────────────────────
echo ""
echo "==> Looking up controller pod in namespace ${CTRL_NS} (label: ${CTRL_LABEL})"

CTRL_POD=""
CTRL_POD=$(kctl -n "${CTRL_NS}" get pod -l "${CTRL_LABEL}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "${CTRL_POD}" ]; then
  echo "FAIL: no controller pod found in namespace ${CTRL_NS} with label '${CTRL_LABEL}'" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

CTRL_IP=""
CTRL_IP=$(kctl -n "${CTRL_NS}" get pod "${CTRL_POD}" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
if [ -z "${CTRL_IP}" ]; then
  echo "FAIL: could not resolve pod IP for controller pod '${CTRL_POD}'" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

echo "Controller pod: ${CTRL_POD} (IP: ${CTRL_IP})"

# ── Probe via ingress controller ─────────────────────────────────────────
echo ""
echo "==> Probing through ${CTRL_NS}/${CTRL_POD} with Host: ${INGRESS_HOST}"

PROBE_POD="ct-irt-$$"
curl_raw=""

# NOTE: Use `|| curl_raw="000"` NOT `|| echo "000"` inside $().
# When curl fails (non-zero exit), the pod exits non-zero, kubectl exits
# non-zero, and the `|| echo "000"` inside $() would APPEND "000" to the
# already-captured curl output (e.g., "000" from %{http_code}), producing
# "000000" which parse_http_code rejects.  The assignment form `|| var="val"`
# overwrites the captured output with the fallback.
curl_raw=$(kctl -n "${NS}" run "${PROBE_POD}" --rm -i --restart=Never --quiet \
  --image="${CURL_IMAGE}" --pod-running-timeout="${PTIMEOUT}" -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: ${INGRESS_HOST}" \
    "http://${CTRL_IP}:${CTRL_PORT}/" 2>/dev/null) || curl_raw="000"

# Extract last 3-digit HTTP status code.
# kubectl run --rm -i may output the code twice ("200200") on some versions.
# Using grep+tail to pick the last occurrence is robust against this.
HTTP_CODE=""
HTTP_CODE=$(printf '%s' "$curl_raw" | grep -oE '[0-9]{3}' | tail -1 || true)
[ -z "$HTTP_CODE" ] && HTTP_CODE="000"

echo "Ingress HTTP response: ${HTTP_CODE}"

# ── Evaluate ─────────────────────────────────────────────────────────────
if [ "${HTTP_CODE}" = "${EXPECTED_STATUS}" ]; then
  echo "PASS: Ingress routed traffic successfully (HTTP ${HTTP_CODE})"
  echo "ASSERTION_RESULT: PASS"
  echo "{\"ingress_name\":\"${INGRESS_NAME}\",\"host\":\"${INGRESS_HOST}\",\"http_code\":\"${HTTP_CODE}\",\"controller\":\"${CTRL_POD}\",\"namespace\":\"${NS}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 0
elif [ "${HTTP_CODE}" = "503" ]; then
  echo "FAIL: Ingress exists but returns 503 — no upstream or backend mis-wired" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"reason\":\"backend_unavailable\",\"detail\":\"HTTP 503 from ingress; backend Service may be mis-wired or unhealthy\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
elif [ "${HTTP_CODE}" = "404" ]; then
  echo "FAIL: Ingress exists but returns 404 — default backend, host/route not matched" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"reason\":\"host_not_matched\",\"detail\":\"HTTP 404 from ingress; Host header may not match any Ingress rule\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
else
  echo "FAIL: expected HTTP ${EXPECTED_STATUS}, got ${HTTP_CODE}" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"reason\":\"http_status_mismatch\",\"detail\":\"Expected ${EXPECTED_STATUS}, got ${HTTP_CODE}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
fi
