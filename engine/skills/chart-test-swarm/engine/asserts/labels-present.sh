#!/usr/bin/env bash
# DEPTH: L1
# Assert: labels-present — every rendered/live object carries the configured
# extra labels. Introspects helm template output and/or live kubectl get -o yaml.
# Returns {status: PASS|FAIL, detail} via exit code + stdout.
set -euo pipefail

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
SOURCE=$(yq ".asserts[$IDX].source // \"both\"" "$SCENARIO")
LABELS_JSON=$(yq ".asserts[$IDX].labels" -o json "$SCENARIO")
KINDS_JSON=$(yq ".asserts[$IDX].kinds // null" -o json "$SCENARIO")

if [ "$LABELS_JSON" = "null" ] || [ -z "$LABELS_JSON" ] || [ "$LABELS_JSON" = "{}" ]; then
  echo "FAIL: no labels specified in assert config" >&2
  exit 1
fi

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

label_keys()  { printf '%s' "$LABELS_JSON" | jq -r 'keys[]'; }
label_value() { printf '%s' "$LABELS_JSON" | jq -r --arg k "$1" '.[$k]'; }

rendered_file=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; return 0; }
trap cleanup EXIT

render_helm_template() {
  rendered_file="$(mktemp /tmp/cap-lbl-rendered-XXXXXX)"
  mv "$rendered_file" "${rendered_file}.yaml"
  rendered_file="${rendered_file}.yaml"
  local chart release product_ns values_file set_json
  chart=$(yq '.product.chart' "$SCENARIO")
  release=$(yq '.product.release' "$SCENARIO")
  product_ns=$(yq '.product.namespace' "$SCENARIO")
  values_file=$(yq '.product.values // ""' "$SCENARIO")
  set_json=$(yq '.product.set // {}' -o json "$SCENARIO")
  local helm_args=(template "$release" "$chart" -n "$product_ns")
  case "$chart" in oci://*) ;; /*) ;; *) chart="${PROJECT_DIR:-$PWD}/$chart"; helm_args=(template "$release" "$chart" -n "$product_ns") ;; esac
  if [ -n "$values_file" ] && [ "$values_file" != "null" ] && [ "$values_file" != "" ]; then
    case "$values_file" in /*) helm_args+=(-f "$values_file") ;; *) helm_args+=(-f "${PROJECT_DIR:-$PWD}/$values_file") ;; esac
  fi
  if [ "$set_json" != "{}" ] && [ "$set_json" != "null" ]; then
    while IFS='=' read -r skey sval; do helm_args+=(--set "$skey=$sval"); done < <(printf '%s' "$set_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
  fi
  helm "${helm_args[@]}" > "$rendered_file" 2>/dev/null || echo "" > "$rendered_file"
}

kind_matches_filter() {
  local kind="$1"
  if [ "$KINDS_JSON" = "null" ]; then return 0; fi  # no filter
  # Exact kind match (not substring): check if kind is in the JSON array
  # using jq 'any(. == $k)' for exact string equality.
  local match; match=$(printf '%s' "$KINDS_JSON" | jq -r --arg k "$kind" 'any(.[]; . == $k)')
  [ "$match" = "true" ]
}

check_rendered_labels() {
  local fail_count=0 doc_count=0

  # Count documents: yq outputs one kind per doc, with '---' separators
  doc_count=$(yq '.kind // ""' "$rendered_file" 2>/dev/null | grep -cv '^$\|^null$\|^---$')

  if [ "$doc_count" -eq 0 ]; then
    echo "FAIL: no documents found in rendered output" >&2
    return 1
  fi

  local di=0
  while [ "$di" -lt "$doc_count" ]; do
    local kind_val name_val
    kind_val=$(yq "select(di == $di) | .kind // \"\"" "$rendered_file" 2>/dev/null || echo "")
    name_val=$(yq "select(di == $di) | .metadata.name // \"\"" "$rendered_file" 2>/dev/null || echo "")

    # Skip empty/null documents
    if [ -z "$kind_val" ] || [ "$kind_val" = "null" ]; then
      di=$((di + 1))
      continue
    fi

    # Check kinds filter
    if ! kind_matches_filter "$kind_val"; then
      di=$((di + 1))
      continue
    fi

    while IFS= read -r lkey; do
      local expected_val
      expected_val=$(label_value "$lkey")
      local found=0

      # Check .metadata.labels
      local meta_val
      meta_val=$(yq "select(di == $di) | .metadata.labels[\"$lkey\"] // \"\"" "$rendered_file" 2>/dev/null || echo "")
      if [ "$meta_val" = "$expected_val" ]; then
        found=1
      fi

      # Check .spec.template.metadata.labels for workload kinds
      case "$kind_val" in
        Deployment|StatefulSet|DaemonSet|Job|ReplicaSet)
          local tpl_val
          tpl_val=$(yq "select(di == $di) | .spec.template.metadata.labels[\"$lkey\"] // \"__ABSENT__\"" "$rendered_file" 2>/dev/null || echo "__ABSENT__")
          if [ "$tpl_val" = "$expected_val" ]; then
            found=1
          fi
          ;;
      esac

      if [ "$found" -eq 0 ]; then
        echo "  missing label '$lkey=$expected_val' on $kind_val/$name_val (metadata=$meta_val)" >&2
        fail_count=$((fail_count + 1))
      fi
    done < <(label_keys)

    di=$((di + 1))
  done

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count label check(s) failed across $doc_count rendered objects" >&2
    return 1
  fi
  echo "PASS: all $doc_count rendered objects carry expected labels"
  return 0
}

check_live_labels() {
  local fail_count=0 obj_count=0
  local query_kinds
  if [ "$KINDS_JSON" != "null" ]; then
    query_kinds=$(printf '%s' "$KINDS_JSON" | jq -r '.[]' | tr '\n' ',' | sed 's/,$//')
  else
    query_kinds="deployment,service,configmap,ingress,networkpolicy,serviceaccount,role,rolebinding"
  fi
  local live_yaml
  live_yaml=$(kubectl "${kubectl_args[@]}" get "$query_kinds" -n "$NS" -o yaml 2>/dev/null || echo "items: []")
  obj_count=$(printf '%s' "$live_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  local i=0
  while [ "$i" -lt "$obj_count" ]; do
    local kind name
    kind=$(printf '%s' "$live_yaml" | yq ".items[$i].kind // \"\"" 2>/dev/null || echo "")
    name=$(printf '%s' "$live_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")

    if ! kind_matches_filter "$kind"; then
      i=$((i + 1)); continue
    fi

    while IFS= read -r lkey; do
      local expected_val found=0
      expected_val=$(label_value "$lkey")
      local meta_val
      meta_val=$(printf '%s' "$live_yaml" | yq ".items[$i].metadata.labels[\"$lkey\"] // \"\"" 2>/dev/null || echo "")
      [ "$meta_val" = "$expected_val" ] && found=1
      case "$kind" in Deployment|StatefulSet|DaemonSet|Job|ReplicaSet)
        local tpl_val
        tpl_val=$(printf '%s' "$live_yaml" | yq ".items[$i].spec.template.metadata.labels[\"$lkey\"] // \"__ABSENT__\"" 2>/dev/null || echo "__ABSENT__")
        [ "$tpl_val" = "$expected_val" ] && found=1 ;; esac
      if [ "$found" -eq 0 ]; then
        echo "  missing label '$lkey=$expected_val' on $kind/$name" >&2
        fail_count=$((fail_count + 1))
      fi
    done < <(label_keys)
    i=$((i + 1))
  done

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count live label check(s) failed across $obj_count objects" >&2
    return 1
  fi
  echo "PASS: all $obj_count live objects carry expected labels"
  return 0
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_labels; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_labels; then overall=1; fi
fi
exit "$overall"
