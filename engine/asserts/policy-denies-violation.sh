#!/usr/bin/env bash
# DEPTH: L3
# Assert: policy-denies-violation — L3 behavioral assert that proves an
# admission policy actually denies a violating object at the admission
# webhook level.
#
# This assert goes beyond mere policy object presence (L1): it actually
# performs kubectl apply --dry-run=server of violating and compliant fixtures
# to prove the admission webhook enforces the policy.
#
# PASS requires BOTH:
#   1. A violating fixture is DENIED by the admission webhook (apply fails,
#      stderr references the webhook/policy name).
#   2. A compliant fixture is ACCEPTED (apply succeeds with exit 0).
#
# FAIL paths:
#   - Policy present but violating object is admitted (webhook not enforcing).
#   - Policy present but compliant object is wrongly denied (over-block).
#
# SKIP (non-failing): when the required platform capability is absent
#   (no admission engine CRDs — Kyverno ClusterPolicy, Gatekeeper
#   ConstraintTemplate, or ValidatingAdmissionPolicy CRD not found).
#
# Env-var parameterized (no hardcoded consumer names):
#   RELEASE, NAMESPACE, PROJECT_DIR, KUBE_CONTEXT, KUBECONFIG
#
# Scenario fields:
#   namespace          — required, product namespace
#   policy_type        — optional, "kyverno" (default), "gatekeeper", or "vap"
#   violating_fixture  — required, path relative to PROJECT_DIR of a fixture that
#                         SHOULD be denied by the policy
#   compliant_fixture  — required, path relative to PROJECT_DIR of a fixture that
#                         SHOULD be admitted by the policy
#   policy_name        — optional, name of the policy/constraint to check for readiness
#   policy_namespace   — optional, namespace where the admission controller pods run
#   timeout            — optional, overall timeout (default "120s")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/assert-helpers.sh
source "$SCRIPT_DIR/lib/assert-helpers.sh"

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
RELEASE="${RELEASE:-$(yq '.product.release' "$SCENARIO")}"
POLICY_TYPE=$(yq ".asserts[$IDX].policy_type // \"kyverno\"" "$SCENARIO")
VIOLATING_FIXTURE=$(yq ".asserts[$IDX].violating_fixture" "$SCENARIO")
COMPLIANT_FIXTURE=$(yq ".asserts[$IDX].compliant_fixture" "$SCENARIO")
POLICY_NAME=$(yq ".asserts[$IDX].policy_name // \"\"" "$SCENARIO")
POLICY_NS=$(yq ".asserts[$IDX].policy_namespace // \"${NS}\"" "$SCENARIO")
PTIMEOUT=$(yq ".asserts[$IDX].timeout // \"120s\"" "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

kctl() { kubectl "${kubectl_args[@]}" "$@"; }

# ── Validate required fields ─────────────────────────────────────────────
if [ -z "${VIOLATING_FIXTURE:-}" ] || [ "${VIOLATING_FIXTURE}" = "null" ]; then
  echo "FAIL: 'violating_fixture' is required for policy-denies-violation" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

if [ -z "${COMPLIANT_FIXTURE:-}" ] || [ "${COMPLIANT_FIXTURE}" = "null" ]; then
  echo "FAIL: 'compliant_fixture' is required for policy-denies-violation" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

# ── SKIP check: platform capability absent ───────────────────────────────
CAP_FOUND=0
case "${POLICY_TYPE}" in
  kyverno)
    if kctl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
      CAP_FOUND=1
      POLICY_NS="${POLICY_NS:-kyverno}"
    fi
    ;;
  gatekeeper)
    if kctl get crd constrainttemplates.templates.gatekeeper.sh >/dev/null 2>&1; then
      CAP_FOUND=1
      POLICY_NS="${POLICY_NS:-gatekeeper-system}"
    fi
    ;;
  vap)
    # ValidatingAdmissionPolicy is a built-in admissionregistration.k8s.io API
    # resource on supported Kubernetes versions, NOT a CRD. Use api-resources
    # to detect VAP capability rather than a false-negative CRD lookup.
    if kctl api-resources --api-group=admissionregistration.k8s.io -o name 2>/dev/null | grep -qFx validatingadmissionpolicies; then
      CAP_FOUND=1
    fi
    ;;
  *)
    echo "FAIL: unsupported policy_type '${POLICY_TYPE}' (must be 'kyverno', 'gatekeeper', or 'vap')" >&2
    echo "ASSERTION_RESULT: FAIL"
    exit 1
    ;;
esac

if [ "$CAP_FOUND" -eq 0 ]; then
  echo "SKIP: ${POLICY_TYPE} admission platform capability not detected"
  echo "ASSERTION_RESULT: SKIP"
  echo "{\"reason\":\"platform_capability_absent\",\"detail\":\"No ${POLICY_TYPE} admission platform capability found — policy enforcement cannot be verified\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 0
fi

# ── Phase 0: Wait for admission controller pods Ready ────────────────────
if [ -n "${POLICY_NS:-}" ]; then
  echo "==> Phase 0: Waiting for admission controller pods in ${POLICY_NS}"
  kctl -n "${POLICY_NS}" wait pod --all --for=condition=Ready --timeout="${PTIMEOUT}" 2>/dev/null || {
    echo "WARN: not all pods in ${POLICY_NS} are Ready within ${PTIMEOUT}"
  }
fi

