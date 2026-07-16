#!/usr/bin/env bash
# Static readiness probe for wait_with_backoff.
# Reads scenario-derived values only as environment data.
set -euo pipefail

NS="${CTS_PROBE_NAMESPACE:-}"
SEL="${CTS_PROBE_SELECTOR:-}"

if [ -z "$NS" ] || [ -z "$SEL" ]; then
  echo "probe-pods-ready: CTS_PROBE_NAMESPACE and CTS_PROBE_SELECTOR are required" >&2
  exit 1
fi

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

ready=$(kubectl "${kubectl_args[@]}" get pods -n "$NS" -l "$SEL" \
  -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
  2>/dev/null || echo '')
total=$(kubectl "${kubectl_args[@]}" get pods -n "$NS" -l "$SEL" --no-headers \
  2>/dev/null | wc -l | tr -d ' ')

ready_count=0
for s in $ready; do
  [ "$s" = "True" ] && ready_count=$((ready_count + 1))
done

[ "$ready_count" -gt 0 ] && [ "$ready_count" -eq "$total" ]
