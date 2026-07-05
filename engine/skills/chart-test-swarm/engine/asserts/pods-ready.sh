#!/usr/bin/env bash
# DEPTH: L2
# Assert: all release-scoped pods reach condition=Ready within timeout.
# Uses wait_with_backoff from the shared helper library, honoring retries.
# Release-scoped via app.kubernetes.io/instance label; falls back to
# an explicit selector from the scenario config.
# Returns {status: PASS|FAIL, detail} via exit code + stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/assert-helpers.sh
source "$SCRIPT_DIR/lib/assert-helpers.sh"

SCENARIO="$1"; IDX="$2"
NS=$(yq      ".asserts[$IDX].namespace" "$SCENARIO")
SEL=$(yq     ".asserts[$IDX].selector // \"\"" "$SCENARIO")
TIMEOUT=$(yq ".asserts[$IDX].timeout  // \"5m\"" "$SCENARIO")
RETRIES=$(yq ".asserts[$IDX].retries  // \"0\"" "$SCENARIO")
RELEASE="${RELEASE:-$(yq '.product.release' "$SCENARIO")}"

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

# Build release-scoped selector: prefer explicit scenario selector,
# else use app.kubernetes.io/instance=$RELEASE
if [ -z "$SEL" ] || [ "$SEL" = "null" ]; then
  if [ -n "${RELEASE:-}" ]; then
    SEL="app.kubernetes.io/instance=${RELEASE}"
  fi
fi

# Convert timeout from Go-style (e.g. "5m") to seconds for wait_with_backoff
timeout_sec=300  # default 5 minutes
case "$TIMEOUT" in
  *s) timeout_sec="${TIMEOUT%s}";;
  *m) timeout_sec=$((${TIMEOUT%m} * 60));;
  *h) timeout_sec=$((${TIMEOUT%h} * 3600));;
  *)   timeout_sec="$TIMEOUT";;  # assume raw seconds
esac

# Validate timeout_sec is numeric
case "$timeout_sec" in
  ''|*[!0-9]*) timeout_sec=300;;
esac

# Check that release pods EXIST before checking readiness.
# This prevents vacuous PASS when zero release pods exist
# (kubectl wait --all returns success on empty set).
echo "Checking for release-scoped pods in ns/$NS (selector=$SEL)..."
pod_count=$(kubectl "${kubectl_args[@]}" get pods -n "$NS" -l "$SEL" -o name 2>/dev/null | wc -l | tr -d ' ')
if [ "$pod_count" -eq 0 ]; then
  echo "FAIL: no matching pods found in ns/$NS with selector '$SEL' — 0 release pods exist" >&2
  exit 1
fi
echo "  Found $pod_count release-scoped pod(s)"

# Use wait_with_backoff for retry logic with the shared helper. Scenario-derived
# values flow to the static probe as environment data, never as shell text.
export CTS_PROBE_NAMESPACE="$NS"
export CTS_PROBE_SELECTOR="$SEL"
if wait_with_backoff "$RETRIES" "$timeout_sec" -- bash "$SCRIPT_DIR/lib/probe-pods-ready.sh"; then
  echo "PASS: pods Ready in ns/$NS (selector=$SEL)"
  kubectl "${kubectl_args[@]}" -n "$NS" get pods -l "$SEL" 2>/dev/null || true
  exit 0
fi

echo "FAIL: pods not Ready in ns/$NS within timeout (selector=$SEL)" >&2
kubectl "${kubectl_args[@]}" -n "$NS" get pods -l "$SEL" 2>/dev/null || true
kubectl "${kubectl_args[@]}" -n "$NS" describe pods -l "$SEL" 2>&1 | tail -n 50 || true
exit 1
