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
  rendered_file="$(mktemp /tmp/cap-volmounts-rendered-XXXXXX)"
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

        # Enforce mount + backing volume correlation for EVERY volumeMount.
        # A dangling volumeMount (name with no matching .spec.template.spec.volumes entry)
        # must FAIL — per VAL-CONFIG-010.
        local vm_count
        vm_count=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].volumeMounts | length" "$rendered_file" 2>/dev/null || echo "0")
        local vi=0
        while [ "$vi" -lt "$vm_count" ]; do
          local vm_name
          vm_name=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].volumeMounts[$vi].name // \"\"" "$rendered_file" 2>/dev/null || echo "")
          local vm_path
          vm_path=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].volumeMounts[$vi].mountPath // \"\"" "$rendered_file" 2>/dev/null || echo "")

          # Verify the volume name exists in .spec.template.spec.volumes
          local backing_vol
          backing_vol=$(yq "select(di == $di) | .spec.template.spec.volumes[] | select(.name == \"$vm_name\") | .name" "$rendered_file" 2>/dev/null || echo "")
          if [ -z "$backing_vol" ]; then
            echo "  $kind_val/$name_val container/$ctr_name: volumeMount '$vm_name' (mountPath=$vm_path) has no matching volume in spec.template.spec.volumes" >&2
            fail_count=$((fail_count + 1))
            vi=$((vi + 1)); continue
          fi

          vi=$((vi + 1))
        done

        # If mountPath knob is set, verify it exists among the mounts
        if [ -n "$MOUNT_PATH" ] && [ "$MOUNT_PATH" != "null" ]; then
          local has_mountpath
          has_mountpath=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].volumeMounts[] | select(.mountPath == \"$MOUNT_PATH\") | .name" "$rendered_file" 2>/dev/null || echo "")
          if [ -z "$has_mountpath" ]; then
            echo "  $kind_val/$name_val container/$ctr_name: mountPath=$MOUNT_PATH not found in volumeMounts" >&2
            fail_count=$((fail_count + 1))
          fi

          # If volume_name knob is set, verify the mount's volume name matches
          if [ -n "$VOLUME_NAME" ] && [ "$VOLUME_NAME" != "null" ] && [ -n "$has_mountpath" ]; then
            if [ "$has_mountpath" != "$VOLUME_NAME" ]; then
              echo "  $kind_val/$name_val container/$ctr_name: volumeMount at $MOUNT_PATH references volume '$has_mountpath', expected '$VOLUME_NAME'" >&2
              fail_count=$((fail_count + 1))
            fi
          fi

          # If source_type knob is set, verify the backing volume source type
          if [ -n "$SOURCE_TYPE" ] && [ "$SOURCE_TYPE" != "null" ] && [ -n "$has_mountpath" ]; then
            local vol_type
            vol_type=$(yq "select(di == $di) | .spec.template.spec.volumes[] | select(.name == \"$has_mountpath\") | keys | .[] | select(. != \"name\")" "$rendered_file" 2>/dev/null || echo "")
            if [ "$vol_type" != "$SOURCE_TYPE" ]; then
              echo "  $kind_val/$name_val volume/$has_mountpath: source type '$vol_type', expected '$SOURCE_TYPE'" >&2
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

  local release_sel="app.kubernetes.io/instance=${RELEASE}"

  # Step 1 (L1): Check volumeMount field presence on live Deployment specs
  local dep_yaml
  dep_yaml=$(kubectl "${kubectl_args[@]}" get deploy -n "$NS" -l "$release_sel" -o yaml 2>/dev/null || echo "items: []")
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

        # Enforce backing volume correlation on live specs too
        if [ "$vm_present" != "null" ] && [ -n "$vm_present" ]; then
          local vm_count
          vm_count=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].volumeMounts | length" 2>/dev/null || echo "0")
          local vi=0
          while [ "$vi" -lt "$vm_count" ]; do
            local vm_name
            vm_name=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].volumeMounts[$vi].name // \"\"" 2>/dev/null || echo "")
            local vm_path
            vm_path=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].volumeMounts[$vi].mountPath // \"\"" 2>/dev/null || echo "")
            local backing_vol
            backing_vol=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.volumes[] | select(.name == \"$vm_name\") | .name" 2>/dev/null || echo "")
            if [ -z "$backing_vol" ]; then
              echo "  Deployment/$dname container/$ctr_name: volumeMount '$vm_name' (mountPath=$vm_path) has no matching volume" >&2
              fail_count=$((fail_count + 1))
            fi
            vi=$((vi + 1))
          done
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
    echo "FAIL: $fail_count live volume mount field check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  # Step 2 (L2): Select a Ready release pod, run kubectl exec, and stat the
  # configured mountPath to prove the volume is actually mounted in-container.
  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "Selecting a Ready release pod to verify mount in-container..."
    local pod_name
    pod_name=$(kubectl "${kubectl_args[@]}" get pods -n "$NS" -l "$release_sel" \
      -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | tr ' ' '\n' | head -n1)
    if [ -z "$pod_name" ]; then
      echo "FAIL: no Running pod found for release in ns/$NS" >&2
      return 1
    fi
    echo "  Selected pod: $pod_name"

    # If mountPath knob is set, stat that specific path
    if [ -n "$MOUNT_PATH" ] && [ "$MOUNT_PATH" != "null" ]; then
      echo "  stat-ing mountPath $MOUNT_PATH in pod $pod_name..."
      if kubectl "${kubectl_args[@]}" exec -n "$NS" "$pod_name" -- stat "$MOUNT_PATH" >/dev/null 2>&1; then
        echo "PASS: volumeMount at $MOUNT_PATH verified in-container on pod $pod_name"
      else
        echo "FAIL: mountPath $MOUNT_PATH not found or not accessible in pod $pod_name" >&2
        return 1
      fi
    else
      # Verify all volumeMounts by stat-ing each mountPath
      local vm_count
      vm_count=$(printf '%s' "$dep_yaml" | yq ".items[0].spec.template.spec.containers[0].volumeMounts | length" 2>/dev/null || echo "0")
      if [ "$vm_count" -gt 0 ]; then
        local vi=0 vm_stat_fails=0
        while [ "$vi" -lt "$vm_count" ]; do
          local vm_path
          vm_path=$(printf '%s' "$dep_yaml" | yq ".items[0].spec.template.spec.containers[0].volumeMounts[$vi].mountPath // \"\"" 2>/dev/null || echo "")
          if [ -n "$vm_path" ] && [ "$vm_path" != "null" ]; then
            if ! kubectl "${kubectl_args[@]}" exec -n "$NS" "$pod_name" -- stat "$vm_path" >/dev/null 2>&1; then
              echo "  mountPath $vm_path: not accessible in pod $pod_name" >&2
              vm_stat_fails=$((vm_stat_fails + 1))
            fi
          fi
          vi=$((vi + 1))
        done
        if [ "$vm_stat_fails" -gt 0 ]; then
          echo "FAIL: $vm_stat_fails mountPath(s) not accessible in-container" >&2
          return 1
        fi
        echo "PASS: all volumeMount paths verified in-container on pod $pod_name"
      fi
    fi
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
