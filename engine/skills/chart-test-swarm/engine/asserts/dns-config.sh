#!/usr/bin/env bash
# DEPTH: L1
# Assert: dns-config — validates presence or absence of dnsPolicy and/or
# dnsConfig on workload pod specs.
# When expect_present=true, asserts that every in-scope workload pod spec
# carries the configured DNS settings (dnsPolicy and/or dnsConfig) per knobs.
# When expect_present=false, asserts that no custom dnsConfig/dnsPolicy is
# present on any workload.
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

# Optional knobs for dnsPolicy and dnsConfig nameservers
DNS_POLICY=$(yq ".asserts[$IDX].dns_policy // \"\"" "$SCENARIO")
_servers_json=$(yq ".asserts[$IDX].nameservers // []" -o json "$SCENARIO" 2>/dev/null || echo "[]")
SERVERS_COUNT=$(printf '%s' "$_servers_json" | jq 'length' 2>/dev/null || echo "0")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

rendered_file=""
# shellcheck disable=SC2329
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; return 0; }
trap cleanup EXIT

render_helm_template() {
  rendered_file=$(mktemp /tmp/cap-dns-rendered.XXXXXX.yaml)
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

check_rendered_dns() {
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
      # Check dnsPolicy if configured
      if [ -n "$DNS_POLICY" ] && [ "$DNS_POLICY" != "null" ]; then
        local actual_policy
        actual_policy=$(yq "select(di == $di) | .spec.template.spec.dnsPolicy // \"\"" "$rendered_file" 2>/dev/null || echo "")
        if [ "$actual_policy" != "$DNS_POLICY" ]; then
          echo "  $kind_val/$name_val: dnsPolicy expected='$DNS_POLICY' actual='${actual_policy:-<unset>}'" >&2
          fail_count=$((fail_count + 1))
        fi
      fi

      # Check dnsConfig.nameservers if configured
      if [ "$SERVERS_COUNT" -gt 0 ]; then
        local dns_config
        dns_config=$(yq "select(di == $di) | .spec.template.spec.dnsConfig // null" "$rendered_file" 2>/dev/null || echo "null")
        if [ "$dns_config" = "null" ] || [ -z "$dns_config" ]; then
          echo "  $kind_val/$name_val: dnsConfig missing (expected nameservers)" >&2
          fail_count=$((fail_count + 1))
        else
          # Check each expected nameserver
          local si=0
          while [ "$si" -lt "$SERVERS_COUNT" ]; do
            local expected_ns
            expected_ns=$(printf '%s' "$_servers_json" | jq -r ".[$si] // \"\"" 2>/dev/null || echo "")
            if [ -n "$expected_ns" ] && [ "$expected_ns" != "null" ]; then
              local found
              found=$(yq "select(di == $di) | .spec.template.spec.dnsConfig.nameservers[] | select(. == \"$expected_ns\") | ." "$rendered_file" 2>/dev/null || echo "")
              if [ -z "$found" ] || [ "$found" = "null" ]; then
                echo "  $kind_val/$name_val: nameserver '$expected_ns' not found in dnsConfig.nameservers" >&2
                fail_count=$((fail_count + 1))
              fi
            fi
            si=$((si + 1))
          done
        fi
      fi

      # If no specific knobs, just check that either dnsPolicy or dnsConfig is set
      if [ -z "$DNS_POLICY" ] || [ "$DNS_POLICY" = "null" ]; then
        if [ "$SERVERS_COUNT" -eq 0 ]; then
          # Generic check: at least one DNS setting should be present
          local dns_config
          dns_config=$(yq "select(di == $di) | .spec.template.spec.dnsConfig // null" "$rendered_file" 2>/dev/null || echo "null")
          local dns_policy
          dns_policy=$(yq "select(di == $di) | .spec.template.spec.dnsPolicy // \"\"" "$rendered_file" 2>/dev/null || echo "")
          if [ "$dns_config" = "null" ] || [ -z "$dns_config" ]; then
            if [ -z "$dns_policy" ] || [ "$dns_policy" = "null" ] || [ "$dns_policy" = "ClusterFirst" ]; then
              # ClusterFirst is default; check if there's explicit DNS config
              echo "  $kind_val/$name_val: no explicit dnsConfig or non-default dnsPolicy" >&2
              fail_count=$((fail_count + 1))
            fi
          fi
        fi
      fi
    else
      # expect_present=false
      local dns_config
      dns_config=$(yq "select(di == $di) | .spec.template.spec.dnsConfig // null" "$rendered_file" 2>/dev/null || echo "null")
      if [ "$dns_config" != "null" ] && [ -n "$dns_config" ]; then
        echo "  $kind_val/$name_val: unexpected dnsConfig present" >&2
        fail_count=$((fail_count + 1))
      fi
      # dnsPolicy: only flag non-default
      local dns_policy
      dns_policy=$(yq "select(di == $di) | .spec.template.spec.dnsPolicy // \"\"" "$rendered_file" 2>/dev/null || echo "")
      if [ -n "$dns_policy" ] && [ "$dns_policy" != "null" ] && [ "$dns_policy" != "ClusterFirst" ]; then
        echo "  $kind_val/$name_val: unexpected non-default dnsPolicy='$dns_policy'" >&2
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
    echo "FAIL: $fail_count DNS config check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: DNS config present on $workload_count workload(s)"
  else
    echo "PASS: no DNS config present on $workload_count workload(s)"
  fi
  return 0
}

check_live_dns() {
  local fail_count=0 workload_count=0

  local dep_yaml
  dep_yaml=$(kubectl "${kubectl_args[@]}" get deploy -n "$NS" -l "app.kubernetes.io/instance=${RELEASE}" -o yaml 2>/dev/null || echo "items: []")
  local dep_count; dep_count=$(printf '%s' "$dep_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  local i=0
  while [ "$i" -lt "$dep_count" ]; do
    local dname; dname=$(printf '%s' "$dep_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")
    workload_count=$((workload_count + 1))

    if [ "$EXPECT_PRESENT" = "true" ]; then
      if [ -n "$DNS_POLICY" ] && [ "$DNS_POLICY" != "null" ]; then
        local actual_policy
        actual_policy=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.dnsPolicy // \"\"" 2>/dev/null || echo "")
        if [ "$actual_policy" != "$DNS_POLICY" ]; then
          echo "  Deployment/$dname: dnsPolicy expected='$DNS_POLICY' actual='${actual_policy:-<unset>}'" >&2
          fail_count=$((fail_count + 1))
        fi
      fi

      if [ "$SERVERS_COUNT" -gt 0 ]; then
        local dns_config
        dns_config=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.dnsConfig // null" 2>/dev/null || echo "null")
        if [ "$dns_config" = "null" ] || [ -z "$dns_config" ]; then
          echo "  Deployment/$dname: dnsConfig missing (expected nameservers)" >&2
          fail_count=$((fail_count + 1))
        else
          local si=0
          while [ "$si" -lt "$SERVERS_COUNT" ]; do
            local expected_ns
            expected_ns=$(printf '%s' "$_servers_json" | jq -r ".[$si] // \"\"" 2>/dev/null || echo "")
            if [ -n "$expected_ns" ] && [ "$expected_ns" != "null" ]; then
              local found
              found=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.dnsConfig.nameservers[] | select(. == \"$expected_ns\") | ." 2>/dev/null || echo "")
              if [ -z "$found" ] || [ "$found" = "null" ]; then
                echo "  Deployment/$dname: nameserver '$expected_ns' not found in dnsConfig.nameservers" >&2
                fail_count=$((fail_count + 1))
              fi
            fi
            si=$((si + 1))
          done
        fi
      fi

      if [ -z "$DNS_POLICY" ] || [ "$DNS_POLICY" = "null" ]; then
        if [ "$SERVERS_COUNT" -eq 0 ]; then
          local dns_config
          dns_config=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.dnsConfig // null" 2>/dev/null || echo "null")
          local dns_policy
          dns_policy=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.dnsPolicy // \"\"" 2>/dev/null || echo "")
          if [ "$dns_config" = "null" ] || [ -z "$dns_config" ]; then
            if [ -z "$dns_policy" ] || [ "$dns_policy" = "null" ] || [ "$dns_policy" = "ClusterFirst" ]; then
              echo "  Deployment/$dname: no explicit dnsConfig or non-default dnsPolicy" >&2
              fail_count=$((fail_count + 1))
            fi
          fi
        fi
      fi
    else
      local dns_config
      dns_config=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.dnsConfig // null" 2>/dev/null || echo "null")
      if [ "$dns_config" != "null" ] && [ -n "$dns_config" ]; then
        echo "  Deployment/$dname: unexpected dnsConfig present" >&2
        fail_count=$((fail_count + 1))
      fi
      local dns_policy
      dns_policy=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.dnsPolicy // \"\"" 2>/dev/null || echo "")
      if [ -n "$dns_policy" ] && [ "$dns_policy" != "null" ] && [ "$dns_policy" != "ClusterFirst" ]; then
        echo "  Deployment/$dname: unexpected non-default dnsPolicy='$dns_policy'" >&2
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
    echo "FAIL: $fail_count live DNS config check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: DNS config present on $workload_count live workload(s)"
  else
    echo "PASS: no DNS config present on $workload_count live workload(s)"
  fi
  return 0
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_dns; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_dns; then overall=1; fi
fi
exit "$overall"
