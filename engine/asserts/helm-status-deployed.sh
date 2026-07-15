#!/usr/bin/env bash
# DEPTH: L1
# Assert: `helm status <release> -n <ns>` reports STATUS=deployed.
set -euo pipefail

SCENARIO="$1"; IDX="$2"
REL=$(yq ".asserts[$IDX].release"   "$SCENARIO")
NS=$(yq  ".asserts[$IDX].namespace" "$SCENARIO")

helm_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  helm_args+=(--kube-context "$KUBE_CONTEXT")
fi

status="$(helm "${helm_args[@]}" status "$REL" -n "$NS" -o json 2>&1 | jq -r '.info.status // empty')"
echo "helm status: $status"

if [ "$status" = "deployed" ]; then
  echo "PASS: release $REL in ns/$NS is deployed"
  exit 0
fi
echo "FAIL: release $REL in ns/$NS status='$status' (expected deployed)" >&2
helm "${helm_args[@]}" history "$REL" -n "$NS" 2>&1 | tail -n 10 || true
exit 1
