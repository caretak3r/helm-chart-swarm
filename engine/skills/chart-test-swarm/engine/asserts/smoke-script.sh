#!/usr/bin/env bash
# Assert: invoke a consumer-owned script. Contract:
#   - script receives RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR via env
#   - exit 0 = PASS, non-zero = FAIL
#   - stdout+stderr captured by run-scenario.sh
set -euo pipefail

SCENARIO="$1"; IDX="$2"
SPATH=$(yq ".asserts[$IDX].path" "$SCENARIO")

# Resolve relative to PROJECT_DIR.
case "$SPATH" in
  /*) abs="$SPATH" ;;
  *)  abs="${PROJECT_DIR:-$PWD}/$SPATH" ;;
esac

[ -f "$abs" ] || { echo "ERROR: smoke script not found: $abs" >&2; exit 1; }
[ -x "$abs" ] || { echo "ERROR: smoke script not executable: $abs" >&2; exit 1; }

echo "exec: $abs (RELEASE=$RELEASE NAMESPACE=$NAMESPACE)"
exec "$abs"
