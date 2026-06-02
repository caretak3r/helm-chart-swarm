#!/usr/bin/env bash
# Assert: configured label keys are ABSENT from every rendered object.
# This is the OFF-case complement to labels-present — verifies no extra
# label keys leak when the global label knob is unset.
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
CHART_DIR="${PROJECT_DIR:-$(pwd)}/chart"

# Keys that must NOT appear on any rendered object
ABSENT_KEYS=("team" "cost-center")

rendered_file=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; }
trap cleanup EXIT

rendered_file=$(mktemp /tmp/cap-lbl-absent.XXXXXX.yaml)
helm template "$RELEASE" "$CHART_DIR" -n "$NS" \
  --set ingress.enabled=true \
  > "$rendered_file" 2>/dev/null || true

if [ ! -s "$rendered_file" ]; then
  echo "FAIL: helm template produced no output" >&2
  exit 1
fi

doc_count=$(yq '.kind // ""' "$rendered_file" 2>/dev/null | grep -cv '^$\|^null$\|^---$')
if [ "$doc_count" -eq 0 ]; then
  echo "FAIL: no documents found in rendered output" >&2
  exit 1
fi

fail_count=0
di=0
while [ "$di" -lt "$doc_count" ]; do
  kind_val=$(yq "select(di == $di) | .kind // \"\"" "$rendered_file" 2>/dev/null || echo "")
  name_val=$(yq "select(di == $di) | .metadata.name // \"\"" "$rendered_file" 2>/dev/null || echo "")

  if [ -z "$kind_val" ] || [ "$kind_val" = "null" ]; then
    di=$((di + 1)); continue
  fi

  for akey in "${ABSENT_KEYS[@]}"; do
    # Check .metadata.labels
    meta_val=$(yq "select(di == $di) | .metadata.labels[\"$akey\"] // \"\"" "$rendered_file" 2>/dev/null || echo "")
    if [ -n "$meta_val" ] && [ "$meta_val" != "" ]; then
      echo "  unexpected label '$akey' on $kind_val/$name_val (metadata value=$meta_val)" >&2
      fail_count=$((fail_count + 1))
    fi

    # Check .spec.template.metadata.labels for workload kinds
    case "$kind_val" in
      Deployment|StatefulSet|DaemonSet|Job|ReplicaSet)
        tpl_val=$(yq "select(di == $di) | .spec.template.metadata.labels[\"$akey\"] // \"\"" "$rendered_file" 2>/dev/null || echo "")
        if [ -n "$tpl_val" ] && [ "$tpl_val" != "" ]; then
          echo "  unexpected label '$akey' on $kind_val/$name_val pod-template (value=$tpl_val)" >&2
          fail_count=$((fail_count + 1))
        fi
        ;;
    esac
  done
  di=$((di + 1))
done

if [ "$fail_count" -gt 0 ]; then
  echo "FAIL: $fail_count unexpected label(s) found across $doc_count rendered objects" >&2
  exit 1
fi

echo "PASS: all $doc_count rendered objects are free of the configured extra-label keys"
exit 0
