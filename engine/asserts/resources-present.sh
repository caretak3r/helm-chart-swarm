#!/usr/bin/env bash
# DEPTH: L1
# Assert: resources-present — validates presence or absence of resource
# requests/limits on workload containers.
# When expect_present=true, asserts that every workload container carries
# the configured resources.requests and resources.limits values.
# When expect_present=false, asserts that no populated resources block
# is present on any workload container.
# Introspects helm template output and/or live kubectl get -o yaml.
# Returns {status: PASS|FAIL, detail} via exit code + stdout.
set -euo pipefail

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
SOURCE=$(yq ".asserts[$IDX].source // \"both\"" "$SCENARIO")
EXPECT_PRESENT=$(yq ".asserts[$IDX].expect_present" "$SCENARIO")

if [ "$EXPECT_PRESENT" != "true" ] && [ "$EXPECT_PRESENT" != "false" ]; then
  echo "FAIL: expect_present must be 'true' or 'false', got '$EXPECT_PRESENT'" >&2
  exit 1
fi

# Expected resources fields (from scenario assert config)
REQUESTS_JSON=$(yq ".asserts[$IDX].requests // {}" -o json "$SCENARIO")
LIMITS_JSON=$(yq ".asserts[$IDX].limits // {}" -o json "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

rendered_file=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; return 0; }
trap cleanup EXIT

render_helm_template() {
  rendered_file=$(mktemp /tmp/cap-resources-rendered.XXXXXX.yaml)
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

check_rendered_resources() {
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
      # Check each container for resources block
      local ctr_count
      ctr_count=$(yq "select(di == $di) | .spec.template.spec.containers | length" "$rendered_file" 2>/dev/null || echo "0")
      local ci=0
      while [ "$ci" -lt "$ctr_count" ]; do
        local ctr_name
        ctr_name=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].name // \"container-$ci\"" "$rendered_file" 2>/dev/null || echo "container-$ci")

        # Check if resources block exists at all
        local res_present
        res_present=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].resources // null" "$rendered_file" 2>/dev/null || echo "null")
        if [ "$res_present" = "null" ] || [ -z "$res_present" ]; then
          echo "  $kind_val/$name_val container/$ctr_name: missing resources block" >&2
          fail_count=$((fail_count + 1))
        else
          # Check requests if configured
          if [ "$REQUESTS_JSON" != "{}" ] && [ "$REQUESTS_JSON" != "null" ]; then
            while IFS= read -r rkey; do
              local expected_rval
              expected_rval=$(printf '%s' "$REQUESTS_JSON" | jq -r --arg k "$rkey" '.[$k]')
              local actual_rval
              actual_rval=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].resources.requests[\"$rkey\"] // \"__ABSENT__\"" "$rendered_file" 2>/dev/null || echo "__ABSENT__")
              if [ "$actual_rval" != "$expected_rval" ]; then
                echo "  $kind_val/$name_val container/$ctr_name: resources.requests.$rkey expected=$expected_rval actual=$actual_rval" >&2
                fail_count=$((fail_count + 1))
              fi
            done < <(printf '%s' "$REQUESTS_JSON" | jq -r 'keys[]')
          fi

          # Check limits if configured
          if [ "$LIMITS_JSON" != "{}" ] && [ "$LIMITS_JSON" != "null" ]; then
            while IFS= read -r lkey; do
              local expected_lval
              expected_lval=$(printf '%s' "$LIMITS_JSON" | jq -r --arg k "$lkey" '.[$k]')
              local actual_lval
              actual_lval=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].resources.limits[\"$lkey\"] // \"__ABSENT__\"" "$rendered_file" 2>/dev/null || echo "__ABSENT__")
              if [ "$actual_lval" != "$expected_lval" ]; then
                echo "  $kind_val/$name_val container/$ctr_name: resources.limits.$lkey expected=$expected_lval actual=$actual_lval" >&2
                fail_count=$((fail_count + 1))
              fi
            done < <(printf '%s' "$LIMITS_JSON" | jq -r 'keys[]')
          fi
        fi
        ci=$((ci + 1))
      done
    else
      # expect_present=false: no populated resources block should be present
      ctr_count=$(yq "select(di == $di) | .spec.template.spec.containers | length" "$rendered_file" 2>/dev/null || echo "0")
      ci=0
      while [ "$ci" -lt "$ctr_count" ]; do
        ctr_name=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].name // \"container-$ci\"" "$rendered_file" 2>/dev/null || echo "container-$ci")
        local res_val
        res_val=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].resources // null" "$rendered_file" 2>/dev/null || echo "null")
        # An empty resources block {} is acceptable for the off-case
        if [ "$res_val" != "null" ] && [ -n "$res_val" ] && [ "$res_val" != "{}" ]; then
          # Check if resources has any non-empty sub-fields
          local has_requests has_limits
          has_requests=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].resources.requests // null" "$rendered_file" 2>/dev/null || echo "null")
          has_limits=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].resources.limits // null" "$rendered_file" 2>/dev/null || echo "null")
          if [ "$has_requests" != "null" ] || [ "$has_limits" != "null" ]; then
            echo "  $kind_val/$name_val container/$ctr_name: unexpected populated resources block" >&2
            fail_count=$((fail_count + 1))
          fi
        fi
        ci=$((ci + 1))
      done
    fi
    di=$((di + 1))
  done

  if [ "$workload_count" -eq 0 ]; then
    echo "FAIL: no workload objects found in rendered output" >&2
    return 1
  fi

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count resources check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: resources requests/limits present on $workload_count workload(s)"
  else
    echo "PASS: no populated resources blocks on $workload_count workload(s)"
  fi
  return 0
}

