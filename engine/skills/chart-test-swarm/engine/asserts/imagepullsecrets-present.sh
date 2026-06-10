#!/usr/bin/env bash
# DEPTH: L1
# Assert: imagepullsecrets-present — validates presence or absence of
# imagePullSecrets on workload pod specs and optionally on the chart's
# ServiceAccount.
# When expect_present=true, asserts that every workload pod spec carries
# the configured imagePullSecrets entries and (if a ServiceAccount exists)
# the ServiceAccount also carries them.
# When expect_present=false, asserts that no imagePullSecrets are present
# on any workload pod spec or ServiceAccount.
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
CHECK_SA=$(yq ".asserts[$IDX].check_service_account // true" "$SCENARIO")
RELEASE="${RELEASE:-$(yq '.product.release' "$SCENARIO")}"

if [ "$EXPECT_PRESENT" != "true" ] && [ "$EXPECT_PRESENT" != "false" ]; then
  echo "FAIL: expect_present must be 'true' or 'false', got '$EXPECT_PRESENT'" >&2
  exit 1
fi

# Expected secret names (from scenario assert config)
SECRET_NAMES_JSON=$(yq ".asserts[$IDX].secret_names // []" -o json "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

rendered_file=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; return 0; }
trap cleanup EXIT

render_helm_template() {
  rendered_file=$(mktemp /tmp/cap-ips-rendered.XXXXXX.yaml)
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

check_rendered_imagepullsecrets() {
  local doc_count=0 fail_count=0 workload_count=0 sa_count=0
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

    if [ "$kind_val" = "ServiceAccount" ]; then
      sa_count=$((sa_count + 1))
      if [ "$CHECK_SA" = "true" ]; then
        local sa_ips
        sa_ips=$(yq "select(di == $di) | .imagePullSecrets // null" "$rendered_file" 2>/dev/null || echo "null")
        if [ "$EXPECT_PRESENT" = "true" ]; then
          if [ "$sa_ips" = "null" ] || [ -z "$sa_ips" ]; then
            echo "  ServiceAccount/$name_val: missing imagePullSecrets" >&2
            fail_count=$((fail_count + 1))
          else
            # Verify expected secret names are present
            if [ "$SECRET_NAMES_JSON" != "[]" ] && [ "$SECRET_NAMES_JSON" != "null" ]; then
              while IFS= read -r expected_name; do
                local found
                found=$(yq "select(di == $di) | .imagePullSecrets[] | select(.name == \"$expected_name\") | .name" "$rendered_file" 2>/dev/null || echo "")
                if [ "$found" != "$expected_name" ]; then
                  echo "  ServiceAccount/$name_val: missing imagePullSecret entry '$expected_name'" >&2
                  fail_count=$((fail_count + 1))
                fi
              done < <(printf '%s' "$SECRET_NAMES_JSON" | jq -r '.[]')
            fi
          fi
        else
          if [ "$sa_ips" != "null" ] && [ -n "$sa_ips" ]; then
            echo "  ServiceAccount/$name_val: unexpected imagePullSecrets present" >&2
            fail_count=$((fail_count + 1))
          fi
        fi
      fi
    fi

    # Check workload kinds
    case "$kind_val" in
      Deployment|StatefulSet|DaemonSet|Job|ReplicaSet)
        workload_count=$((workload_count + 1))
        local pod_ips
        pod_ips=$(yq "select(di == $di) | .spec.template.spec.imagePullSecrets // null" "$rendered_file" 2>/dev/null || echo "null")

        if [ "$EXPECT_PRESENT" = "true" ]; then
          if [ "$pod_ips" = "null" ] || [ -z "$pod_ips" ]; then
            echo "  $kind_val/$name_val: missing imagePullSecrets on pod spec" >&2
            fail_count=$((fail_count + 1))
          else
            # Verify expected secret names are present
            if [ "$SECRET_NAMES_JSON" != "[]" ] && [ "$SECRET_NAMES_JSON" != "null" ]; then
              while IFS= read -r expected_name; do
                local found
                found=$(yq "select(di == $di) | .spec.template.spec.imagePullSecrets[] | select(.name == \"$expected_name\") | .name" "$rendered_file" 2>/dev/null || echo "")
                if [ "$found" != "$expected_name" ]; then
                  echo "  $kind_val/$name_val: missing imagePullSecret entry '$expected_name' on pod spec" >&2
                  fail_count=$((fail_count + 1))
                fi
              done < <(printf '%s' "$SECRET_NAMES_JSON" | jq -r '.[]')
            fi
          fi
        else
          if [ "$pod_ips" != "null" ] && [ -n "$pod_ips" ]; then
            echo "  $kind_val/$name_val: unexpected imagePullSecrets on pod spec" >&2
            fail_count=$((fail_count + 1))
          fi
        fi
        ;;
    esac
    di=$((di + 1))
  done

  if [ "$workload_count" -eq 0 ]; then
    echo "FAIL: no workload objects found in rendered output" >&2
    return 1
  fi

  if [ "$fail_count" -gt 0 ]; then
    local scope_msg=""
    if [ "$CHECK_SA" = "true" ] && [ "$sa_count" -eq 0 ] && [ "$EXPECT_PRESENT" = "true" ]; then
      scope_msg=" (no ServiceAccount rendered — documented gap)"
    fi
    echo "FAIL: $fail_count imagePullSecrets check(s) failed across $workload_count workload(s)$scope_msg" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    local sa_msg=""
    if [ "$CHECK_SA" = "true" ] && [ "$sa_count" -eq 0 ]; then
      sa_msg=" (no ServiceAccount rendered — documented gap)"
    fi
    echo "PASS: imagePullSecrets present on $workload_count workload(s)$sa_msg"
  else
    echo "PASS: no imagePullSecrets on $workload_count workload(s) and $sa_count ServiceAccount(s)"
  fi
  return 0
}

