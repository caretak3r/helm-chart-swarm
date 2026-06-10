#!/usr/bin/env bash
# DEPTH: L1
# Assert: security-context — validates presence or absence of pod-level and
# container-level securityContext fields on workload objects.
# When expect_present=true, asserts that configured podSecurityContext and
# container securityContext fields appear with the specified values.
# When expect_present=false, asserts that no securityContext blocks are present.
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

# Pod-level securityContext fields to check (from scenario assert config or defaults)
POD_SC_JSON=$(yq ".asserts[$IDX].podSecurityContext // {}" -o json "$SCENARIO")
# Container-level securityContext fields to check
CTR_SC_JSON=$(yq ".asserts[$IDX].containerSecurityContext // {}" -o json "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

rendered_file=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; return 0; }
trap cleanup EXIT

render_helm_template() {
  rendered_file=$(mktemp /tmp/cap-secctx-rendered.XXXXXX.yaml)
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

check_rendered_security_context() {
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
      # Check pod-level securityContext
      local pod_sc_present
      pod_sc_present=$(yq "select(di == $di) | .spec.template.spec.securityContext // null" "$rendered_file" 2>/dev/null || echo "null")
      if [ "$pod_sc_present" = "null" ] || [ -z "$pod_sc_present" ]; then
        echo "  $kind_val/$name_val: missing pod-level securityContext" >&2
        fail_count=$((fail_count + 1))
      else
        # Check specific pod-level fields if configured
        if [ "$POD_SC_JSON" != "{}" ] && [ "$POD_SC_JSON" != "null" ]; then
          while IFS= read -r pkey; do
            local expected_pval
            expected_pval=$(printf '%s' "$POD_SC_JSON" | jq -r --arg k "$pkey" '.[$k]')
            local actual_pval
            # Handle nested keys like seccompProfile.type
            if echo "$pkey" | grep -q '\.'; then
              actual_pval=$(yq "select(di == $di) | .spec.template.spec.securityContext | $pkey // \"__ABSENT__\"" "$rendered_file" 2>/dev/null || echo "__ABSENT__")
            else
              actual_pval=$(yq "select(di == $di) | .spec.template.spec.securityContext[\"$pkey\"] // \"__ABSENT__\"" "$rendered_file" 2>/dev/null || echo "__ABSENT__")
            fi
            if [ "$actual_pval" != "$expected_pval" ]; then
              echo "  $kind_val/$name_val: pod securityContext.$pkey expected=$expected_pval actual=$actual_pval" >&2
              fail_count=$((fail_count + 1))
            fi
          done < <(printf '%s' "$POD_SC_JSON" | jq -r 'keys[]')
        fi
      fi

      # Check container-level securityContext on each container
      local ctr_count
      ctr_count=$(yq "select(di == $di) | .spec.template.spec.containers | length" "$rendered_file" 2>/dev/null || echo "0")
      local ci=0
      while [ "$ci" -lt "$ctr_count" ]; do
        local ctr_name
        ctr_name=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].name // \"container-$ci\"" "$rendered_file" 2>/dev/null || echo "container-$ci")
        local ctr_sc_present
        ctr_sc_present=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].securityContext // null" "$rendered_file" 2>/dev/null || echo "null")
        if [ "$ctr_sc_present" = "null" ] || [ -z "$ctr_sc_present" ]; then
          echo "  $kind_val/$name_val container/$ctr_name: missing container-level securityContext" >&2
          fail_count=$((fail_count + 1))
        else
          # Check specific container-level fields if configured
          if [ "$CTR_SC_JSON" != "{}" ] && [ "$CTR_SC_JSON" != "null" ]; then
            while IFS= read -r ckey; do
              local expected_cval
              expected_cval=$(printf '%s' "$CTR_SC_JSON" | jq -r --arg k "$ckey" '.[$k]')
              local actual_cval
              # Handle nested keys like capabilities.drop
              if echo "$ckey" | grep -q '\.'; then
                actual_cval=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].securityContext | $ckey // \"__ABSENT__\"" "$rendered_file" 2>/dev/null || echo "__ABSENT__")
              else
                actual_cval=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].securityContext[\"$ckey\"] // \"__ABSENT__\"" "$rendered_file" 2>/dev/null || echo "__ABSENT__")
              fi
              if [ "$actual_cval" != "$expected_cval" ]; then
                echo "  $kind_val/$name_val container/$ctr_name: securityContext.$ckey expected=$expected_cval actual=$actual_cval" >&2
                fail_count=$((fail_count + 1))
              fi
            done < <(printf '%s' "$CTR_SC_JSON" | jq -r 'keys[]')
          fi
        fi
        ci=$((ci + 1))
      done
    else
      # expect_present=false: no securityContext should be present
      local pod_sc
      pod_sc=$(yq "select(di == $di) | .spec.template.spec.securityContext // null" "$rendered_file" 2>/dev/null || echo "null")
      if [ "$pod_sc" != "null" ] && [ -n "$pod_sc" ]; then
        echo "  $kind_val/$name_val: unexpected pod-level securityContext present" >&2
        fail_count=$((fail_count + 1))
      fi
      # Check each container
      ctr_count=$(yq "select(di == $di) | .spec.template.spec.containers | length" "$rendered_file" 2>/dev/null || echo "0")
      ci=0
      while [ "$ci" -lt "$ctr_count" ]; do
        ctr_name=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].name // \"container-$ci\"" "$rendered_file" 2>/dev/null || echo "container-$ci")
        ctr_sc=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].securityContext // null" "$rendered_file" 2>/dev/null || echo "null")
        if [ "$ctr_sc" != "null" ] && [ -n "$ctr_sc" ]; then
          echo "  $kind_val/$name_val container/$ctr_name: unexpected container-level securityContext present" >&2
          fail_count=$((fail_count + 1))
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
    echo "FAIL: $fail_count securityContext check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: pod-level and container-level securityContext fields present on $workload_count workload(s)"
  else
    echo "PASS: no securityContext blocks present on $workload_count workload(s)"
  fi
  return 0
}

