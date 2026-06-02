#!/usr/bin/env bash
# Assert: rbac-objects — validates presence or absence of RBAC objects
# (ServiceAccount, Role, RoleBinding, ClusterRole, ClusterRoleBinding).
# When expect_present=true, also validates wiring (roleRef, subjects, serviceAccountName).
# Introspects helm template output and/or live kubectl get -o yaml.
# Returns {status: PASS|FAIL, detail} via exit code + stdout.
set -euo pipefail

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
SOURCE=$(yq ".asserts[$IDX].source // \"both\"" "$SCENARIO")
EXPECT_PRESENT=$(yq ".asserts[$IDX].expect_present" "$SCENARIO")

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
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; }
trap cleanup EXIT

render_helm_template() {
  rendered_file=$(mktemp /tmp/cap-rbac-rendered.XXXXXX.yaml)
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

check_rendered_rbac() {
  local doc_count=0
  doc_count=$(yq '.kind // ""' "$rendered_file" 2>/dev/null | grep -cv '^$\|^null$\|^---$')
  if [ "$doc_count" -eq 0 ]; then
    echo "FAIL: no documents found in rendered output" >&2
    return 1
  fi

  local rbac_count=0 rbac_list=""
  local di=0
  while [ "$di" -lt "$doc_count" ]; do
    local kind_val name_val
    kind_val=$(yq "select(di == $di) | .kind // \"\"" "$rendered_file" 2>/dev/null || echo "")
    name_val=$(yq "select(di == $di) | .metadata.name // \"\"" "$rendered_file" 2>/dev/null || echo "")

    if [ -z "$kind_val" ] || [ "$kind_val" = "null" ]; then
      di=$((di + 1)); continue
    fi

    case "$kind_val" in
      ServiceAccount|Role|RoleBinding|ClusterRole|ClusterRoleBinding)
        rbac_count=$((rbac_count + 1))
        rbac_list="${rbac_list}  $kind_val/$name_val"$'\n'
        ;;
    esac
    di=$((di + 1))
  done

  if [ "$EXPECT_PRESENT" = "true" ]; then
    if [ "$rbac_count" -eq 0 ]; then
      echo "FAIL: expected RBAC objects but found 0" >&2
      return 1
    fi
    # Validate wiring: RoleBinding/ClusterRoleBinding must have roleRef + subjects
    local wire_fail=0
    di=0
    while [ "$di" -lt "$doc_count" ]; do
      local kind_val
      kind_val=$(yq "select(di == $di) | .kind // \"\"" "$rendered_file" 2>/dev/null || echo "")
      case "$kind_val" in
        RoleBinding|ClusterRoleBinding)
          local bname; bname=$(yq "select(di == $di) | .metadata.name // \"\"" "$rendered_file" 2>/dev/null || echo "")
          local role_ref; role_ref=$(yq "select(di == $di) | .roleRef // null" "$rendered_file" 2>/dev/null || echo "null")
          local subjects; subjects=$(yq "select(di == $di) | .subjects // null" "$rendered_file" 2>/dev/null || echo "null")
          if [ "$role_ref" = "null" ] || [ -z "$role_ref" ]; then
            echo "  $kind_val/$bname missing roleRef" >&2
            wire_fail=$((wire_fail + 1))
          fi
          if [ "$subjects" = "null" ] || [ -z "$subjects" ]; then
            echo "  $kind_val/$bname missing subjects" >&2
            wire_fail=$((wire_fail + 1))
          fi
          ;;
      esac
      di=$((di + 1))
    done
    if [ "$wire_fail" -gt 0 ]; then
      echo "FAIL: $wire_fail wiring issue(s) in RBAC bindings" >&2
      return 1
    fi
    echo "PASS: $rbac_count RBAC object(s) found, wiring valid"
    return 0
  else
    # expect_present=false: no RBAC objects should exist
    if [ "$rbac_count" -gt 0 ]; then
      echo "FAIL: expected no RBAC objects but found $rbac_count:" >&2
      printf '%s' "$rbac_list" >&2
      return 1
    fi
    echo "PASS: no RBAC objects found (as expected)"
    return 0
  fi
}

check_live_rbac() {
  local rbac_count=0 wire_fail=0

  # ServiceAccounts
  local sa_yaml
  sa_yaml=$(kubectl "${kubectl_args[@]}" get sa -n "$NS" -o yaml 2>/dev/null || echo "items: []")
  local sa_count; sa_count=$(printf '%s' "$sa_yaml" | yq '.items | length' 2>/dev/null || echo "0")
  rbac_count=$((rbac_count + sa_count))

  # Roles
  local role_yaml
  role_yaml=$(kubectl "${kubectl_args[@]}" get role -n "$NS" -o yaml 2>/dev/null || echo "items: []")
  local role_count; role_count=$(printf '%s' "$role_yaml" | yq '.items | length' 2>/dev/null || echo "0")
  rbac_count=$((rbac_count + role_count))

  # RoleBindings
  local rb_yaml
  rb_yaml=$(kubectl "${kubectl_args[@]}" get rolebinding -n "$NS" -o yaml 2>/dev/null || echo "items: []")
  local rb_count; rb_count=$(printf '%s' "$rb_yaml" | yq '.items | length' 2>/dev/null || echo "0")
  rbac_count=$((rbac_count + rb_count))

  if [ "$EXPECT_PRESENT" = "true" ]; then
    if [ "$rbac_count" -eq 0 ]; then echo "FAIL: no live RBAC objects found" >&2; return 1; fi
    # Validate RoleBinding wiring
    local i=0
    while [ "$i" -lt "$rb_count" ]; do
      local bname; bname=$(printf '%s' "$rb_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")
      local role_ref; role_ref=$(printf '%s' "$rb_yaml" | yq ".items[$i].roleRef // null" 2>/dev/null || echo "null")
      local subjects; subjects=$(printf '%s' "$rb_yaml" | yq ".items[$i].subjects // null" 2>/dev/null || echo "null")
      if [ "$role_ref" = "null" ] || [ -z "$role_ref" ]; then echo "  RoleBinding/$bname missing roleRef" >&2; wire_fail=$((wire_fail + 1)); fi
      if [ "$subjects" = "null" ] || [ -z "$subjects" ]; then echo "  RoleBinding/$bname missing subjects" >&2; wire_fail=$((wire_fail + 1)); fi
      i=$((i + 1))
    done
    if [ "$wire_fail" -gt 0 ]; then echo "FAIL: $wire_fail wiring issue(s) in live RoleBindings" >&2; return 1; fi
    echo "PASS: $rbac_count live RBAC object(s) found, wiring valid"
    return 0
  else
    if [ "$rbac_count" -gt 0 ]; then echo "FAIL: $rbac_count live RBAC object(s) found (expected 0)" >&2; return 1; fi
    echo "PASS: no live RBAC objects found (as expected)"
    return 0
  fi
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_rbac; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_rbac; then overall=1; fi
fi
exit "$overall"