check_live_resources() {
  local fail_count=0 workload_count=0

  local dep_yaml
  dep_yaml=$(kubectl "${kubectl_args[@]}" get deploy -n "$NS" -o yaml 2>/dev/null || echo "items: []")
  local dep_count; dep_count=$(printf '%s' "$dep_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  local i=0
  while [ "$i" -lt "$dep_count" ]; do
    local dname
    dname=$(printf '%s' "$dep_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")
    workload_count=$((workload_count + 1))

    local ctr_count; ctr_count=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers | length" 2>/dev/null || echo "0")
    local ci=0
    while [ "$ci" -lt "$ctr_count" ]; do
      local ctr_name; ctr_name=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].name // \"container-$ci\"" 2>/dev/null || echo "container-$ci")

      if [ "$EXPECT_PRESENT" = "true" ]; then
        local res_present
        res_present=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].resources // null" 2>/dev/null || echo "null")
        if [ "$res_present" = "null" ] || [ -z "$res_present" ]; then
          echo "  Deployment/$dname container/$ctr_name: missing resources block" >&2
          fail_count=$((fail_count + 1))
        fi
      else
        local res_val
        res_val=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].resources // null" 2>/dev/null || echo "null")
        if [ "$res_val" != "null" ] && [ -n "$res_val" ] && [ "$res_val" != "{}" ]; then
          local has_requests has_limits
          has_requests=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].resources.requests // null" 2>/dev/null || echo "null")
          has_limits=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].resources.limits // null" 2>/dev/null || echo "null")
          if [ "$has_requests" != "null" ] || [ "$has_limits" != "null" ]; then
            echo "  Deployment/$dname container/$ctr_name: unexpected populated resources block" >&2
            fail_count=$((fail_count + 1))
          fi
        fi
      fi
      ci=$((ci + 1))
    done
    i=$((i + 1))
  done

  if [ "$workload_count" -eq 0 ]; then
    echo "FAIL: no live workload objects found" >&2
    return 1
  fi

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count live resources check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: resources present on $workload_count live workload(s)"
  else
    echo "PASS: no populated resources blocks on $workload_count live workload(s)"
  fi
  return 0
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_resources; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_resources; then overall=1; fi
fi
exit "$overall"
