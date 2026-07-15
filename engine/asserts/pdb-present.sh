#!/usr/bin/env bash
# DEPTH: L1
# Assert: pdb-present — validates presence or absence of a PodDisruptionBudget
# that selects the release workload.
# When expect_present=true, asserts that at least one PDB exists whose selector
# matches release workload pod labels.
# When expect_present=false, asserts that no PDB selects the release workload.
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
# shellcheck disable=SC2329
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; return 0; }
trap cleanup EXIT

render_helm_template() {
  rendered_file="$(mktemp /tmp/cap-pdb-rendered-XXXXXX)"
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

check_pdb_selector_matches() {
  # Given a JSON matchLabels set from a PDB spec.selector, check if the
  # PDB selector matches the release workload's pod labels.
  #
  # Kubernetes selector semantics: EVERY label in the PDB selector
  # MUST match a label on the pod. The PDB selector can be a subset
  # of the workload labels — it does NOT need to contain every
  # workload label.
  #
  # Args: $1 = PDB selector matchLabels JSON, $2 = workload pod labels JSON
  # Returns 0 if the PDB selector matches; 1 otherwise.
  local pdb_sel_json="$1"
  local workload_labels_json="$2"

  if [ "$pdb_sel_json" = "{}" ] || [ "$pdb_sel_json" = "null" ]; then
    # Empty PDB selector matches nothing
    return 1
  fi
  if [ "$workload_labels_json" = "{}" ] || [ "$workload_labels_json" = "null" ]; then
    return 1
  fi

  # For every key in the PDB selector, verify it exists AND matches in workload labels
  local all_match=true
  while IFS='=' read -r pdb_key pdb_val; do
    if [ -z "$pdb_key" ]; then continue; fi
    local wl_val
    wl_val=$(printf '%s' "$workload_labels_json" | jq -r --arg k "$pdb_key" '.[$k] // ""' 2>/dev/null || echo "")
    if [ "$wl_val" != "$pdb_val" ]; then
      all_match=false
      break
    fi
  done < <(printf '%s' "$pdb_sel_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')

  if [ "$all_match" = "true" ]; then
    return 0
  fi
  return 1
}

check_rendered_pdb() {
  local doc_count=0 workload_count=0 pdb_found=0
  doc_count=$(yq '.kind // ""' "$rendered_file" 2>/dev/null | grep -cv '^$\|^null$\|^---$')
  if [ "$doc_count" -eq 0 ]; then
    echo "FAIL: no documents found in rendered output" >&2
    return 1
  fi

  # Collect release workload labels first
  local release_labels=""
  local di=0
  while [ "$di" -lt "$doc_count" ]; do
    local kind_val
    kind_val=$(yq "select(di == $di) | .kind // \"\"" "$rendered_file" 2>/dev/null || echo "")
    case "$kind_val" in
      Deployment|StatefulSet|DaemonSet|Job|ReplicaSet)
        workload_count=$((workload_count + 1))
        if [ -z "$release_labels" ]; then
          release_labels=$(yq "select(di == $di) | .spec.selector.matchLabels // {}" -o json "$rendered_file" 2>/dev/null || echo "{}")
        fi
        ;;
    esac
    di=$((di + 1))
  done

  if [ "$workload_count" -eq 0 ]; then
    echo "FAIL: no workload objects found in rendered output" >&2
    return 1
  fi

  # Now check for PDBs
  di=0
  while [ "$di" -lt "$doc_count" ]; do
    local kind_val name_val
    kind_val=$(yq "select(di == $di) | .kind // \"\"" "$rendered_file" 2>/dev/null || echo "")
    name_val=$(yq "select(di == $di) | .metadata.name // \"\"" "$rendered_file" 2>/dev/null || echo "")

    if [ "$kind_val" = "PodDisruptionBudget" ]; then
      pdb_found=$((pdb_found + 1))
      if [ "$EXPECT_PRESENT" = "true" ]; then
        # Check that PDB selector matches the release workload
        local pdb_sel
        pdb_sel=$(yq "select(di == $di) | .spec.selector.matchLabels // {}" -o json "$rendered_file" 2>/dev/null || echo "{}")

        if ! check_pdb_selector_matches "$pdb_sel" "$release_labels"; then
          echo "  PodDisruptionBudget/$name_val: selector does not match release workload labels" >&2
          echo "FAIL: PodDisruptionBudget $name_val selector does not select any release workload" >&2
          return 1
        fi
        echo "PASS: PodDisruptionBudget $name_val selects release workload"
        return 0
      else
        # expect_present=false but PDB present
        echo "  PodDisruptionBudget/$name_val: unexpected PodDisruptionBudget present" >&2
        echo "FAIL: unexpected PodDisruptionBudget present" >&2
        return 1
      fi
    fi
    di=$((di + 1))
  done

  if [ "$EXPECT_PRESENT" = "true" ]; then
    if [ "$pdb_found" -eq 0 ]; then
      echo "FAIL: no PodDisruptionBudget found" >&2
      return 1
    fi
  else
    echo "PASS: no PodDisruptionBudget present"
    return 0
  fi
}

check_live_pdb() {
  local release_sel="app.kubernetes.io/instance=${RELEASE}"

  # Get all PDBs in namespace
  local pdb_yaml
  pdb_yaml=$(kubectl "${kubectl_args[@]}" get pdb -n "$NS" -o yaml 2>/dev/null || echo "items: []")
  local pdb_count; pdb_count=$(printf '%s' "$pdb_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  # Get release workload pod template labels for selector matching
  local workload_labels="{}"
  local dep_yaml
  dep_yaml=$(kubectl "${kubectl_args[@]}" get deploy -n "$NS" -l "$release_sel" -o yaml 2>/dev/null || echo "items: []")
  local dep_count; dep_count=$(printf '%s' "$dep_yaml" | yq '.items | length' 2>/dev/null || echo "0")
  if [ "$dep_count" -gt 0 ]; then
    workload_labels=$(printf '%s' "$dep_yaml" | yq '.items[0].spec.template.metadata.labels // {}' -o json 2>/dev/null || echo "{}")
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    if [ "$pdb_count" -eq 0 ]; then
      echo "FAIL: no PodDisruptionBudget found in namespace $NS" >&2
      return 1
    fi

    # Check each PDB: it must have the release instance label AND its
    # spec.selector must actually match release workload pod labels.
    local di=0 found_matching_pdb=0
    while [ "$di" -lt "$pdb_count" ]; do
      local pdb_name
      pdb_name=$(printf '%s' "$pdb_yaml" | yq ".items[$di].metadata.name // \"\"" 2>/dev/null || echo "")

      # Check release scope via metadata labels
      local pdb_labels
      pdb_labels=$(printf '%s' "$pdb_yaml" | yq ".items[$di].metadata.labels // {}" -o json 2>/dev/null || echo "{}")
      local instance_label
      instance_label=$(printf '%s' "$pdb_labels" | jq -r '.["app.kubernetes.io/instance"] // ""' 2>/dev/null || echo "")

      if [ "$instance_label" != "$RELEASE" ]; then
        di=$((di + 1)); continue
      fi

      # PDB has the release instance label — now verify spec.selector matches
      local pdb_sel
      pdb_sel=$(printf '%s' "$pdb_yaml" | yq ".items[$di].spec.selector.matchLabels // {}" -o json 2>/dev/null || echo "{}")

      if check_pdb_selector_matches "$pdb_sel" "$workload_labels"; then
        found_matching_pdb=1
        echo "PASS: PodDisruptionBudget $pdb_name selects release workload $RELEASE"
        break
      else
        echo "  PodDisruptionBudget/$pdb_name: spec.selector does not match release workload labels" >&2
      fi
      di=$((di + 1))
    done

    if [ "$found_matching_pdb" -eq 0 ]; then
      if [ "$pdb_count" -gt 0 ]; then
        echo "FAIL: PodDisruptionBudget(s) present but none select the release $RELEASE workload" >&2
      else
        echo "FAIL: no PodDisruptionBudget selects release $RELEASE in namespace $NS" >&2
      fi
      return 1
    fi
  else
    # expect_present=false: check if any PDB is release-scoped
    local di=0 found_any=0
    while [ "$di" -lt "$pdb_count" ]; do
      local pdb_labels
      pdb_labels=$(printf '%s' "$pdb_yaml" | yq ".items[$di].metadata.labels // {}" -o json 2>/dev/null || echo "{}")
      local instance_label
      instance_label=$(printf '%s' "$pdb_labels" | jq -r '.["app.kubernetes.io/instance"] // ""' 2>/dev/null || echo "")
      if [ "$instance_label" = "$RELEASE" ]; then
        found_any=1
        break
      fi
      di=$((di + 1))
    done

    if [ "$found_any" -eq 1 ]; then
      echo "FAIL: unexpected PodDisruptionBudget present for release $RELEASE" >&2
      return 1
    fi
    echo "PASS: no PodDisruptionBudget for release $RELEASE"
    return 0
  fi

  return 0
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_pdb; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_pdb; then overall=1; fi
fi
exit "$overall"
