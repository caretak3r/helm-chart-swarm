#!/usr/bin/env bash
# DEPTH: L2
# Assert: HTTP GET against an in-cluster service returns the expected status.
# Runs from an ephemeral quay.io/curl/curl pod in the service's namespace.
# Uses anchored HTTP status-code parser from the shared helper library.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/assert-helpers.sh
source "$SCRIPT_DIR/lib/assert-helpers.sh"

SCENARIO="$1"; IDX="$2"
SVC=$(yq    ".asserts[$IDX].service" "$SCENARIO")   # form: name.namespace
PORT=$(yq   ".asserts[$IDX].port"    "$SCENARIO")
PATH_=$(yq  ".asserts[$IDX].path // \"/\"" "$SCENARIO")
EXPECT=$(yq ".asserts[$IDX].expect // 200" "$SCENARIO")
TIMEOUT=$(yq ".asserts[$IDX].timeout // \"60s\"" "$SCENARIO")

case "$SVC" in
  *.*) name="${SVC%%.*}"; ns="${SVC#*.}";;
  *)   echo "ERROR: service must be <name>.<namespace>, got '$SVC'" >&2; exit 1;;
esac

url="http://${name}.${ns}.svc.cluster.local:${PORT}${PATH_}"
echo "curl -> $url (expect HTTP $EXPECT)"

pod="ct-probe-$$"
kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

curl_raw=""
kubectl "${kubectl_args[@]}" -n "$ns" run "$pod" --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.20.0 --pod-running-timeout="$TIMEOUT" \
  -- sh -c "curl -sS -o /dev/null -w '%{http_code}' --max-time 30 '$url'" \
  > /tmp/${pod}.out 2>/tmp/${pod}.err || true

curl_raw="$(cat /tmp/${pod}.out 2>/dev/null || echo "")"
rm -f /tmp/${pod}.out /tmp/${pod}.err

# Use anchored HTTP status-code parser from the shared helper library
code=""
if ! code=$(parse_http_code "$curl_raw" 2>/dev/null); then
  echo "FAIL: $url returned '$curl_raw' — could not parse HTTP status code" >&2
  exit 1
fi

if [ "$code" = "$EXPECT" ]; then
  echo "PASS: $url returned $code"
  exit 0
fi
echo "FAIL: $url returned '$code', expected $EXPECT" >&2
exit 1