# ── Phase 1: Check policy readiness ──────────────────────────────────────
if [ -n "${POLICY_NAME}" ]; then
  echo "==> Phase 1: Checking policy ${POLICY_NAME} readiness"
  case "${POLICY_TYPE}" in
    kyverno)
      if kctl wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True "clusterpolicy/${POLICY_NAME}" --timeout=60s 2>/dev/null; then
        echo "PASS: ClusterPolicy ${POLICY_NAME} Ready=True"
      else
        echo "WARN: ClusterPolicy ${POLICY_NAME} may not be ready — proceeding anyway"
      fi
      ;;
    gatekeeper)
      # Check constraint template reconciliation
      CT_NAME="${POLICY_NAME}"
      for _ in $(seq 1 12); do
        GEN=$(kctl get constrainttemplate "${CT_NAME}" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "0")
        OBS_GEN=$(kctl get constrainttemplate "${CT_NAME}" -o jsonpath='{.status.byPod[0].observedGeneration}' 2>/dev/null || echo "0")
        if [ -n "${OBS_GEN}" ] && [ "${OBS_GEN}" -ge "${GEN}" ] 2>/dev/null; then
          echo "PASS: ConstraintTemplate ${CT_NAME} reconciled (gen=${GEN}, obs=${OBS_GEN})"
          break
        fi
        sleep 5
      done
      ;;
    vap)
      echo "INFO: VAP readiness — assuming policies are active"
      ;;
  esac
  # Allow webhook sync lag
  sleep 5
fi

VIOLATING_PATH="${PROJECT_DIR:-.}/${VIOLATING_FIXTURE}"
COMPLIANT_PATH="${PROJECT_DIR:-.}/${COMPLIANT_FIXTURE}"

if [ ! -f "${VIOLATING_PATH}" ]; then
  echo "FAIL: violating fixture not found at ${VIOLATING_PATH}" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

if [ ! -f "${COMPLIANT_PATH}" ]; then
  echo "FAIL: compliant fixture not found at ${COMPLIANT_PATH}" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

# ── Phase 2: Violating fixture MUST be denied ────────────────────────────
echo ""
echo "==> Phase 2: Testing violating fixture (expect DENY)"

# Capture stderr so we can validate the rejection reason, not just the exit code.
# A non-zero exit alone is insufficient: invalid fixtures, API errors, or
# unrelated admission failures could also produce a non-zero exit, causing a
# false-PASS.  We require the stderr to reference a known denial token.
VIOLATING_STDERR=""
set +e
VIOLATING_STDERR=$(kctl apply --dry-run=server -f "${VIOLATING_PATH}" 2>&1)
VIOLATING_EXIT=$?
set -e

if [ "$VIOLATING_EXIT" -ne 0 ]; then
  # Build a regex from the policy name and known denial tokens.
  # Match: 'denied', the webhook service (e.g. 'validate.kyverno.svc'),
  # or the policy name.
  deny_pattern="denied|admission webhook"
  if [ -n "${POLICY_NAME}" ]; then
    deny_pattern="${deny_pattern}|${POLICY_NAME}"
  fi
  # Add engine-specific webhook service patterns
  case "${POLICY_TYPE}" in
    kyverno)   deny_pattern="${deny_pattern}|kyverno\.svc" ;;
    gatekeeper) deny_pattern="${deny_pattern}|gatekeeper" ;;
    vap)       deny_pattern="${deny_pattern}|validatingadmissionpolicy" ;;
  esac

  if echo "${VIOLATING_STDERR}" | grep -qiE "${deny_pattern}"; then
    echo "PASS: violating fixture was DENIED by admission webhook"
  else
    echo "FAIL: violating fixture apply failed (exit ${VIOLATING_EXIT}) but stderr does not match an admission denial pattern — may be an unrelated error" >&2
    echo "  stderr: ${VIOLATING_STDERR}" >&2
    echo "ASSERTION_RESULT: FAIL"
    echo "{\"violating_unrelated_error\":true,\"exit_code\":${VIOLATING_EXIT},\"policy_type\":\"${POLICY_TYPE}\"}" | sed 's/^/ASSERTION_DETAIL: /'
    exit 1
  fi
else
  echo "FAIL: policy present but violating object was ADMITTED — enforcement not working" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"violating_admitted\":true,\"compliant_checked\":false,\"policy_type\":\"${POLICY_TYPE}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
fi

# ── Phase 3: Compliant fixture MUST be accepted ──────────────────────────
echo ""
echo "==> Phase 3: Testing compliant fixture (expect ACCEPT)"

if kctl apply --dry-run=server -f "${COMPLIANT_PATH}" 2>/dev/null; then
  echo "PASS: compliant fixture was ACCEPTED"
else
  echo "FAIL: compliant fixture was DENIED — policy may be over-blocking" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"violating_admitted\":false,\"compliant_denied\":true,\"policy_type\":\"${POLICY_TYPE}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
fi

# ── Final report ─────────────────────────────────────────────────────────
echo ""
echo "PASS: Admission policy enforcement verified (violating=denied, compliant=accepted)"
echo "ASSERTION_RESULT: PASS"
echo "{\"violating_admitted\":false,\"compliant_accepted\":true,\"policy_type\":\"${POLICY_TYPE}\",\"policy\":\"${POLICY_NAME:-none}\"}" | sed 's/^/ASSERTION_DETAIL: /'
exit 0
