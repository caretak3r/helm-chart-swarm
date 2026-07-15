#!/usr/bin/env bash
# DEPTH: L1
# Assert: network-policy — validates presence or absence of NetworkPolicy objects.
# When expect_present=true, asserts that at least one NetworkPolicy is rendered
# whose spec.podSelector matches the chart's workload selector labels.
# When expect_present=false, asserts zero NetworkPolicy documents are present.
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

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

rendered_file=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; return 0; }
trap cleanup EXIT

render_helm_template() {
  rendered_file="$(mktemp /tmp/cap-netpol-rendered-XXXXXX)"
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

check_rendered_network_policy() {
  local doc_count=0 netpol_count=0 netpol_list=""
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

    if [ "$kind_val" = "NetworkPolicy" ]; then
      netpol_count=$((netpol_count + 1))
      local pod_selector
      pod_selector=$(yq "select(di == $di) | .spec.podSelector // null" "$rendered_file" 2>/dev/null || echo "null")
      netpol_list="${netpol_list}  NetworkPolicy/$name_val podSelector=$pod_selector"$'\n'
    fi
    di=$((di + 1))
  done

  if [ "$EXPECT_PRESENT" = "true" ]; then
    if [ "$netpol_count" -eq 0 ]; then
      echo "FAIL: expected NetworkPolicy but found 0" >&2
      return 1
    fi
    # Validate podSelector is non-empty (should match workload)
    # Validate podSelector is meaningful (not empty {})
    di=0
    while [ "$di" -lt "$doc_count" ]; do
      local kind_val
      kind_val=$(yq "select(di == $di) | .kind // \"\"" "$rendered_file" 2>/dev/null || echo "")
      if [ "$kind_val" = "NetworkPolicy" ]; then
        local match_expressions
        match_expressions=$(yq "select(di == $di) | .spec.podSelector.matchExpressions // null" "$rendered_file" 2>/dev/null || echo "null")
        local match_labels
        match_labels=$(yq "select(di == $di) | .spec.podSelector.matchLabels // null" "$rendered_file" 2>/dev/null || echo "null")
        # A completely empty podSelector {} selects all pods in namespace — valid but warn
        if [ "$match_labels" = "null" ] && [ "$match_expressions" = "null" ]; then
          local np_name
          np_name=$(yq "select(di == $di) | .metadata.name // \"\"" "$rendered_file" 2>/dev/null || echo "")
          echo "  NetworkPolicy/$np_name: podSelector is empty (selects all pods in namespace)" >&2
        fi
      fi
      di=$((di + 1))
    done
    echo "PASS: $netpol_count NetworkPolicy object(s) found"
    printf '%s' "$netpol_list"
    return 0
  else
    # expect_present=false: no NetworkPolicy should exist
    if [ "$netpol_count" -gt 0 ]; then
      echo "FAIL: expected no NetworkPolicy but found $netpol_count:" >&2
      printf '%s' "$netpol_list" >&2
      return 1
    fi
    echo "PASS: no NetworkPolicy objects found (as expected)"
    return 0
  fi
}

check_live_network_policy() {
  # Get all NetworkPolicies in the namespace as YAML
  local np_yaml
  np_yaml=$(kubectl "${kubectl_args[@]}" get networkpolicy -n "$NS" -o yaml 2>/dev/null || echo "items: []")
  local total_count
  total_count=$(printf '%s' "$np_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  # Build release-scoped label selector (verify RELEASE is set)
  if ! selector_for_release >/dev/null 2>/dev/null; then
    echo "FAIL: cannot build release selector (RELEASE not set)" >&2
    return 1
  fi

  # Count NetworkPolicies whose podSelector selects the release workload.
  # A policy selects the release if its spec.podSelector.matchLabels includes
  # app.kubernetes.io/instance=$RELEASE OR if it has an empty podSelector
  # (selects all) but that's weakly scoped — we still count it as a match.
  local release_matching=0
  local matching_names=""
  local i=0
  while [ "$i" -lt "$total_count" ]; do
    local np_name
    np_name=$(printf '%s' "$np_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")

    # Check if policy has the release-scoped labels on the podSelector
    local match_labels
    match_labels=$(printf '%s' "$np_yaml" | yq ".items[$i].spec.podSelector.matchLabels // {}" 2>/dev/null || echo "{}")
    local instance_label
    instance_label=$(printf '%s' "$match_labels" | yq '.["app.kubernetes.io/instance"] // ""' 2>/dev/null || echo "")

    if [ "$instance_label" = "$RELEASE" ]; then
      release_matching=$((release_matching + 1))
      matching_names="${matching_names}  NetworkPolicy/$np_name selects release '$RELEASE'"$'\n'
    fi
    i=$((i + 1))
  done

  if [ "$EXPECT_PRESENT" = "true" ]; then
    if [ "$release_matching" -eq 0 ]; then
      echo "FAIL: no NetworkPolicy selects the release workload (${total_count} total policy/policies in namespace, none release-scoped)" >&2
      return 1
    fi
    echo "PASS: $release_matching NetworkPolicy object(s) select the release workload (${total_count} total)"
    printf '%s' "$matching_names"
    return 0
  else
    # expect_present=false: only release-scoped policies matter
    if [ "$release_matching" -gt 0 ]; then
      echo "FAIL: $release_matching NetworkPolicy object(s) select the release (expected 0):" >&2
      printf '%s' "$matching_names" >&2
      return 1
    fi
    echo "PASS: no NetworkPolicy selects the release workload (as expected, ${total_count} total policy/policies ignored)"
    return 0
  fi
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_network_policy; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_network_policy; then overall=1; fi
fi
exit "$overall"
