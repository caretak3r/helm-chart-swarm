#!/usr/bin/env bash
# DEPTH: L1
# Assert: lifecycle-hooks — validates presence or absence of container
# lifecycle hooks (postStart and/or preStop) on workload containers.
# When expect_present=true, asserts that every in-scope workload container
# carries a lifecycle block with the configured hook types.
# When expect_present=false, asserts that no lifecycle hooks are present.
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

# Hook type flags (default: check both postStart and preStop)
_raw=$(yq ".asserts[$IDX].check_postStart" "$SCENARIO")
CHECK_POSTSTART=$([ "$_raw" = "null" ] || [ -z "$_raw" ] && echo "true" || echo "$_raw")
_raw=$(yq ".asserts[$IDX].check_preStop" "$SCENARIO")
CHECK_PRESTOP=$([ "$_raw" = "null" ] || [ -z "$_raw" ] && echo "true" || echo "$_raw")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

rendered_file=""
# shellcheck disable=SC2329
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; return 0; }
trap cleanup EXIT

render_helm_template() {
  rendered_file=$(mktemp /tmp/cap-lifecycle-rendered.XXXXXX.yaml)
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

check_rendered_lifecycle_hooks() {
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

    local ctr_count
    ctr_count=$(yq "select(di == $di) | .spec.template.spec.containers | length" "$rendered_file" 2>/dev/null || echo "0")
    local ci=0
    while [ "$ci" -lt "$ctr_count" ]; do
      local ctr_name
      ctr_name=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].name // \"container-$ci\"" "$rendered_file" 2>/dev/null || echo "container-$ci")

      if [ "$EXPECT_PRESENT" = "true" ]; then
        if [ "$CHECK_POSTSTART" = "true" ]; then
          local poststart
          poststart=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].lifecycle.postStart // null" "$rendered_file" 2>/dev/null || echo "null")
          if [ "$poststart" = "null" ] || [ -z "$poststart" ]; then
            echo "  $kind_val/$name_val container/$ctr_name: missing postStart lifecycle hook" >&2
            fail_count=$((fail_count + 1))
          fi
        fi
        if [ "$CHECK_PRESTOP" = "true" ]; then
          local prestop
          prestop=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].lifecycle.preStop // null" "$rendered_file" 2>/dev/null || echo "null")
          if [ "$prestop" = "null" ] || [ -z "$prestop" ]; then
            echo "  $kind_val/$name_val container/$ctr_name: missing preStop lifecycle hook" >&2
            fail_count=$((fail_count + 1))
          fi
        fi
      else
        # expect_present=false: no lifecycle hooks should be present
        if [ "$CHECK_POSTSTART" = "true" ]; then
          local poststart
          poststart=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].lifecycle.postStart // null" "$rendered_file" 2>/dev/null || echo "null")
          if [ "$poststart" != "null" ] && [ -n "$poststart" ]; then
            echo "  $kind_val/$name_val container/$ctr_name: unexpected postStart lifecycle hook present" >&2
            fail_count=$((fail_count + 1))
          fi
        fi
        if [ "$CHECK_PRESTOP" = "true" ]; then
          local prestop
          prestop=$(yq "select(di == $di) | .spec.template.spec.containers[$ci].lifecycle.preStop // null" "$rendered_file" 2>/dev/null || echo "null")
          if [ "$prestop" != "null" ] && [ -n "$prestop" ]; then
            echo "  $kind_val/$name_val container/$ctr_name: unexpected preStop lifecycle hook present" >&2
            fail_count=$((fail_count + 1))
          fi
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
    echo "FAIL: $fail_count lifecycle hook check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: lifecycle hooks present on $workload_count workload(s)"
  else
    echo "PASS: no lifecycle hooks present on $workload_count workload(s)"
  fi
  return 0
}

check_live_lifecycle_hooks() {
  local fail_count=0 workload_count=0

  local dep_yaml
  dep_yaml=$(kubectl "${kubectl_args[@]}" get deploy -n "$NS" -l "app.kubernetes.io/instance=${RELEASE}" -o yaml 2>/dev/null || echo "items: []")
  local dep_count; dep_count=$(printf '%s' "$dep_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  local i=0
  while [ "$i" -lt "$dep_count" ]; do
    local dname; dname=$(printf '%s' "$dep_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")
    workload_count=$((workload_count + 1))

    local ctr_count; ctr_count=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers | length" 2>/dev/null || echo "0")
    local ci=0
    while [ "$ci" -lt "$ctr_count" ]; do
      local ctr_name; ctr_name=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].name // \"container-$ci\"" 2>/dev/null || echo "container-$ci")

      if [ "$EXPECT_PRESENT" = "true" ]; then
        if [ "$CHECK_POSTSTART" = "true" ]; then
          local poststart
          poststart=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].lifecycle.postStart // null" 2>/dev/null || echo "null")
          if [ "$poststart" = "null" ] || [ -z "$poststart" ]; then
            echo "  Deployment/$dname container/$ctr_name: missing postStart lifecycle hook" >&2
            fail_count=$((fail_count + 1))
          fi
        fi
        if [ "$CHECK_PRESTOP" = "true" ]; then
          local prestop
          prestop=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].lifecycle.preStop // null" 2>/dev/null || echo "null")
          if [ "$prestop" = "null" ] || [ -z "$prestop" ]; then
            echo "  Deployment/$dname container/$ctr_name: missing preStop lifecycle hook" >&2
            fail_count=$((fail_count + 1))
          fi
        fi
      else
        if [ "$CHECK_POSTSTART" = "true" ]; then
          local poststart
          poststart=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].lifecycle.postStart // null" 2>/dev/null || echo "null")
          if [ "$poststart" != "null" ] && [ -n "$poststart" ]; then
            echo "  Deployment/$dname container/$ctr_name: unexpected postStart lifecycle hook present" >&2
            fail_count=$((fail_count + 1))
          fi
        fi
        if [ "$CHECK_PRESTOP" = "true" ]; then
          local prestop
          prestop=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[$ci].lifecycle.preStop // null" 2>/dev/null || echo "null")
          if [ "$prestop" != "null" ] && [ -n "$prestop" ]; then
            echo "  Deployment/$dname container/$ctr_name: unexpected preStop lifecycle hook present" >&2
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
    echo "FAIL: $fail_count live lifecycle hook check(s) failed across $workload_count workload(s)" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: lifecycle hooks present on $workload_count live workload(s)"
  else
    echo "PASS: no lifecycle hooks present on $workload_count live workload(s)"
  fi
  return 0
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_lifecycle_hooks; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_lifecycle_hooks; then overall=1; fi
fi
exit "$overall"
