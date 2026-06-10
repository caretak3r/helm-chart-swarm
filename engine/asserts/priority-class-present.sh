#!/usr/bin/env bash
# DEPTH: L1
# Assert: priority-class-present — validates presence or absence of
# priorityClassName on workload pod specs.
# When expect_present=true, asserts that every workload pod spec carries
# the configured priorityClassName value.
# When expect_present=false, asserts that no workload pod spec carries
# a priorityClassName field.
# Introspects helm template output and/or live kubectl get -o yaml.
# Returns {status: PASS|FAIL, detail} via exit code + stdout.
set -euo pipefail

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
SOURCE=$(yq ".asserts[$IDX].source // \"both\"" "$SCENARIO")
EXPECT_PRESENT=$(yq ".asserts[$IDX].expect_present" "$SCENARIO")
EXPECTED_PC=$(yq ".asserts[$IDX].priority_class_name // \"\"" "$SCENARIO")

if [ "$EXPECT_PRESENT" != "true" ] && [ "$EXPECT_PRESENT" != "false" ]; then
  echo "FAIL: expect_present must be 'true' or 'false', got '$EXPECT_PRESENT'" >&2
  exit 1
fi

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

rendered_file=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; }
trap cleanup EXIT

render_helm_template() {
  rendered_file=$(mktemp /tmp/cap-pc-rendered.XXXXXX.yaml)
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

check_rendered_priority_class() {
  local doc_count=0 fail_count=0 workload_count=0
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

    if [ -z "$kind_val" ] || [ "$kind_val" = "null" ]; then
      di=$((di + 1)); continue
    fi

    # Only check workload kinds
    case "$kind_val" in
      Deployment|StatefulSet|DaemonSet|Job|ReplicaSet)
        workload_count=$((workload_count + 1))
        ;;
      *)
        di=$((di + 1)); continue
        ;;
    esac

    local pc_actual
    pc_actual=$(yq "select(di == $di) | .spec.template.spec.priorityClassName // null" "$rendered_file" 2>/dev/null || echo "null")

    if [ "$EXPECT_PRESENT" = "true" ]; then
      if [ "$pc_actual" = "null" ] || [ -z "$pc_actual" ]; then
        echo "  $kind_val/$name_val: missing priorityClassName on pod spec" >&2
        fail_count=$((fail_count + 1))
      elif [ -n "$EXPECTED_PC" ] && [ "$pc_actual" != "$EXPECTED_PC" ]; then
        echo "  $kind_val/$name_val: priorityClassName expected='$EXPECTED_PC' actual='$pc_actual'" >&2
        fail_count=$((fail_count + 1))
      fi
    else
      if [ "$pc_actual" != "null" ] && [ -n "$pc_actual" ]; then
        echo "  $kind_val/$name_val: unexpected priorityClassName='$pc_actual' present" >&2
        fail_count=$((fail_count + 1))
      fi
    fi
    di=$((di + 1))
  done

  if [ "$workload_count" -eq 0 ]; then
    echo "FAIL: no workload objects found in rendered output" >&2
    return 1
  fi

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count priorityClassName check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: priorityClassName present on $workload_count workload(s)"
  else
    echo "PASS: no priorityClassName on $workload_count workload(s)"
  fi
  return 0
}

check_live_priority_class() {
  local fail_count=0 workload_count=0

  local dep_yaml
  dep_yaml=$(kubectl "${kubectl_args[@]}" get deploy -n "$NS" -o yaml 2>/dev/null || echo "items: []")
  local dep_count; dep_count=$(printf '%s' "$dep_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  local i=0
  while [ "$i" -lt "$dep_count" ]; do
    local dname
    dname=$(printf '%s' "$dep_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")
    workload_count=$((workload_count + 1))

    local pc_actual
    pc_actual=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.priorityClassName // null" 2>/dev/null || echo "null")

    if [ "$EXPECT_PRESENT" = "true" ]; then
      if [ "$pc_actual" = "null" ] || [ -z "$pc_actual" ]; then
        echo "  Deployment/$dname: missing priorityClassName on pod spec" >&2
        fail_count=$((fail_count + 1))
      elif [ -n "$EXPECTED_PC" ] && [ "$pc_actual" != "$EXPECTED_PC" ]; then
        echo "  Deployment/$dname: priorityClassName expected='$EXPECTED_PC' actual='$pc_actual'" >&2
        fail_count=$((fail_count + 1))
      fi
    else
      if [ "$pc_actual" != "null" ] && [ -n "$pc_actual" ]; then
        echo "  Deployment/$dname: unexpected priorityClassName='$pc_actual' present" >&2
        fail_count=$((fail_count + 1))
      fi
    fi
    i=$((i + 1))
  done

  if [ "$workload_count" -eq 0 ]; then
    echo "FAIL: no live workload objects found" >&2
    return 1
  fi

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count live priorityClassName check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: priorityClassName present on $workload_count live workload(s)"
  else
    echo "PASS: no priorityClassName on $workload_count live workload(s)"
  fi
  return 0
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_priority_class; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_priority_class; then overall=1; fi
fi
exit "$overall"
