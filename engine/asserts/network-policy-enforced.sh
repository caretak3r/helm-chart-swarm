#!/usr/bin/env bash
# DEPTH: L3
# Assert: network-policy-enforced — L3 behavioral assert that proves NetworkPolicy
# (or CiliumNetworkPolicy) enforcement on live Kubernetes clusters.
#
# This assert goes beyond the L1 "network-policy" presence check: it actually probes
# traffic flows to prove the policy DENIES blocked traffic AND ALLOWS permitted traffic.
#
# PASS requires BOTH:
#   1. An ALLOWED probe (labeled to match the policy's ingress rule) reaches the
#      product Service and returns the expected HTTP status (default 200).
#   2. A DENIED probe (NOT matching the policy's ingress rule) is BLOCKED
#      (timeout / connection refused / HTTP 000).
#
# FAIL paths:
#   - Policy present but denied traffic still flows (HTTP 200) → policy not enforced
#   - Allowed path broken (allowed probe blocked) → over-block (policy too restrictive)
#
# SKIP (non-failing): when the required platform capability is absent
#   (no NetworkPolicy CRD, no CiliumNetworkPolicy CRD, or CNI does not support policy).
#
# Env-var parameterized (no hardcoded consumer names):
#   RELEASE, NAMESPACE, PROJECT_DIR, KUBE_CONTEXT, KUBECONFIG
#
# Scenario fields:
#   namespace          — required, product namespace
#   port              — optional, default 80
#   allowed_label     — optional, label for the allowed probe pod (default "access=allowed")
#   expected_status   — optional, default 200
#   curl_image        — optional, curl image for probe (from versions config)
#   timeout           — optional, per-probe timeout (default "60s")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/assert-helpers.sh
source "$SCRIPT_DIR/lib/assert-helpers.sh"

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
PORT=$(yq ".asserts[$IDX].port // 80" "$SCENARIO")
ALLOWED_LABEL=$(yq ".asserts[$IDX].allowed_label // \"access=allowed\"" "$SCENARIO")
EXPECTED_STATUS=$(yq ".asserts[$IDX].expected_status // 200" "$SCENARIO")
CURL_IMAGE=$(yq ".asserts[$IDX].curl_image // \"quay.io/curl/curl:8.20.0\"" "$SCENARIO")
PTIMEOUT=$(yq ".asserts[$IDX].timeout // \"60s\"" "$SCENARIO")
RELEASE="${RELEASE:-$(yq '.product.release' "$SCENARIO")}"

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

kctl() { kubectl "${kubectl_args[@]}" "$@"; }

# ── SKIP check: platform capability absent ───────────────────────────────
# NetworkPolicy is a BUILT-IN networking.k8s.io/v1 API resource, NOT a CRD.
# Detecting it via `kubectl get crd` always returns NotFound, causing false
# SKIP on clusters enforcing standard NetworkPolicy.  Use `kubectl
# api-resources` for built-in APIs and fall back to CRD checks only for
# CNI-specific custom resources (Cilium, Calico).
POLICY_CAPABILITY_FOUND=0
if kctl api-resources --api-group=networking.k8s.io 2>/dev/null | grep -q 'networkpolicies'; then
  POLICY_CAPABILITY_FOUND=1
elif kctl get crd ciliumnetworkpolicies.cilium.io >/dev/null 2>&1; then
  POLICY_CAPABILITY_FOUND=1
elif kctl get crd networkpolicies.crd.projectcalico.org >/dev/null 2>&1; then
  POLICY_CAPABILITY_FOUND=1
fi

if [ "$POLICY_CAPABILITY_FOUND" -eq 0 ]; then
  echo "SKIP: NetworkPolicy platform capability not detected (no networking.k8s.io NetworkPolicy API, CiliumNetworkPolicy CRD, or Calico NetworkPolicy CRD found)"
  echo "ASSERTION_RESULT: SKIP"
  echo 'ASSERTION_DETAIL: {"reason":"platform_capability_absent","detail":"No NetworkPolicy API, CiliumNetworkPolicy, or Calico NetworkPolicy capability found"}'
  exit 0
fi

