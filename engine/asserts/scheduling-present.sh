#!/usr/bin/env bash
# DEPTH: L1
# Assert: scheduling-present — validates presence or absence of scheduling knobs
# (nodeSelector, tolerations, affinity, topologySpreadConstraints) on workload
# pod specs.
# When expect_present=true, asserts that the configured scheduling fields appear
# on every workload pod spec with the expected values.
# When expect_present=false, asserts that none of the checked scheduling fields
# appear on any workload pod spec.
# Introspects helm template output and/or live kubectl get -o yaml.
# Returns {status: PASS|FAIL, detail} via exit code + stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/assert-helpers.sh
source "$SCRIPT_DIR/lib/assert-helpers.sh"

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
SOURCE=$(yq ".asserts[$IDX].source // \"both\"" "$SCENARIO")
EXPECT_PRESENT=$(yq ".asserts[$IDX].expect_present" "$SCENARIO")
RELEASE="${RELEASE:-$(yq '.product.release' "$SCENARIO")}"

if [ "$EXPECT_PRESENT" != "true" ] && [ "$EXPECT_PRESENT" != "false" ]; then
  echo "FAIL: expect_present must be 'true' or 'false', got '$EXPECT_PRESENT'" >&2
  exit 1
fi

# Which fields to check (default: all true)
# NOTE: yq's // fallback treats boolean false as falsy and replaces it,
# so we must read the raw value and handle null/missing explicitly.
_raw=$(yq ".asserts[$IDX].check_nodeSelector" "$SCENARIO")
CHECK_NODESEL=$([ "$_raw" = "null" ] || [ -z "$_raw" ] && echo "true" || echo "$_raw")
_raw=$(yq ".asserts[$IDX].check_tolerations" "$SCENARIO")
CHECK_TOL=$([ "$_raw" = "null" ] || [ -z "$_raw" ] && echo "true" || echo "$_raw")
_raw=$(yq ".asserts[$IDX].check_affinity" "$SCENARIO")
CHECK_AFF=$([ "$_raw" = "null" ] || [ -z "$_raw" ] && echo "true" || echo "$_raw")
_raw=$(yq ".asserts[$IDX].check_topologySpreadConstraints" "$SCENARIO")
CHECK_TSC=$([ "$_raw" = "null" ] || [ -z "$_raw" ] && echo "true" || echo "$_raw")

# Expected values (from scenario assert config, checked when expect_present=true)
NODESEL_JSON=$(yq ".asserts[$IDX].nodeSelector // {}" -o json "$SCENARIO")
TOLERATIONS_JSON=$(yq ".asserts[$IDX].tolerations // []" -o json "$SCENARIO")
AFFINITY_JSON=$(yq ".asserts[$IDX].affinity // {}" -o json "$SCENARIO")
TSC_JSON=$(yq ".asserts[$IDX].topologySpreadConstraints // []" -o json "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

rendered_file=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; return 0; }
trap cleanup EXIT

