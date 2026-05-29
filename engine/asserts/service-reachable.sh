#!/usr/bin/env bash
# Assert: HTTP GET against an in-cluster service returns the expected status.
# Runs from an ephemeral curlimages/curl pod in the service's namespace.
set -euo pipefail

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

kubectl "${kubectl_args[@]}" -n "$ns" run "$pod" --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.6.0 --timeout="$TIMEOUT" \
  -- sh -c "curl -sS -o /dev/null -w '%{http_code}' --max-time 30 '$url'" \
  > /tmp/${pod}.out 2>/tmp/${pod}.err || true

code="$(cat /tmp/${pod}.out 2>/dev/null || echo "")"
rm -f /tmp/${pod}.out /tmp/${pod}.err

if [ "$code" = "$EXPECT" ]; then
  echo "PASS: $url returned $code"
  exit 0
fi
echo "FAIL: $url returned '$code', expected $EXPECT" >&2
exit 1
