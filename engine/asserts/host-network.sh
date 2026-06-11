#!/usr/bin/env bash
# DEPTH: L1
# Assert: host-network — validates presence or absence of hostNetwork on
# workload pod specs.
# When expect_present=true, asserts that every in-scope workload pod spec
# has hostNetwork: true. When check_host_port=true, also verifies that at
# least one container port declares a hostPort.
# When expect_present=false, asserts that no hostNetwork: true (and no
# hostPort when checked) is present on any workload.
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

# Check hostPort knob (default: false)
_raw=$(yq ".asserts[$IDX].check_host_port" "$SCENARIO")
CHECK_HOST_PORT=$([ "$_raw" = "null" ] || [ -z "$_raw" ] && echo "false" || echo "$_raw")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

rendered_file=""
# shellcheck disable=SC2329
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; return 0; }
trap cleanup EXIT

render_helm_template() {
  rendered_file=$(mktemp /tmp/cap-hostnet-rendered.XXXXXX.yaml)
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

check_rendered_host_network() {
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

    local hn_val
    hn_val=$(yq "select(di == $di) | .spec.template.spec.hostNetwork // false" "$rendered_file" 2>/dev/null || echo "false")

    if [ "$EXPECT_PRESENT" = "true" ]; then
      if [ "$CHECK_HOST_PORT" = "true" ]; then
        # When check_host_port=true, hostPort presence satisfies the assert
        # independently of hostNetwork (VAL-CONFIG-041).
        local ctr_count; ctr_count=$(yq "select(di == $di) | .spec.template.spec.containers | length" "$rendered_file" 2>/dev/null || echo "0")
        local ci=0 hostport_found=0
        while [ "$ci" -lt "$ctr_count" ]; do
          local port_count; port_count=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].ports | length" "$rendered_file" 2>/dev/null || echo "0")
          local pi=0
          while [ "$pi" -lt "$port_count" ]; do
            local hp
            hp=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].ports[$pi].hostPort // \"\"" "$rendered_file" 2>/dev/null || echo "")
            if [ -n "$hp" ] && [ "$hp" != "null" ]; then
              hostport_found=1
              break 2
            fi
            pi=$((pi + 1))
          done
          ci=$((ci + 1))
        done
        if [ "$hostport_found" -eq 0 ]; then
          echo "  $kind_val/$name_val: hostPort not found on any container port (hostNetwork=$hn_val)" >&2
          fail_count=$((fail_count + 1))
        fi
      else
        # Only checking hostNetwork (check_host_port=false / default)
        if [ "$hn_val" != "true" ]; then
          echo "  $kind_val/$name_val: hostNetwork is not true (hostNetwork=$hn_val)" >&2
          fail_count=$((fail_count + 1))
        fi
      fi
    else
      # expect_present=false
      if [ "$hn_val" = "true" ]; then
        echo "  $kind_val/$name_val: unexpected hostNetwork=true" >&2
        fail_count=$((fail_count + 1))
      fi
      if [ "$CHECK_HOST_PORT" = "true" ]; then
        local ctr_count; ctr_count=$(yq "select(di == $di) | .spec.template.spec.containers | length" "$rendered_file" 2>/dev/null || echo "0")
        local ci=0 hostport_found=0
        while [ "$ci" -lt "$ctr_count" ]; do
          local port_count; port_count=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].ports | length" "$rendered_file" 2>/dev/null || echo "0")
          local pi=0
          while [ "$pi" -lt "$port_count" ]; do
            local hp
            hp=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].ports[$pi].hostPort // \"\"" "$rendered_file" 2>/dev/null || echo "")
            if [ -n "$hp" ] && [ "$hp" != "null" ]; then
              hostport_found=1
              break 2
            fi
            pi=$((pi + 1))
          done
          ci=$((ci + 1))
        done
        if [ "$hostport_found" -eq 1 ]; then
          echo "  $kind_val/$name_val: unexpected hostPort present" >&2
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
    echo "FAIL: $fail_count hostNetwork check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: hostNetwork present on $workload_count workload(s)"
  else
    echo "PASS: no hostNetwork present on $workload_count workload(s)"
  fi
  return 0
}