render_helm_template() {
  rendered_file="$(mktemp /tmp/cap-sched-rendered-XXXXXX)"
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

# Check a single scheduling field on a workload pod spec.
# Usage: check_field <di> <kind> <name> <field_name> <expect_present>
# field_name is one of: nodeSelector, tolerations, affinity, topologySpreadConstraints
check_field() {
  local di="$1" kind="$2" name="$3" field="$4" expect="$5"
  local actual
  actual=$(yq "select(di == $di) | .spec.template.spec.$field // null" "$rendered_file" 2>/dev/null || echo "null")

  if [ "$expect" = "true" ]; then
    if [ "$actual" = "null" ] || [ -z "$actual" ]; then
      echo "  $kind/$name: missing $field on pod spec" >&2
      return 1
    fi
  else
    if [ "$actual" != "null" ] && [ -n "$actual" ]; then
      echo "  $kind/$name: unexpected $field present on pod spec" >&2
      return 1
    fi
  fi
  return 0
}

check_rendered_scheduling() {
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

    if [ "$EXPECT_PRESENT" = "true" ]; then
      # Check nodeSelector
      if [ "$CHECK_NODESEL" = "true" ]; then
        local ns_actual
        ns_actual=$(yq "select(di == $di) | .spec.template.spec.nodeSelector // null" "$rendered_file" 2>/dev/null || echo "null")
        if [ "$ns_actual" = "null" ] || [ -z "$ns_actual" ]; then
          echo "  $kind_val/$name_val: missing nodeSelector on pod spec" >&2
          fail_count=$((fail_count + 1))
        else
          # Verify specific key-value pairs if configured
          if [ "$NODESEL_JSON" != "{}" ] && [ "$NODESEL_JSON" != "null" ]; then
            while IFS= read -r nkey; do
              local expected_nval
              expected_nval=$(printf '%s' "$NODESEL_JSON" | jq -r --arg k "$nkey" '.[$k]')
              local actual_nval
              actual_nval=$(yq "select(di == $di) | .spec.template.spec.nodeSelector[\"$nkey\"] // \"__ABSENT__\"" "$rendered_file" 2>/dev/null || echo "__ABSENT__")
              if [ "$actual_nval" != "$expected_nval" ]; then
                echo "  $kind_val/$name_val: nodeSelector.$nkey expected=$expected_nval actual=$actual_nval" >&2
                fail_count=$((fail_count + 1))
              fi
            done < <(printf '%s' "$NODESEL_JSON" | jq -r 'keys[]')
          fi
        fi
      fi

      # Check tolerations
      if [ "$CHECK_TOL" = "true" ]; then
        local tol_actual
        tol_actual=$(yq "select(di == $di) | .spec.template.spec.tolerations // null" "$rendered_file" 2>/dev/null || echo "null")
        if [ "$tol_actual" = "null" ] || [ -z "$tol_actual" ]; then
          echo "  $kind_val/$name_val: missing tolerations on pod spec" >&2
          fail_count=$((fail_count + 1))
        else
          # Verify specific toleration entries if configured
          if [ "$TOLERATIONS_JSON" != "[]" ] && [ "$TOLERATIONS_JSON" != "null" ]; then
            local tol_count
            tol_count=$(printf '%s' "$TOLERATIONS_JSON" | jq 'length')
            local ti=0
            while [ "$ti" -lt "$tol_count" ]; do
              local tkey tval
              tkey=$(printf '%s' "$TOLERATIONS_JSON" | jq -r ".[$ti].key // \"\"")
              tval=$(printf '%s' "$TOLERATIONS_JSON" | jq -r ".[$ti].value // \"\"")
              local found
              found=$(yq "select(di == $di) | .spec.template.spec.tolerations[] | select(.key == \"$tkey\") | .key // \"\"" "$rendered_file" 2>/dev/null || echo "")
              if [ "$found" != "$tkey" ]; then
                echo "  $kind_val/$name_val: toleration key='$tkey' not found" >&2
                fail_count=$((fail_count + 1))
              elif [ -n "$tval" ]; then
                local found_val
                found_val=$(yq "select(di == $di) | .spec.template.spec.tolerations[] | select(.key == \"$tkey\") | .value // \"\"" "$rendered_file" 2>/dev/null || echo "")
                if [ "$found_val" != "$tval" ]; then
                  echo "  $kind_val/$name_val: toleration key='$tkey' value expected=$tval actual=$found_val" >&2
                  fail_count=$((fail_count + 1))
                fi
              fi
              ti=$((ti + 1))
            done
          fi
        fi
      fi

      # Check affinity
      if [ "$CHECK_AFF" = "true" ]; then
        local aff_actual
        aff_actual=$(yq "select(di == $di) | .spec.template.spec.affinity // null" "$rendered_file" 2>/dev/null || echo "null")
        if [ "$aff_actual" = "null" ] || [ -z "$aff_actual" ]; then
          echo "  $kind_val/$name_val: missing affinity on pod spec" >&2
          fail_count=$((fail_count + 1))
        else
          # Verify specific affinity keys if configured (top-level: nodeAffinity, podAffinity, podAntiAffinity)
          if [ "$AFFINITY_JSON" != "{}" ] && [ "$AFFINITY_JSON" != "null" ]; then
            while IFS= read -r akey; do
              local aff_present
              aff_present=$(yq "select(di == $di) | .spec.template.spec.affinity.$akey // null" "$rendered_file" 2>/dev/null || echo "null")
              if [ "$aff_present" = "null" ] || [ -z "$aff_present" ]; then
                echo "  $kind_val/$name_val: affinity.$akey expected but absent" >&2
                fail_count=$((fail_count + 1))
              fi
            done < <(printf '%s' "$AFFINITY_JSON" | jq -r 'keys[]')
          fi
        fi
      fi

      # Check topologySpreadConstraints
      if [ "$CHECK_TSC" = "true" ]; then
        local tsc_actual
        tsc_actual=$(yq "select(di == $di) | .spec.template.spec.topologySpreadConstraints // null" "$rendered_file" 2>/dev/null || echo "null")
        if [ "$tsc_actual" = "null" ] || [ -z "$tsc_actual" ]; then
          echo "  $kind_val/$name_val: missing topologySpreadConstraints on pod spec" >&2
          fail_count=$((fail_count + 1))
        else
          # Verify specific constraint entries if configured
          if [ "$TSC_JSON" != "[]" ] && [ "$TSC_JSON" != "null" ]; then
            local tsc_count
            tsc_count=$(printf '%s' "$TSC_JSON" | jq 'length')
            local tci=0
            while [ "$tci" -lt "$tsc_count" ]; do
              local expected_topo_key
              expected_topo_key=$(printf '%s' "$TSC_JSON" | jq -r ".[$tci].topologyKey // \"\"")
              if [ -n "$expected_topo_key" ]; then
                local found_topo
                found_topo=$(yq "select(di == $di) | .spec.template.spec.topologySpreadConstraints[] | select(.topologyKey == \"$expected_topo_key\") | .topologyKey // \"\"" "$rendered_file" 2>/dev/null || echo "")
                if [ "$found_topo" != "$expected_topo_key" ]; then
                  echo "  $kind_val/$name_val: topologySpreadConstraints topologyKey='$expected_topo_key' not found" >&2
                  fail_count=$((fail_count + 1))
                fi
              fi
              tci=$((tci + 1))
            done
          fi
        fi
      fi
    else
      # expect_present=false: no scheduling fields should be present
      if [ "$CHECK_NODESEL" = "true" ]; then
        if ! check_field "$di" "$kind_val" "$name_val" "nodeSelector" "false"; then
          fail_count=$((fail_count + 1))
        fi
      fi
      if [ "$CHECK_TOL" = "true" ]; then
        if ! check_field "$di" "$kind_val" "$name_val" "tolerations" "false"; then
          fail_count=$((fail_count + 1))
        fi
      fi
      if [ "$CHECK_AFF" = "true" ]; then
        if ! check_field "$di" "$kind_val" "$name_val" "affinity" "false"; then
          fail_count=$((fail_count + 1))
        fi
      fi
      if [ "$CHECK_TSC" = "true" ]; then
        if ! check_field "$di" "$kind_val" "$name_val" "topologySpreadConstraints" "false"; then
          fail_count=$((fail_count + 1))
        fi
      fi
    fi
    di=$((di + 1))
  done

  if [ "$workload_count" -eq 0 ]; then
    echo "FAIL: no workload objects found in rendered output" >&2
    return 1
  fi

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count scheduling check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    local fields=""
    [ "$CHECK_NODESEL" = "true" ] && fields="${fields}nodeSelector "
    [ "$CHECK_TOL" = "true" ] && fields="${fields}tolerations "
    [ "$CHECK_AFF" = "true" ] && fields="${fields}affinity "
    [ "$CHECK_TSC" = "true" ] && fields="${fields}topologySpreadConstraints "
    echo "PASS: scheduling fields present on $workload_count workload(s) (${fields%' '})"
  else
    echo "PASS: no scheduling fields present on $workload_count workload(s)"
  fi
  return 0
}

check_live_scheduling() {
  local fail_count=0 workload_count=0

  local dep_yaml
  dep_yaml=$(kubectl "${kubectl_args[@]}" get deploy -n "$NS" -l "app.kubernetes.io/instance=${RELEASE}" -o yaml 2>/dev/null || echo "items: []")
  local dep_count; dep_count=$(printf '%s' "$dep_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  local i=0
  while [ "$i" -lt "$dep_count" ]; do
    local dname
    dname=$(printf '%s' "$dep_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")
    workload_count=$((workload_count + 1))

    if [ "$EXPECT_PRESENT" = "true" ]; then
      if [ "$CHECK_NODESEL" = "true" ]; then
        local ns_actual
        ns_actual=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.nodeSelector // null" 2>/dev/null || echo "null")
        if [ "$ns_actual" = "null" ] || [ -z "$ns_actual" ]; then
          echo "  Deployment/$dname: missing nodeSelector on pod spec" >&2
          fail_count=$((fail_count + 1))
        fi
      fi
      if [ "$CHECK_TOL" = "true" ]; then
        local tol_actual
        tol_actual=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.tolerations // null" 2>/dev/null || echo "null")
        if [ "$tol_actual" = "null" ] || [ -z "$tol_actual" ]; then
          echo "  Deployment/$dname: missing tolerations on pod spec" >&2
          fail_count=$((fail_count + 1))
        fi
      fi
      if [ "$CHECK_AFF" = "true" ]; then
        local aff_actual
        aff_actual=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.affinity // null" 2>/dev/null || echo "null")
        if [ "$aff_actual" = "null" ] || [ -z "$aff_actual" ]; then
          echo "  Deployment/$dname: missing affinity on pod spec" >&2
          fail_count=$((fail_count + 1))
        fi
      fi
      if [ "$CHECK_TSC" = "true" ]; then
        local tsc_actual
        tsc_actual=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.topologySpreadConstraints // null" 2>/dev/null || echo "null")
        if [ "$tsc_actual" = "null" ] || [ -z "$tsc_actual" ]; then
          echo "  Deployment/$dname: missing topologySpreadConstraints on pod spec" >&2
          fail_count=$((fail_count + 1))
        fi
      fi
    else
      # expect_present=false
      if [ "$CHECK_NODESEL" = "true" ]; then
        local ns_actual
        ns_actual=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.nodeSelector // null" 2>/dev/null || echo "null")
        if [ "$ns_actual" != "null" ] && [ -n "$ns_actual" ]; then
          echo "  Deployment/$dname: unexpected nodeSelector present" >&2
          fail_count=$((fail_count + 1))
        fi
      fi
      if [ "$CHECK_TOL" = "true" ]; then
        local tol_actual
        tol_actual=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.tolerations // null" 2>/dev/null || echo "null")
        if [ "$tol_actual" != "null" ] && [ -n "$tol_actual" ]; then
          echo "  Deployment/$dname: unexpected tolerations present" >&2
          fail_count=$((fail_count + 1))
        fi
      fi
      if [ "$CHECK_AFF" = "true" ]; then
        local aff_actual
        aff_actual=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.affinity // null" 2>/dev/null || echo "null")
        if [ "$aff_actual" != "null" ] && [ -n "$aff_actual" ]; then
          echo "  Deployment/$dname: unexpected affinity present" >&2
          fail_count=$((fail_count + 1))
        fi
      fi
      if [ "$CHECK_TSC" = "true" ]; then
        local tsc_actual
        tsc_actual=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.topologySpreadConstraints // null" 2>/dev/null || echo "null")
        if [ "$tsc_actual" != "null" ] && [ -n "$tsc_actual" ]; then
          echo "  Deployment/$dname: unexpected topologySpreadConstraints present" >&2
          fail_count=$((fail_count + 1))
        fi
      fi
    fi
    i=$((i + 1))
  done

  if [ "$workload_count" -eq 0 ]; then
    echo "FAIL: no live workload objects found" >&2
    return 1
  fi

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count live scheduling check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: scheduling fields present on $workload_count live workload(s)"
  else
    echo "PASS: no scheduling fields present on $workload_count live workload(s)"
  fi
  return 0
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_scheduling; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_scheduling; then overall=1; fi
fi
exit "$overall"
