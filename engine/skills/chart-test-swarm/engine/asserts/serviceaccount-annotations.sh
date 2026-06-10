#!/usr/bin/env bash
# DEPTH: L1
# Assert: serviceaccount-annotations — validates presence or absence of
# cloud-identity annotations (IRSA, Azure workload identity, GKE WI)
# on the chart's ServiceAccount.
# When expect_present=true, asserts that the rendered ServiceAccount carries
# the configured annotations with the exact key/value pairs.
# When expect_present=false, asserts that the ServiceAccount does NOT carry
# any of the specified cloud-identity annotation keys.
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

# Expected annotations (from scenario assert config)
ANNOTATIONS_JSON=$(yq ".asserts[$IDX].annotations // {}" -o json "$SCENARIO")
# Cloud-identity keys to check for absence (used when expect_present=false)
IDENTITY_KEYS_JSON=$(yq ".asserts[$IDX].identity_keys // []" -o json "$SCENARIO")

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

rendered_file=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() { [ -n "$rendered_file" ] && [ -f "$rendered_file" ] && rm -f "$rendered_file"; }
trap cleanup EXIT

render_helm_template() {
  rendered_file=$(mktemp /tmp/cap-sa-ann-rendered.XXXXXX.yaml)
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

check_rendered_sa_annotations() {
  local doc_count=0 sa_count=0 fail_count=0
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

    if [ "$kind_val" != "ServiceAccount" ]; then
      di=$((di + 1)); continue
    fi

    sa_count=$((sa_count + 1))

    if [ "$EXPECT_PRESENT" = "true" ]; then
      # Check that each configured annotation is present with the right value

      if [ "$ANNOTATIONS_JSON" != "{}" ] && [ "$ANNOTATIONS_JSON" != "null" ]; then
        while IFS= read -r akey; do
          local expected_aval
          expected_aval=$(printf '%s' "$ANNOTATIONS_JSON" | jq -r --arg k "$akey" '.[$k]')
          local actual_aval
          # Handle annotation keys with dots (e.g. eks.amazonaws.com/role-arn)
          actual_aval=$(yq "select(di == $di) | .metadata.annotations[\"$akey\"] // \"__ABSENT__\"" "$rendered_file" 2>/dev/null || echo "__ABSENT__")
          if [ "$actual_aval" = "__ABSENT__" ]; then
            echo "  ServiceAccount/$name_val: missing annotation '$akey'" >&2
            fail_count=$((fail_count + 1))
          elif [ "$actual_aval" != "$expected_aval" ]; then
            echo "  ServiceAccount/$name_val: annotation '$akey' expected='$expected_aval' actual='$actual_aval'" >&2
            fail_count=$((fail_count + 1))
          fi
        done < <(printf '%s' "$ANNOTATIONS_JSON" | jq -r 'keys[]')
      fi
    else
      # expect_present=false: specified cloud-identity keys must NOT be present

      # Check identity_keys list
      if [ "$IDENTITY_KEYS_JSON" != "[]" ] && [ "$IDENTITY_KEYS_JSON" != "null" ]; then
        while IFS= read -r ikey; do
          local val
          val=$(yq "select(di == $di) | .metadata.annotations[\"$ikey\"] // \"__ABSENT__\"" "$rendered_file" 2>/dev/null || echo "__ABSENT__")
          if [ "$val" != "__ABSENT__" ]; then
            echo "  ServiceAccount/$name_val: unexpected identity annotation '$ikey' present" >&2
            fail_count=$((fail_count + 1))
          fi
        done < <(printf '%s' "$IDENTITY_KEYS_JSON" | jq -r '.[]')
      fi
    fi
    di=$((di + 1))
  done

  if [ "$EXPECT_PRESENT" = "true" ] && [ "$sa_count" -eq 0 ]; then
    echo "FAIL: no ServiceAccount found in rendered output — chart lacks ServiceAccount template (documented gap)" >&2
    return 1
  fi

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count ServiceAccount annotation check(s) failed" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: ServiceAccount annotations present on $sa_count ServiceAccount(s)"
  else
    if [ "$sa_count" -eq 0 ]; then
      echo "PASS: no ServiceAccount rendered (vacuously satisfies absence of identity annotations)"
    else
      echo "PASS: no cloud-identity annotations on $sa_count ServiceAccount(s)"
    fi
  fi
  return 0
}

check_live_sa_annotations() {
  local sa_count=0 fail_count=0

  # Get ServiceAccounts excluding the auto-created "default"
  local sa_yaml
  sa_yaml=$(kubectl "${kubectl_args[@]}" get sa -n "$NS" -o yaml 2>/dev/null || echo "items: []")
  sa_count=$(printf '%s' "$sa_yaml" | yq '[.items[] | select(.metadata.name != "default")] | length' 2>/dev/null || echo "0")

  if [ "$EXPECT_PRESENT" = "true" ] && [ "$sa_count" -eq 0 ]; then
    echo "FAIL: no live ServiceAccount found — chart lacks ServiceAccount template (documented gap)" >&2
    return 1
  fi

  local j=0
  while [ "$j" -lt "$sa_count" ]; do
    local sa_name
    sa_name=$(printf '%s' "$sa_yaml" | yq '[.items[] | select(.metadata.name != "default")]['"$j"'].metadata.name // ""' 2>/dev/null || echo "")

    if [ "$EXPECT_PRESENT" = "true" ]; then
      if [ "$ANNOTATIONS_JSON" != "{}" ] && [ "$ANNOTATIONS_JSON" != "null" ]; then
        while IFS= read -r akey; do
          local expected_aval
          expected_aval=$(printf '%s' "$ANNOTATIONS_JSON" | jq -r --arg k "$akey" '.[$k]')
          local actual_aval
          actual_aval=$(printf '%s' "$sa_yaml" | yq '[.items[] | select(.metadata.name != "default")]['"$j"'].metadata.annotations["'"$akey"'"] // "__ABSENT__"' 2>/dev/null || echo "__ABSENT__")
          if [ "$actual_aval" = "__ABSENT__" ]; then
            echo "  ServiceAccount/$sa_name: missing annotation '$akey'" >&2
            fail_count=$((fail_count + 1))
          elif [ "$actual_aval" != "$expected_aval" ]; then
            echo "  ServiceAccount/$sa_name: annotation '$akey' expected='$expected_aval' actual='$actual_aval'" >&2
            fail_count=$((fail_count + 1))
          fi
        done < <(printf '%s' "$ANNOTATIONS_JSON" | jq -r 'keys[]')
      fi
    else
      if [ "$IDENTITY_KEYS_JSON" != "[]" ] && [ "$IDENTITY_KEYS_JSON" != "null" ]; then
        while IFS= read -r ikey; do
          local val
          val=$(printf '%s' "$sa_yaml" | yq '[.items[] | select(.metadata.name != "default")]['"$j"'].metadata.annotations["'"$ikey"'"] // "__ABSENT__"' 2>/dev/null || echo "__ABSENT__")
          if [ "$val" != "__ABSENT__" ]; then
            echo "  ServiceAccount/$sa_name: unexpected identity annotation '$ikey' present" >&2
            fail_count=$((fail_count + 1))
          fi
        done < <(printf '%s' "$IDENTITY_KEYS_JSON" | jq -r '.[]')
      fi
    fi
    j=$((j + 1))
  done

  if [ "$fail_count" -gt 0 ]; then
    echo "FAIL: $fail_count live ServiceAccount annotation check(s) failed" >&2
    return 1
  fi

  if [ "$EXPECT_PRESENT" = "true" ]; then
    echo "PASS: ServiceAccount annotations present on $sa_count live ServiceAccount(s)"
  else
    if [ "$sa_count" -eq 0 ]; then
      echo "PASS: no live ServiceAccount (vacuously satisfies absence)"
    else
      echo "PASS: no cloud-identity annotations on $sa_count live ServiceAccount(s)"
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
  elif ! check_rendered_sa_annotations; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_sa_annotations; then overall=1; fi
fi
exit "$overall"
