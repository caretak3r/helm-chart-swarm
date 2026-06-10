#!/usr/bin/env bash
# DEPTH: L1
# Assert: rbac-objects — validates presence or absence of RBAC objects
# (ServiceAccount, Role, RoleBinding, ClusterRole, ClusterRoleBinding).
# When expect_present=true, also validates wiring (roleRef targets chart Role,
# subjects include chart ServiceAccount).
# Live queries are release-scoped via app.kubernetes.io/instance label.
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
  local wire_fail=0

  # Build release label
  local release_val="${RELEASE:-}"
  if [ -z "$release_val" ]; then
    echo "FAIL: RELEASE not set for live RBAC scoping" >&2
    return 1
  fi

  # ServiceAccounts — release-scoped, excluding "default"
  local sa_yaml
  sa_yaml=$(kubectl "${kubectl_args[@]}" get sa -n "$NS" -l "app.kubernetes.io/instance=$release_val" -o yaml 2>/dev/null || echo "items: []")
  local sa_count; sa_count=$(printf '%s' "$sa_yaml" | yq '[.items[] | select(.metadata.name != "default")] | length' 2>/dev/null || echo "0")

  # Roles — release-scoped
  local role_yaml
  role_yaml=$(kubectl "${kubectl_args[@]}" get role -n "$NS" -l "app.kubernetes.io/instance=$release_val" -o yaml 2>/dev/null || echo "items: []")
  local role_count; role_count=$(printf '%s' "$role_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  # Collect chart Role names for later wiring validation
  local chart_role_names=""
  local ri=0
  while [ "$ri" -lt "$role_count" ]; do
    local rname
    rname=$(printf '%s' "$role_yaml" | yq ".items[$ri].metadata.name // \"\"" 2>/dev/null || echo "")
    chart_role_names="${chart_role_names} ${rname}"
    ri=$((ri + 1))
  done
  chart_role_names="${chart_role_names# }"  # trim leading space

  # RoleBindings — release-scoped
  local rb_yaml
  rb_yaml=$(kubectl "${kubectl_args[@]}" get rolebinding -n "$NS" -l "app.kubernetes.io/instance=$release_val" -o yaml 2>/dev/null || echo "items: []")
  local rb_count; rb_count=$(printf '%s' "$rb_yaml" | yq '.items | length' 2>/dev/null || echo "0")

  local rbac_count=$((sa_count + role_count + rb_count))

  if [ "$EXPECT_PRESENT" = "true" ]; then
    if [ "$rbac_count" -eq 0 ]; then
      echo "FAIL: no release-scoped RBAC objects found in namespace '$NS' (release='$release_val')" >&2
      return 1
    fi

    # Validate RoleBinding wiring: each RoleBinding must have:
    # - roleRef pointing to a chart Role (not to a foreign/unrelated Role)
    # - subjects including the chart ServiceAccount
    local i=0
    while [ "$i" -lt "$rb_count" ]; do
      local bname rb_role_ref_name
      bname=$(printf '%s' "$rb_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")
      rb_role_ref_name=$(printf '%s' "$rb_yaml" | yq ".items[$i].roleRef.name // \"\"" 2>/dev/null || echo "")

      if [ -z "$rb_role_ref_name" ] || [ "$rb_role_ref_name" = "null" ]; then
        echo "  RoleBinding/$bname: missing roleRef" >&2
        wire_fail=$((wire_fail + 1))
      else
        # Check that roleRef.name points to one of the chart's own Roles
        local role_ref_match=0
        for crn in $chart_role_names; do
          if [ "$rb_role_ref_name" = "$crn" ]; then
            role_ref_match=1
            break
          fi
        done
        if [ "$role_ref_match" -eq 0 ]; then
          echo "  RoleBinding/$bname: roleRef.name='$rb_role_ref_name' does not match any chart Role (chart roles:$chart_role_names)" >&2
          wire_fail=$((wire_fail + 1))
        fi
      fi

      # Check subjects include the chart ServiceAccount
      local subj_count sa_in_subjects
      subj_count=$(printf '%s' "$rb_yaml" | yq ".items[$i].subjects | length" 2>/dev/null || echo "0")
      sa_in_subjects=0
      if [ "$subj_count" -gt 0 ] && [ "$subj_count" != "null" ]; then
        local si=0
        while [ "$si" -lt "$subj_count" ]; do
          local skind sname
          skind=$(printf '%s' "$rb_yaml" | yq ".items[$i].subjects[$si].kind // \"\"" 2>/dev/null || echo "")
          sname=$(printf '%s' "$rb_yaml" | yq ".items[$i].subjects[$si].name // \"\"" 2>/dev/null || echo "")
          if [ "$skind" = "ServiceAccount" ] && [ "$sname" = "$release_val" ]; then
            sa_in_subjects=1
            break
          fi
          si=$((si + 1))
        done
      fi

      if [ "$sa_in_subjects" -eq 0 ]; then
        echo "  RoleBinding/$bname: subjects do not include chart ServiceAccount '$release_val'" >&2
        wire_fail=$((wire_fail + 1))
      fi

      i=$((i + 1))
    done

    if [ "$wire_fail" -gt 0 ]; then
      echo "FAIL: $wire_fail wiring issue(s) in release-scoped RoleBindings" >&2
      return 1
    fi
    echo "PASS: $rbac_count release-scoped RBAC object(s) found ($sa_count SA, $role_count Role, $rb_count RoleBinding), wiring valid"
    return 0
  else
    # expect_present=false: only release-scoped RBAC objects matter
    if [ "$rbac_count" -gt 0 ]; then
      echo "FAIL: $rbac_count release-scoped RBAC object(s) found (expected 0): ${sa_count} SA, ${role_count} Role, ${rb_count} RoleBinding" >&2
      return 1
    fi
    echo "PASS: no release-scoped RBAC objects found (as expected)"
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