check_live_host_network() {
  local fail_count=0 workload_count=0

  # Query all 5 in-scope workload types (not just Deployments)
  local dep_yaml
  dep_yaml=$(kubectl "${kubectl_args[@]}" get deploy,statefulset,daemonset,job,replicaset -n "$NS" -l "app.kubernetes.io/instance=${RELEASE}" -o yaml 2>/dev/null || echo "items: []")
  local dep_count; dep_count=$(printf '%s' "$dep_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  local i=0
  while [ "$i" -lt "$dep_count" ]; do
    local dname kind_val
    dname=$(printf '%s' "$dep_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")
    kind_val=$(printf '%s' "$dep_yaml" | yq ".items[$i].kind // \"\"" 2>/dev/null || echo "")
    workload_count=$((workload_count + 1))

    local hn_val
    hn_val=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.hostNetwork // false" 2>/dev/null || echo "false")

    if [ "$EXPECT_PRESENT" = "true" ]; then
      if [ "$CHECK_HOST_PORT" = "true" ]; then
        # When check_host_port=true, hostPort presence satisfies the assert
        # independently of hostNetwork (VAL-CONFIG-041).
        local ctr_count; ctr_count=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers | length" 2>/dev/null || echo "0")
        local ci=0 hostport_found=0
        while [ "$ci" -lt "$ctr_count" ]; do
          local port_count; port_count=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].ports | length" 2>/dev/null || echo "0")
          local pi=0
          while [ "$pi" -lt "$port_count" ]; do
            local hp
            hp=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].ports[$pi].hostPort // \"\"" 2>/dev/null || echo "")
            if [ -n "$hp" ] && [ "$hp" != "null" ]; then
              hostport_found=1
              break 2
            fi
            pi=$((pi + 1))
          done
          ci=$((ci + 1))
        done
        if [ "$hostport_found" -eq 0 ]; then
          echo "  $kind_val/$dname: hostPort not found on any container port (hostNetwork=$hn_val)" >&2
          fail_count=$((fail_count + 1))
        fi
      else
        # Only checking hostNetwork (check_host_port=false / default)
        if [ "$hn_val" != "true" ]; then
          echo "  $kind_val/$dname: hostNetwork is not true (hostNetwork=$hn_val)" >&2
          fail_count=$((fail_count + 1))
        fi
      fi
    else
      if [ "$hn_val" = "true" ]; then
        echo "  $kind_val/$dname: unexpected hostNetwork=true" >&2
        fail_count=$((fail_count + 1))
      fi
      if [ "$CHECK_HOST_PORT" = "true" ]; then
        local ctr_count; ctr_count=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers | length" 2>/dev/null || echo "0")
        local ci=0 hostport_found=0
        while [ "$ci" -lt "$ctr_count" ]; do
          local port_count; port_count=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].ports | length" 2>/dev/null || echo "0")
          local pi=0
          while [ "$pi" -lt "$port_count" ]; do
            local hp
            hp=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].ports[$pi].hostPort // \"\"" 2>/dev/null || echo "")
            if [ -n "$hp" ] && [ "$hp" != "null" ]; then
              hostport_found=1
              break 2
            fi
            pi=$((pi + 1))
          done
          ci=$((ci + 1))
        done
        if [ "$hostport_found" -eq 1 ]; then
          echo "  $kind_val/$dname: unexpected hostPort present" >&2
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
    echo "FAIL: $fail_count live hostNetwork check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: hostNetwork present on $workload_count live workload(s)"
  else
    echo "PASS: no hostNetwork present on $workload_count live workload(s)"
  fi
  return 0
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_host_network; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_host_network; then overall=1; fi
fi
exit "$overall"
