#!/usr/bin/env bash
# Assert: all pods in target namespace (optionally matching a label selector)
# reach condition=Ready within timeout.
set -euo pipefail

SCENARIO="$1"; IDX="$2"
NS=$(yq      ".asserts[$IDX].namespace" "$SCENARIO")
SEL=$(yq     ".asserts[$IDX].selector // \"\"" "$SCENARIO")
TIMEOUT=$(yq ".asserts[$IDX].timeout  // \"5m\"" "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

args=(-n "$NS" wait --for=condition=Ready pods --timeout="$TIMEOUT")
if [ -n "$SEL" ] && [ "$SEL" != "null" ]; then
  args+=(-l "$SEL")
else
  args+=(--all)
fi

echo "kubectl ${kubectl_args[*]} ${args[*]}"
if kubectl "${kubectl_args[@]}" "${args[@]}"; then
  echo "PASS: pods Ready in ns/$NS${SEL:+ (selector=$SEL)}"
  kubectl "${kubectl_args[@]}" -n "$NS" get pods ${SEL:+ -l "$SEL"}
  exit 0
fi

echo "FAIL: pods not Ready in ns/$NS within $TIMEOUT" >&2
kubectl "${kubectl_args[@]}" -n "$NS" get pods ${SEL:+ -l "$SEL"} || true
kubectl "${kubectl_args[@]}" -n "$NS" describe pods ${SEL:+ -l "$SEL"} 2>&1 | tail -n 50 || true
exit 1
