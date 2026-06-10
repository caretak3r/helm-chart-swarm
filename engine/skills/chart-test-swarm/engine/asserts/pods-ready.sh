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

# Build a temp probe script for wait_with_backoff eval.
# The probe checks that ALL release-scoped pods have Ready=True.
_probe_file=$(mktemp /tmp/ct-pods-ready-probe.XXXXXX)
# Cleanup on exit (append to existing trap)
trap 'rm -f "$_probe_file"' EXIT

# Write kubectl args (if any) and selector into the probe file as env vars
printf 'KUBECTL_ARGS="%s"\n' "${kubectl_args[*]}" > "$_probe_file"
printf 'NS="%s"\n' "$NS" >> "$_probe_file"
printf 'SEL="%s"\n' "$SEL" >> "$_probe_file"

# Probe: source the env file, then check pod readiness
probe_cmd="source $_probe_file 2>/dev/null; ready=\$(kubectl \$KUBECTL_ARGS get pods -n \"\$NS\" -l \"\$SEL\" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}{end}' 2>/dev/null || echo ''); total=\$(kubectl \$KUBECTL_ARGS get pods -n \"\$NS\" -l \"\$SEL\" --no-headers 2>/dev/null | wc -l | tr -d ' '); ready_count=0; for s in \$ready; do [ \"\$s\" = 'True' ] && ready_count=\$((ready_count + 1)); done; [ \"\$ready_count\" -gt 0 ] && [ \"\$ready_count\" -eq \"\$total\" ]"

# Use wait_with_backoff for retry logic with the shared helper
if wait_with_backoff "$probe_cmd" "$RETRIES" "$timeout_sec"; then
  echo "PASS: pods Ready in ns/$NS (selector=$SEL)"
  kubectl "${kubectl_args[@]}" -n "$NS" get pods -l "$SEL" 2>/dev/null || true
  exit 0
fi

echo "FAIL: pods not Ready in ns/$NS within timeout (selector=$SEL)" >&2
kubectl "${kubectl_args[@]}" -n "$NS" get pods -l "$SEL" 2>/dev/null || true
kubectl "${kubectl_args[@]}" -n "$NS" describe pods -l "$SEL" 2>&1 | tail -n 50 || true
exit 1
