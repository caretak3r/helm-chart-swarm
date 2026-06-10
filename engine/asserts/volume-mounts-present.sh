#!/usr/bin/env bash
# DEPTH: L1
# Assert: volume-mounts-present — validates presence or absence of volumeMounts
# and matching volumes on workload containers.
# When expect_present=true, asserts that every in-scope workload container
# carries the configured volumeMounts with matching volume definitions.
# When expect_present=false, asserts that no volumeMounts are present.
# Introspects helm template output and/or live kubectl get -o yaml.
# L2: When source=live, execs into pod and stats the mountPath.
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

# Optional knobs
MOUNT_PATH=$(yq ".asserts[$IDX].mountPath // \"\"" "$SCENARIO")
VOLUME_NAME=$(yq ".asserts[$IDX].volume_name // \"\"" "$SCENARIO")
SOURCE_TYPE=$(yq ".asserts[$IDX].source_type // \"\"" "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

rendered_file=""
# shellcheck disable=SC2329
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; return 0; }
trap cleanup EXIT

render_helm_template() {
  rendered_file=$(mktemp /tmp/cap-volmounts-rendered.XXXXXX.yaml)
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

check_rendered_volume_mounts() {
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

    case "$kind_val" in
      Deployment|StatefulSet|DaemonSet|Job|ReplicaSet)
        workload_count=$((workload_count + 1))
        ;;
      *)
        di=$((di + 1)); continue
        ;;
    esac

    local ctr_count
    ctr_count=$(yq "select(di == $di) | .spec.template.spec.containers | length" "$rendered_file" 2>/dev/null || echo "0")
    local ci=0
    while [ "$ci" -lt "$ctr_count" ]; do
      local ctr_name
      ctr_name=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].name // \"container-$ci\"" "$rendered_file" 2>/dev/null || echo "container-$ci")

      if [ "$EXPECT_PRESENT" = "true" ]; then
        # Check volumeMounts presence
        local vm_present
        vm_present=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].volumeMounts // null" "$rendered_file" 2>/dev/null || echo "null")
        if [ "$vm_present" = "null" ] || [ -z "$vm_present" ]; then
          echo "  $kind_val/$name_val container/$ctr_name: missing volumeMounts" >&2
          fail_count=$((fail_count + 1))
          ci=$((ci + 1)); continue
        fi

        # If mountPath knob is set, verify it exists
        if [ -n "$MOUNT_PATH" ] && [ "$MOUNT_PATH" != "null" ]; then
          local has_mountpath
          has_mountpath=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].volumeMounts[] | select(.mountPath == \"$MOUNT_PATH\") | .name" "$rendered_file" 2>/dev/null || echo "")
          if [ -z "$has_mountpath" ]; then
            echo "  $kind_val/$name_val container/$ctr_name: mountPath=$MOUNT_PATH not found in volumeMounts" >&2
            fail_count=$((fail_count + 1))
            ci=$((ci + 1)); continue
          fi

          # If volume_name knob is set, verify the mount's volume name matches
          if [ -n "$VOLUME_NAME" ] && [ "$VOLUME_NAME" != "null" ]; then
            local mount_vol_name
            mount_vol_name=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].volumeMounts[] | select(.mountPath == \"$MOUNT_PATH\") | .name" "$rendered_file" 2>/dev/null || echo "")
            if [ "$mount_vol_name" != "$VOLUME_NAME" ]; then
              echo "  $kind_val/$name_val container/$ctr_name: volumeMount at $MOUNT_PATH references volume '$mount_vol_name', expected '$VOLUME_NAME'" >&2
              fail_count=$((fail_count + 1))
              ci=$((ci + 1)); continue
            fi
          fi

          # If source_type knob is set, verify the backing volume source type
          if [ -n "$SOURCE_TYPE" ] && [ "$SOURCE_TYPE" != "null" ]; then
            local vol_name_for_path
            vol_name_for_path=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].volumeMounts[] | select(.mountPath == \"$MOUNT_PATH\") | .name" "$rendered_file" 2>/dev/null || echo "")
            local vol_type
            vol_type=$(yq "select(di == $di) | .spec.template.spec.volumes[] | select(.name == \"$vol_name_for_path\") | keys | .[] | select(. != \"name\")" "$rendered_file" 2>/dev/null || echo "")
            if [ "$vol_type" != "$SOURCE_TYPE" ]; then
              echo "  $kind_val/$name_val volume/$vol_name_for_path: source type '$vol_type', expected '$SOURCE_TYPE'" >&2
              fail_count=$((fail_count + 1))
            fi
          fi
        fi
      else
        # expect_present=false: no volumeMounts should be present
        local vm_present
        vm_present=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].volumeMounts // null" "$rendered_file" 2>/dev/null || echo "null")
        if [ "$vm_present" != "null" ] && [ -n "$vm_present" ]; then
          echo "  $kind_val/$name_val container/$ctr_name: unexpected volumeMounts present" >&2
          fail_count=$((fail_count + 1))
        fi
      fi
      ci=$((ci + 1))
    done
    di=$((di + 1))
  done

  if [ "$workload_count" -eq 0 ]; then
    echo "FAIL: no workload objects found in rendered output" >&2
    return 1
  fi

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count volume mount check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: volume mounts present on $workload_count workload(s)"
  else
    echo "PASS: no volume mounts present on $workload_count workload(s)"
  fi
  return 0
}

check_live_volume_mounts() {
  local fail_count=0 workload_count=0

  local dep_yaml
  dep_yaml=$(kubectl "${kubectl_args[@]}" get deploy -n "$NS" -l "app.kubernetes.io/instance=${RELEASE}" -o yaml 2>/dev/null || echo "items: []")
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
        local vm_present
        vm_present=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].volumeMounts // null" 2>/dev/null || echo "null")
        if [ "$vm_present" = "null" ] || [ -z "$vm_present" ]; then
          echo "  Deployment/$dname container/$ctr_name: missing volumeMounts" >&2
          fail_count=$((fail_count + 1))
        fi
      else
        local vm_present
        vm_present=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].volumeMounts // null" 2>/dev/null || echo "null")
        if [ "$vm_present" != "null" ] && [ -n "$vm_present" ]; then
          echo "  Deployment/$dname container/$ctr_name: unexpected volumeMounts present" >&2
          fail_count=$((fail_count + 1))
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
    echo "FAIL: $fail_count live volume mount check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: volume mounts present on $workload_count live workload(s)"
  else
    echo "PASS: no volume mounts present on $workload_count live workload(s)"
  fi
  return 0
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_volume_mounts; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_volume_mounts; then overall=1; fi
fi
exit "$overall"
