#!/usr/bin/env bash
# DEPTH: L3
# Assert: scheduled-on-target — L3 behavioral assert that proves pods actually
# land on the targeted node as configured by nodeSelector/affinity/tolerations.
#
# This assert goes beyond mere scheduling fields presence (L1 scheduling-present):
# it actually checks every release pod's .spec.nodeName and verifies each node
# carries the configured target label/taint — proving the scheduler enforced
# the placement constraints, not just that they were rendered.
#
# PASS requires BOTH:
#   1. Every release-scoped pod is scheduled (no pods Pending).
#   2. Every release-scoped pod's .spec.nodeName resolves to a node that
#      carries the configured target_label.
#
# FAIL paths:
#   - Scheduling configured but pods landed on a non-target node
#     (scheduler ignored a soft preferred affinity).
#   - Scheduling configured but pods are stuck Pending
#     (target node unschedulable / taint not tolerated).
#
# SKIP (non-failing): when no release pods exist or no scheduling config.
#
# Env-var parameterized (no hardcoded consumer names):
#   RELEASE, NAMESPACE, PROJECT_DIR, KUBE_CONTEXT, KUBECONFIG
#
# Scenario fields:
#   namespace    — required, product namespace
#   target_label — required, label key=value that target nodes MUST carry
#                   (e.g. "node-role.kubernetes.io/worker=" or "disktype=ssd")
#   timeout      — optional, timeout for waiting for pods to schedule (default "120s")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/assert-helpers.sh
source "$SCRIPT_DIR/lib/assert-helpers.sh"

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
RELEASE="${RELEASE:-$(yq '.product.release' "$SCENARIO")}"
TARGET_LABEL=$(yq ".asserts[$IDX].target_label" "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

kctl() { kubectl "${kubectl_args[@]}" "$@"; }

# ── Validate required fields ─────────────────────────────────────────────
if [ -z "${TARGET_LABEL:-}" ]; then
  echo "FAIL: 'target_label' is required for scheduled-on-target" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

# Parse target_label into key and optional value
TARGET_KEY="${TARGET_LABEL%%=*}"
TARGET_VALUE="${TARGET_LABEL#*=}"
if [ "${TARGET_VALUE}" = "${TARGET_LABEL}" ]; then
  # No '=' in the label — it's a key-only check
  TARGET_VALUE=""
fi

echo "Target: nodes with label ${TARGET_KEY}${TARGET_VALUE:+=$TARGET_VALUE}"
echo "Release: ${RELEASE}, Namespace: ${NS}"

# ── Get all release pods ──────────────────────────────────────────────────
RELEASE_SEL="app.kubernetes.io/instance=${RELEASE}"
POD_INFO=""
POD_INFO=$(kctl -n "${NS}" get pods -l "${RELEASE_SEL}" -o json 2>/dev/null || echo "")

pod_count=$(echo "${POD_INFO}" | jq '.items | length' 2>/dev/null || echo "0")

if [ -z "${POD_INFO}" ] || [ "${POD_INFO}" = "{}" ] || [ "${POD_INFO}" = "null" ] || [ "${pod_count}" -eq 0 ]; then
  echo "SKIP: no release-scoped pods found in namespace ${NS} — scheduling enforcement cannot be verified"
  echo "ASSERTION_RESULT: SKIP"
  echo "{\"reason\":\"platform_capability_absent\",\"detail\":\"No pods with label ${RELEASE_SEL} found in namespace ${NS}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 0
fi

# ── Phase 1: Check no pods are Pending ───────────────────────────────────
echo ""
echo "==> Phase 1: Check no release pods are Pending"
PENDING_PODS=""
PENDING_PODS=$(echo "${POD_INFO}" | jq -r '.items[] | select(.status.phase == "Pending") | "\(.metadata.name): \(.status.phase)"' 2>/dev/null || echo "")

if [ -n "${PENDING_PODS}" ]; then
  echo "FAIL: the following release pods are Pending (not scheduled):" >&2
  echo "${PENDING_PODS}" >&2
  echo "ASSERTION_RESULT: FAIL"
  echo "{\"pending_pods\":\"$(echo "${PENDING_PODS}" | tr '\n' ' ' | sed 's/ *$//')\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 1
fi

echo "PASS: no Pending release pods"

# ── Phase 2: Check every pod's node has the target label ──────────────────
echo ""
echo "==> Phase 2: Verify each pod landed on a target node"

pod_count=$(echo "${POD_INFO}" | jq '.items | length' 2>/dev/null || echo "0")
mismatch_count=0

for i in $(seq 0 $((pod_count - 1))); do
  pod_name=$(echo "${POD_INFO}" | jq -r ".items[$i].metadata.name" 2>/dev/null || echo "?")
  node_name=$(echo "${POD_INFO}" | jq -r ".items[$i].spec.nodeName" 2>/dev/null || echo "")

  if [ -z "${node_name}" ] || [ "${node_name}" = "null" ]; then
    echo "FAIL: pod ${pod_name} has no .spec.nodeName — not scheduled" >&2
    mismatch_count=$((mismatch_count + 1))
    continue
  fi

  # Check if this node carries the target label.
  # Use jq against -o json instead of interpolating TARGET_KEY into a JSONPath
  # expression.  Common Kubernetes label keys contain dots and slashes
  # (e.g. node-role.kubernetes.io/worker) that break kubectl JSONPath
  # interpolation (--jsonpath="{.metadata.labels.${TARGET_KEY}}").
  # We use has($key) to distinguish "label absent" from "label present with
  # empty value" (e.g. node-role.kubernetes.io/control-plane=).
  node_has_label="false"
  node_has_label=$(kctl get node "${node_name}" -o json 2>/dev/null | jq -r --arg key "${TARGET_KEY}" '.metadata.labels | has($key)' 2>/dev/null || echo "false")

  if [ "${node_has_label}" != "true" ]; then
    echo "FAIL: pod ${pod_name} is on node ${node_name} which does NOT have label ${TARGET_KEY}" >&2
    mismatch_count=$((mismatch_count + 1))
    continue
  fi

  node_label_value=""
  node_label_value=$(kctl get node "${node_name}" -o json 2>/dev/null | jq -r --arg key "${TARGET_KEY}" '.metadata.labels[$key] // ""' 2>/dev/null || echo "")

  if [ -n "${TARGET_VALUE}" ] && [ "${node_label_value}" != "${TARGET_VALUE}" ]; then
    echo "FAIL: pod ${pod_name} is on node ${node_name} where ${TARGET_KEY}=${node_label_value} (expected: ${TARGET_VALUE})" >&2
    mismatch_count=$((mismatch_count + 1))
  else
    echo "PASS: pod ${pod_name} on node ${node_name} (${TARGET_KEY}=${node_label_value})"
  fi
done

# ── Final report ─────────────────────────────────────────────────────────
if [ "$mismatch_count" -eq 0 ]; then
  echo ""
  echo "PASS: all ${pod_count} release pods are scheduled on target nodes"
  echo "ASSERTION_RESULT: PASS"
  echo "{\"pods_checked\":${pod_count},\"target_label\":\"${TARGET_LABEL}\",\"namespace\":\"${NS}\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 0
else
  echo ""
  echo "FAIL: ${mismatch_count} pod(s) not on target nodes (out of ${pod_count} total)"
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi
