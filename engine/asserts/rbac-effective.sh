#!/usr/bin/env bash
# DEPTH: L3
# Assert: rbac-effective — L3 behavioral assert that proves RBAC permissions
# are effectively granted to the chart's ServiceAccount via kubectl auth can-i.
#
# This assert goes beyond mere RBAC object presence (L1 rbac-objects): it
# actually checks effective permissions by running kubectl auth can-i
# --as=system:serviceaccount:<ns>:<sa> to confirm the ServiceAccount can
# perform the configured verbs on the configured resources.
#
# PASS requires BOTH:
#   1. All configured granted verbs/resources return "yes" from auth can-i.
#   2. All configured denied verbs/resources return "no" from auth can-i
#      (proving the grant is bounded, not cluster-admin).
#
# FAIL paths:
#   - RBAC objects exist but a should-be-granted action returns "no"
#     (binding ineffective — roleRef/subjects mis-wired).
#   - RBAC objects exist but a should-be-denied action returns "yes"
#     (over-grant — binding too broad).
#
# SKIP (non-failing): when the required platform capability is absent
#   (no ServiceAccount found for the release).
#
# Env-var parameterized (no hardcoded consumer names):
#   RELEASE, NAMESPACE, PROJECT_DIR, KUBE_CONTEXT, KUBECONFIG
#
# Scenario fields:
#   namespace       — required, product namespace
#   service_account — optional, ServiceAccount name (default "${RELEASE}")
#   granted         — required, array of {verb, resource, apiGroup?} that
#                      SHOULD return "yes"
#   denied          — optional, array of {verb, resource, apiGroup?} that
#                      SHOULD return "no" (boundary check)
#   timeout         — optional, timeout (default "60s")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/assert-helpers.sh
source "$SCRIPT_DIR/lib/assert-helpers.sh"

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
RELEASE="${RELEASE:-$(yq '.product.release' "$SCENARIO")}"
SA=$(yq ".asserts[$IDX].service_account // \"${RELEASE}\"" "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

kctl() { kubectl "${kubectl_args[@]}" "$@"; }

# ── SKIP check: ServiceAccount must exist ─────────────────────────────────
SA_AS="system:serviceaccount:${NS}:${SA}"

if ! kctl -n "${NS}" get serviceaccount "${SA}" >/dev/null 2>&1; then
  echo "SKIP: ServiceAccount ${SA} not found in namespace ${NS} — RBAC effectiveness cannot be verified"
  echo "ASSERTION_RESULT: SKIP"
  echo "{\"reason\":\"platform_capability_absent\",\"detail\":\"ServiceAccount ${SA} not found in namespace ${NS}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 0
fi

echo "ServiceAccount: ${SA_AS}"

# ── Helper: check a single auth can-i ────────────────────────────────────
auth_check() {
  local verb="$1"
  local resource="$2"
  local subgroup="${3:-}"

  local args=(auth can-i "${verb}" "${resource}" -n "${NS}" "--as=${SA_AS}")
  if [ -n "${subgroup}" ] && [ "${subgroup}" != "null" ]; then
    args+=(--subresource="${subgroup}")
  fi

  local result
  result=$(kctl "${args[@]}" 2>/dev/null || echo "no")
  printf '%s' "$result"
}

# ── Phase 1: Check granted verbs/resources ───────────────────────────────
echo ""
echo "==> Phase 1: Checking granted permissions"
GRANTED_COUNT=$(yq ".asserts[$IDX].granted | length" "$SCENARIO" 2>/dev/null || echo "0")

if [ "${GRANTED_COUNT}" -eq 0 ] || [ "${GRANTED_COUNT}" = "null" ]; then
  echo "FAIL: 'granted' list is required for rbac-effective — must specify at least one verb/resource pair" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

overall_fail=0

for i in $(seq 0 $((GRANTED_COUNT - 1))); do
  verb=$(yq ".asserts[$IDX].granted[$i].verb" "$SCENARIO")
  resource=$(yq ".asserts[$IDX].granted[$i].resource" "$SCENARIO")
  subgroup=$(yq ".asserts[$IDX].granted[$i].subresource // \"\"" "$SCENARIO")

  result=$(auth_check "$verb" "$resource" "$subgroup")
  echo "  auth can-i ${verb} ${resource} ${subgroup:+--subresource=${subgroup}} → ${result}"

  if [ "${result}" != "yes" ]; then
    echo "FAIL: expected 'yes' for ${verb} ${resource} but got '${result}' — binding ineffective" >&2
    overall_fail=1
  fi
done

# ── Phase 2: Check denied verbs/resources (boundary check) ───────────────
echo ""
echo "==> Phase 2: Checking denied permissions (boundary)"
DENIED_COUNT=$(yq ".asserts[$IDX].denied | length" "$SCENARIO" 2>/dev/null || echo "0")

if [ "${DENIED_COUNT}" != "0" ] && [ "${DENIED_COUNT}" != "null" ]; then
  for i in $(seq 0 $((DENIED_COUNT - 1))); do
    verb=$(yq ".asserts[$IDX].denied[$i].verb" "$SCENARIO")
    resource=$(yq ".asserts[$IDX].denied[$i].resource" "$SCENARIO")
    subgroup=$(yq ".asserts[$IDX].denied[$i].subresource // \"\"" "$SCENARIO")

    result=$(auth_check "$verb" "$resource" "$subgroup")
    echo "  auth can-i ${verb} ${resource} ${subgroup:+--subresource=${subgroup}} → ${result}"

    if [ "${result}" != "no" ]; then
      echo "FAIL: expected 'no' for ${verb} ${resource} but got '${result}' — RBAC may be over-granted" >&2
      overall_fail=1
    fi
  done
else
  echo "  (no denied checks configured — skipping boundary verification)"
fi

# ── Final report ─────────────────────────────────────────────────────────
if [ "$overall_fail" -eq 0 ]; then
  echo ""
  echo "PASS: RBAC effective permissions verified (all granted=yes, all denied=no)"
  echo "ASSERTION_RESULT: PASS"
  echo "{\"service_account\":\"${SA_AS}\",\"namespace\":\"${NS}\",\"granted_checked\":${GRANTED_COUNT},\"denied_checked\":$([ "${DENIED_COUNT}" = "null" ] && echo 0 || echo "${DENIED_COUNT}")}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 0
else
  echo ""
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi
