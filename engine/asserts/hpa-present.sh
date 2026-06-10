#!/usr/bin/env bash
# DEPTH: L1
# Assert: hpa-present — validates presence or absence of a HorizontalPodAutoscaler
# that targets the release workload.
# When expect_present=true, asserts that at least one HPA exists whose
# scaleTargetRef points at a release workload with correct min/max replicas.
# When expect_present=false, asserts that no HPA targets the release workload.
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

# Optional knobs for replicas verification
MIN_REPLICAS=$(yq ".asserts[$IDX].min_replicas // \"\"" "$SCENARIO")
MAX_REPLICAS=$(yq ".asserts[$IDX].max_replicas // \"\"" "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

rendered_file=""
# shellcheck disable=SC2329
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; return 0; }
trap cleanup EXIT

render_helm_template() {
  rendered_file=$(mktemp /tmp/cap-hpa-rendered.XXXXXX.yaml)
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

check_rendered_hpa() {
  local doc_count=0 workload_count=0 hpa_found=0
  doc_count=$(yq '.kind // ""' "$rendered_file" 2>/dev/null | grep -cv '^$\|^null$\|^---$')
  if [ "$doc_count" -eq 0 ]; then
    echo "FAIL: no documents found in rendered output" >&2
    return 1
  fi

  # Collect release workload names
  local release_workload_names=""
  local di=0
  while [ "$di" -lt "$doc_count" ]; do
    local kind_val name_val
    kind_val=$(yq "select(di == $di) | .kind // \"\"" "$rendered_file" 2>/dev/null || echo "")
    name_val=$(yq "select(di == $di) | .metadata.name // \"\"" "$rendered_file" 2>/dev/null || echo "")

    case "$kind_val" in
      Deployment|StatefulSet|DaemonSet|Job|ReplicaSet)
        workload_count=$((workload_count + 1))
        release_workload_names="${release_workload_names}${name_val}\n"
        ;;
    esac
    di=$((di + 1))
  done

  if [ "$workload_count" -eq 0 ]; then
    echo "FAIL: no workload objects found in rendered output" >&2
    return 1
  fi

  # Check for HPAs
  di=0
  while [ "$di" -lt "$doc_count" ]; do
    local kind_val name_val
    kind_val=$(yq "select(di == $di) | .kind // \"\"" "$rendered_file" 2>/dev/null || echo "")
    name_val=$(yq "select(di == $di) | .metadata.name // \"\"" "$rendered_file" 2>/dev/null || echo "")

    if [ "$kind_val" = "HorizontalPodAutoscaler" ]; then
      hpa_found=$((hpa_found + 1))
      if [ "$EXPECT_PRESENT" = "true" ]; then
        # Check scaleTargetRef points at a release workload
        local target_kind target_name
        target_kind=$(yq "select(di == $di) | .spec.scaleTargetRef.kind // \"\"" "$rendered_file" 2>/dev/null || echo "")
        target_name=$(yq "select(di == $di) | .spec.scaleTargetRef.name // \"\"" "$rendered_file" 2>/dev/null || echo "")

        if ! printf '%b' "$release_workload_names" | grep -qF "$target_name"; then
          echo "FAIL: HorizontalPodAutoscaler $name_val scaleTargetRef ($target_kind/$target_name) does not point at a release workload" >&2
          return 1
        fi

        # Verify min/max replicas if configured
        if [ -n "$MIN_REPLICAS" ] && [ "$MIN_REPLICAS" != "null" ]; then
          local actual_min
          actual_min=$(yq "select(di == $di) | .spec.minReplicas // \"\"" "$rendered_file" 2>/dev/null || echo "")
          if [ "$actual_min" != "$MIN_REPLICAS" ]; then
            echo "FAIL: HorizontalPodAutoscaler $name_val minReplicas=$actual_min expected=$MIN_REPLICAS" >&2
            return 1
          fi
        fi

        if [ -n "$MAX_REPLICAS" ] && [ "$MAX_REPLICAS" != "null" ]; then
          local actual_max
          actual_max=$(yq "select(di == $di) | .spec.maxReplicas // \"\"" "$rendered_file" 2>/dev/null || echo "")
          if [ "$actual_max" != "$MAX_REPLICAS" ]; then
            echo "FAIL: HorizontalPodAutoscaler $name_val maxReplicas=$actual_max expected=$MAX_REPLICAS" >&2
            return 1
          fi
        fi

        echo "PASS: HorizontalPodAutoscaler $name_val targets release workload $target_kind/$target_name"
        return 0
      else
        # expect_present=false but HPA present
        echo "FAIL: unexpected HorizontalPodAutoscaler $name_val present" >&2
        return 1
      fi
    fi
    di=$((di + 1))
  done

  if [ "$EXPECT_PRESENT" = "true" ]; then
    if [ "$hpa_found" -eq 0 ]; then
      echo "FAIL: no HorizontalPodAutoscaler found" >&2
      return 1
    fi
  else
    echo "PASS: no HorizontalPodAutoscaler present"
    return 0
  fi
}

check_live_hpa() {
  local hpa_yaml
  hpa_yaml=$(kubectl "${kubectl_args[@]}" get hpa -n "$NS" -o yaml 2>/dev/null || echo "items: []")
  local hpa_count; hpa_count=$(printf '%s' "$hpa_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  if [ "$EXPECT_PRESENT" = "true" ]; then
    if [ "$hpa_count" -eq 0 ]; then
      echo "FAIL: no HorizontalPodAutoscaler found in namespace $NS" >&2
      return 1
    fi

    # Check if any HPA targets the release workload
    local di=0 found_release_hpa=0
    while [ "$di" -lt "$hpa_count" ]; do
      local hpa_name hpa_labels
      hpa_name=$(printf '%s' "$hpa_yaml" | yq ".items[$di].metadata.name // \"\"" 2>/dev/null || echo "")
      hpa_labels=$(printf '%s' "$hpa_yaml" | yq ".items[$di].metadata.labels // {}" -o json 2>/dev/null || echo "{}")
      local instance_label
      instance_label=$(printf '%s' "$hpa_labels" | jq -r '.["app.kubernetes.io/instance"] // ""' 2>/dev/null || echo "")

      if [ "$instance_label" = "$RELEASE" ]; then
        found_release_hpa=1
        local target_kind target_name
        target_kind=$(printf '%s' "$hpa_yaml" | yq ".items[$di].spec.scaleTargetRef.kind // \"\"" 2>/dev/null || echo "")
        target_name=$(printf '%s' "$hpa_yaml" | yq ".items[$di].spec.scaleTargetRef.name // \"\"" 2>/dev/null || echo "")

        # Verify the target is a real workload
        if ! kubectl "${kubectl_args[@]}" get "$target_kind" "$target_name" -n "$NS" &>/dev/null; then
          echo "FAIL: HPA $hpa_name scaleTargetRef ($target_kind/$target_name) not found" >&2
          return 1
        fi

        # Verify min/max if configured
        if [ -n "$MIN_REPLICAS" ] && [ "$MIN_REPLICAS" != "null" ]; then
          local actual_min
          actual_min=$(printf '%s' "$hpa_yaml" | yq ".items[$di].spec.minReplicas // \"\"" 2>/dev/null || echo "")
          if [ "$actual_min" != "$MIN_REPLICAS" ]; then
            echo "FAIL: HPA $hpa_name minReplicas=$actual_min expected=$MIN_REPLICAS" >&2
            return 1
          fi
        fi
        if [ -n "$MAX_REPLICAS" ] && [ "$MAX_REPLICAS" != "null" ]; then
          local actual_max
          actual_max=$(printf '%s' "$hpa_yaml" | yq ".items[$di].spec.maxReplicas // \"\"" 2>/dev/null || echo "")
          if [ "$actual_max" != "$MAX_REPLICAS" ]; then
            echo "FAIL: HPA $hpa_name maxReplicas=$actual_max expected=$MAX_REPLICAS" >&2
            return 1
          fi
        fi

        echo "PASS: HPA $hpa_name targets release workload $target_kind/$target_name"
        break
      fi
      di=$((di + 1))
    done

    if [ "$found_release_hpa" -eq 0 ]; then
      echo "FAIL: no HorizontalPodAutoscaler targets release $RELEASE in namespace $NS" >&2
      return 1
    fi
  else
    # expect_present=false
    local di=0 found_any=0
    while [ "$di" -lt "$hpa_count" ]; do
      local hpa_labels
      hpa_labels=$(printf '%s' "$hpa_yaml" | yq ".items[$di].metadata.labels // {}" -o json 2>/dev/null || echo "{}")
      local instance_label
      instance_label=$(printf '%s' "$hpa_labels" | jq -r '.["app.kubernetes.io/instance"] // ""' 2>/dev/null || echo "")
      if [ "$instance_label" = "$RELEASE" ]; then
        found_any=1
        break
      fi
      di=$((di + 1))
    done

    if [ "$found_any" -eq 1 ]; then
      echo "FAIL: unexpected HorizontalPodAutoscaler present for release $RELEASE" >&2
      return 1
    fi
    echo "PASS: no HorizontalPodAutoscaler for release $RELEASE"
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
  elif ! check_rendered_hpa; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_hpa; then overall=1; fi
fi
exit "$overall"