# ── Resolve Service endpoint ─────────────────────────────────────────────
SVC_NAME="${RELEASE}"
SVC_IP=$(kctl -n "${NS}" get svc "${SVC_NAME}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [ -z "${SVC_IP}" ] || [ "${SVC_IP}" = "<none>" ]; then
  # Fallback: try finding any release-scoped service
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

echo "Product Service: ${SVC_NAME}.${NS}.svc.cluster.local (ClusterIP: ${SVC_IP}:${PORT})"

# ── Helper: probe via ephemeral curl pod ─────────────────────────────────
probe_service() {
  local label="$1"   # label for the probe pod (empty = none)
  local pod_name="$2"

  local label_arg=""
  if [ -n "$label" ]; then
    label_arg="--labels=$label"
  fi

  local raw_code
  raw_code=$(kctl -n "${NS}" run "${pod_name}" --rm -i --restart=Never --quiet \
    --image="${CURL_IMAGE}" --pod-running-timeout="${PTIMEOUT}" \
    ${label_arg:+$label_arg} -- \
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 15 \
      "http://${SVC_IP}:${PORT}/" 2>/dev/null || echo "000")

  local code
  code=$(parse_http_code "$raw_code" 2>/dev/null || echo "$raw_code")
  printf '%s' "$code"
}

# ── Phase 1: ALLOWED probe (should succeed per policy) ──────────────────
echo ""
echo "==> Phase 1: ALLOWED probe (with label '${ALLOWED_LABEL}')"
ALLOWED_POD="ct-npe-allowed-$$"
ALLOWED_CODE=""
ALLOWED_CODE=$(probe_service "${ALLOWED_LABEL}" "${ALLOWED_POD}")

echo "ALLOWED probe HTTP code: ${ALLOWED_CODE}"

# ── Phase 2: DENIED probe (must be blocked by policy) ───────────────────
echo ""
echo "==> Phase 2: DENIED probe (no matching label)"
DENIED_POD="ct-npe-denied-$$"
DENIED_CODE=""
DENIED_CODE=$(probe_service "" "${DENIED_POD}")

echo "DENIED probe HTTP code: ${DENIED_CODE}"

# ── Evaluate results ─────────────────────────────────────────────────────
overall_fail=0

# Check ALLOWED path — must succeed
if [ "${ALLOWED_CODE}" != "${EXPECTED_STATUS}" ]; then
  # Check if allowed probe was blocked (000 or timeout)
  case "${ALLOWED_CODE}" in
    000|028)
      echo "FAIL: allowed path BROKEN — expected HTTP ${EXPECTED_STATUS} but got '${ALLOWED_CODE}' (policy over-block)" >&2
      ;;
    *)
      echo "FAIL: allowed path returned HTTP ${ALLOWED_CODE}, expected ${EXPECTED_STATUS}" >&2
      ;;
  esac
  overall_fail=1
else
  echo "PASS: allowed client reached product Service (HTTP ${ALLOWED_CODE})"
fi

# Check DENIED path — must be blocked
if [ "${DENIED_CODE}" = "000" ] || [ "${DENIED_CODE}" = "028" ]; then
  echo "PASS: denied client was blocked (code=${DENIED_CODE})"
elif [ "${DENIED_CODE}" = "${EXPECTED_STATUS}" ]; then
  echo "FAIL: policy present but traffic still flows — denied client reached product Service (HTTP ${DENIED_CODE})" >&2
  overall_fail=1
else
  # Non-200 but not completely blocked — still a potential enforcement failure
  echo "FAIL: denied client returned HTTP ${DENIED_CODE} — enforcement may be incomplete" >&2
  overall_fail=1
fi

if [ "$overall_fail" -eq 0 ]; then
  echo ""
  echo "PASS: NetworkPolicy enforcement verified (allowed=reachable, denied=blocked)"
  echo "ASSERTION_RESULT: PASS"
  echo "{\"allowed_code\":\"${ALLOWED_CODE}\",\"denied_code\":\"${DENIED_CODE}\",\"service\":\"${SVC_NAME}\",\"namespace\":\"${NS}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 0
else
  echo ""
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"allowed_code\":\"${ALLOWED_CODE}\",\"denied_code\":\"${DENIED_CODE}\",\"service\":\"${SVC_NAME}\",\"namespace\":\"${NS}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
fi
