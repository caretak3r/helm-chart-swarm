#!/usr/bin/env bash
# Build a JSON profile of a Helm chart for feasibility analysis.
#
# Usage: introspect-chart.sh <chart_dir>
# Output (stdout): JSON conforming to the shape documented in SKILL.md phase 5.
#
# This is a HEURISTIC scan — it answers questions like "is this pod template's
# volumes block driven by .Values?" via grep, not full Go-template evaluation.
# Good enough for feasibility verdicts; never substitutes for a real helm install.
set -euo pipefail

CHART_DIR="${1:?usage: introspect-chart.sh <chart_dir>}"
[ -d "$CHART_DIR/templates" ] || { echo "ERROR: no templates/ in $CHART_DIR" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }

# Parse Chart.yaml name/version
if command -v yq >/dev/null 2>&1; then
  name=$(yq    '.name'    "$CHART_DIR/Chart.yaml")
  version=$(yq '.version' "$CHART_DIR/Chart.yaml")
else
  name=$(grep -E '^name:'    "$CHART_DIR/Chart.yaml" | head -1 | awk '{print $2}' | tr -d '"')
  version=$(grep -E '^version:' "$CHART_DIR/Chart.yaml" | head -1 | awk '{print $2}' | tr -d '"')
fi

# Top-level value keys (best-effort)
values_keys_json="[]"
if [ -f "$CHART_DIR/values.yaml" ]; then
  if command -v yq >/dev/null 2>&1; then
    values_keys_json=$(yq -o=json '. | keys' "$CHART_DIR/values.yaml" 2>/dev/null || echo "[]")
  fi
fi

# TLS-ish references anywhere under templates/ or values.yaml
tls_refs=false
if grep -RIE -l 'tls|cert-manager|cacert|Certificate' "$CHART_DIR" >/dev/null 2>&1; then
  tls_refs=true
fi

# Already has helm tests?
already_has_tests=false
if [ -d "$CHART_DIR/templates/tests" ] && [ -n "$(ls -A "$CHART_DIR/templates/tests" 2>/dev/null)" ]; then
  already_has_tests=true
fi

# Per-template analysis
pod_kinds=()
templates_buf="["
first=1
while IFS= read -r f; do
  [ -f "$f" ] || continue
  rel="${f#"$CHART_DIR"/}"

  # Extract the first `kind:` value (skip Helm conditionals)
  kind=$(grep -E '^kind:' "$f" | head -1 | awk '{print $2}' | tr -d '"')
  case "$kind" in
    Deployment|StatefulSet|DaemonSet|Job|CronJob|ReplicaSet) ;;
    *) continue ;;
  esac
  pod_kinds+=("$kind")

  has_volumes=$(grep -qE '^\s*volumes:'      "$f" && echo true || echo false)
  has_mounts=$(grep  -qE '^\s*volumeMounts:' "$f" && echo true || echo false)
  vols_value_driven=$(awk '/^[[:space:]]*volumes:/,/^[^[:space:]]/' "$f" | grep -q '{{' && echo true || echo false)
  mounts_value_driven=$(awk '/^[[:space:]]*volumeMounts:/,/^[^[:space:]]/' "$f" | grep -q '{{' && echo true || echo false)
  pod_ann_value_driven=$(grep -qE 'podAnnotations|template:.*\{\{|annotations:.*\{\{' "$f" && echo true || echo false)
  pod_lbl_value_driven=$(grep -qE 'podLabels|labels:[^}]*\{\{' "$f" && echo true || echo false)
  env_value_driven=$(awk '/^[[:space:]]*env:/,/^[[:space:]]*[a-zA-Z]/' "$f" | grep -q '{{' && echo true || echo false)
  host_network=$(grep -qE '^\s*hostNetwork:\s*true' "$f" && echo true || echo false)

  entry=$(jq -n \
    --arg path "$rel" \
    --arg kind "$kind" \
    --argjson hv "$has_volumes" \
    --argjson vd "$vols_value_driven" \
    --argjson hm "$has_mounts" \
    --argjson md "$mounts_value_driven" \
    --argjson av "$pod_ann_value_driven" \
    --argjson lv "$pod_lbl_value_driven" \
    --argjson ev "$env_value_driven" \
    --argjson hn "$host_network" \
    '{
      path: $path,
      kind: $kind,
      has_volumes_block:           $hv,
      volumes_value_driven:        $vd,
      has_volume_mounts:           $hm,
      volume_mounts_value_driven:  $md,
      pod_annotations_value_driven: $av,
      pod_labels_value_driven:     $lv,
      env_value_driven:            $ev,
      host_network:                $hn
    }')
  if [ $first -eq 1 ]; then
    templates_buf="${templates_buf}${entry}"
    first=0
  else
    templates_buf="${templates_buf},${entry}"
  fi
done < <(find "$CHART_DIR/templates" -type f \( -name "*.yaml" -o -name "*.yml" \) | sort)
templates_buf="${templates_buf}]"

# Dedup pod_kinds
pod_kinds_json="[]"
if [ ${#pod_kinds[@]} -gt 0 ]; then
  pod_kinds_json=$(printf '%s\n' "${pod_kinds[@]}" | sort -u | jq -R . | jq -s .)
fi

jq -n \
  --arg cd "$CHART_DIR" \
  --arg n "$name" \
  --arg v "$version" \
  --argjson pk "$pod_kinds_json" \
  --argjson tpls "$templates_buf" \
  --argjson aht "$already_has_tests" \
  --argjson tls "$tls_refs" \
  --argjson vk "$values_keys_json" \
  '{
    chart_dir: $cd,
    name: $n,
    version: $v,
    pod_owning_kinds: $pk,
    templates: $tpls,
    already_has_helm_tests: $aht,
    tls_references_found: $tls,
    values_keys: $vk
  }'