check_live_security_context() {
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
      local pod_sc
      pod_sc=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.securityContext // null" 2>/dev/null || echo "null")
      if [ "$pod_sc" = "null" ] || [ -z "$pod_sc" ]; then
        echo "  Deployment/$dname: missing pod-level securityContext" >&2
        fail_count=$((fail_count + 1))
      fi
      # Check each container
      local ctr_count; ctr_count=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers | length" 2>/dev/null || echo "0")
      local ci=0
      while [ "$ci" -lt "$ctr_count" ]; do
        local ctr_name; ctr_name=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].name // \"container-$ci\"" 2>/dev/null || echo "container-$ci")
        local ctr_sc; ctr_sc=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].securityContext // null" 2>/dev/null || echo "null")
        if [ "$ctr_sc" = "null" ] || [ -z "$ctr_sc" ]; then
          echo "  Deployment/$dname container/$ctr_name: missing container-level securityContext" >&2
          fail_count=$((fail_count + 1))
        fi
        ci=$((ci + 1))
      done
    else
      local pod_sc
      pod_sc=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.securityContext // null" 2>/dev/null || echo "null")
      if [ "$pod_sc" != "null" ] && [ -n "$pod_sc" ]; then
        echo "  Deployment/$dname: unexpected pod-level securityContext present" >&2
        fail_count=$((fail_count + 1))
      fi
      local ctr_count; ctr_count=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers | length" 2>/dev/null || echo "0")
      local ci=0
      while [ "$ci" -lt "$ctr_count" ]; do
        local ctr_name; ctr_name=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].name // \"container-$ci\"" 2>/dev/null || echo "container-$ci")
        local ctr_sc; ctr_sc=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].securityContext // null" 2>/dev/null || echo "null")
        if [ "$ctr_sc" != "null" ] && [ -n "$ctr_sc" ]; then
          echo "  Deployment/$dname container/$ctr_name: unexpected container-level securityContext present" >&2
          fail_count=$((fail_count + 1))
        fi
        ci=$((ci + 1))
      done
    fi
    i=$((i + 1))
  done

  if [ "$workload_count" -eq 0 ]; then
    echo "FAIL: no live workload objects found" >&2
    return 1
  fi

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count live securityContext check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: pod-level and container-level securityContext fields present on $workload_count live workload(s)"
  else
    echo "PASS: no securityContext blocks present on $workload_count live workload(s)"
  fi
  return 0
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_security_context; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_security_context; then overall=1; fi
fi
exit "$overall"