check_live_imagepullsecrets() {
  local fail_count=0 workload_count=0 sa_count=0

  # Check Deployments — release-scoped
  local dep_yaml
  dep_yaml=$(kubectl "${kubectl_args[@]}" get deploy -n "$NS" -l "app.kubernetes.io/instance=${RELEASE}" -o yaml 2>/dev/null || echo "items: []")
  local dep_count; dep_count=$(printf '%s' "$dep_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  local i=0
  while [ "$i" -lt "$dep_count" ]; do
    local dname
    dname=$(printf '%s' "$dep_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")
    workload_count=$((workload_count + 1))

    local pod_ips
    pod_ips=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.imagePullSecrets // null" 2>/dev/null || echo "null")

    if [ "$EXPECT_PRESENT" = "true" ]; then
      if [ "$pod_ips" = "null" ] || [ -z "$pod_ips" ]; then
        echo "  Deployment/$dname: missing imagePullSecrets on pod spec" >&2
        fail_count=$((fail_count + 1))
      fi
    else
      if [ "$pod_ips" != "null" ] && [ -n "$pod_ips" ]; then
        echo "  Deployment/$dname: unexpected imagePullSecrets on pod spec" >&2
        fail_count=$((fail_count + 1))
      fi
    fi
    i=$((i + 1))
  done

  # Check ServiceAccounts — release-scoped
  if [ "$CHECK_SA" = "true" ]; then
    local sa_yaml
    sa_yaml=$(kubectl "${kubectl_args[@]}" get sa -n "$NS" -l "app.kubernetes.io/instance=${RELEASE}" -o yaml 2>/dev/null || echo "items: []")
    # Exclude the auto-created "default" SA
    local sa_count; sa_count=$(printf '%s' "$sa_yaml" | yq '[.items[] | select(.metadata.name != "default")] | length' 2>/dev/null || echo "0")
    local j=0
    while [ "$j" -lt "$sa_count" ]; do
      local sa_name
      sa_name=$(printf '%s' "$sa_yaml" | yq '[.items[] | select(.metadata.name != "default")]['"$j"'].metadata.name // ""' 2>/dev/null || echo "")
      local sa_ips
      sa_ips=$(printf '%s' "$sa_yaml" | yq '[.items[] | select(.metadata.name != "default")]['"$j"'].imagePullSecrets // null' 2>/dev/null || echo "null")

      if [ "$EXPECT_PRESENT" = "true" ]; then
        if [ "$sa_ips" = "null" ] || [ -z "$sa_ips" ]; then
          echo "  ServiceAccount/$sa_name: missing imagePullSecrets" >&2
          fail_count=$((fail_count + 1))
        fi
      else
        if [ "$sa_ips" != "null" ] && [ -n "$sa_ips" ]; then
          echo "  ServiceAccount/$sa_name: unexpected imagePullSecrets" >&2
          fail_count=$((fail_count + 1))
        fi
      fi
      j=$((j + 1))
    done
  fi

  if [ "$workload_count" -eq 0 ]; then
    echo "FAIL: no live workload objects found" >&2
    return 1
  fi

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count live imagePullSecrets check(s) failed" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: imagePullSecrets present on $workload_count live workload(s)"
  else
    echo "PASS: no imagePullSecrets on $workload_count live workload(s)"
  fi
  return 0
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_imagepullsecrets; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_imagepullsecrets; then overall=1; fi
fi
exit "$overall"
