#!/usr/bin/env bash
# DEPTH: L1
# Assert: scheme-enforced — the capability enforces HTTPS-only (no HTTP port 80
# exposed) or allows HTTP baseline. Introspects helm template output and/or live
# kubectl get -o yaml. Returns {status: PASS|FAIL, detail} via exit code + stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/assert-helpers.sh
source "$SCRIPT_DIR/lib/assert-helpers.sh"

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
SOURCE=$(yq ".asserts[$IDX].source // \"both\"" "$SCENARIO")
SCHEME=$(yq ".asserts[$IDX].scheme" "$SCENARIO")
RELEASE="${RELEASE:-$(yq '.product.release' "$SCENARIO")}"

if [ "$SCHEME" != "https-only" ] && [ "$SCHEME" != "allow-http" ]; then
  echo "FAIL: scheme must be 'https-only' or 'allow-http', got '$SCHEME'" >&2
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
  rendered_file="$(mktemp /tmp/cap-scheme-rendered-XXXXXX)"
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

check_rendered_scheme() {
  local doc_count=0
  doc_count=$(yq '.kind // ""' "$rendered_file" 2>/dev/null | grep -cv '^$\|^null$\|^---$')
  if [ "$doc_count" -eq 0 ]; then
    echo "FAIL: no documents found in rendered output" >&2
    return 1
  fi

  local http_violations=0 http_found=0

  local di=0
  while [ "$di" -lt "$doc_count" ]; do
    local kind_val name_val
    kind_val=$(yq "select(di == $di) | .kind // \"\"" "$rendered_file" 2>/dev/null || echo "")
    name_val=$(yq "select(di == $di) | .metadata.name // \"\"" "$rendered_file" 2>/dev/null || echo "")

    if [ -z "$kind_val" ] || [ "$kind_val" = "null" ]; then
      di=$((di + 1)); continue
    fi

    case "$kind_val" in
      Service)
        # Check for port 80 in service spec.ports
        local port_line
        port_line=$(yq "select(di == $di) | .spec.ports[] | select(.port == 80) | .port" "$rendered_file" 2>/dev/null || echo "")
        if [ -n "$port_line" ]; then
          http_found=$((http_found + 1))
          if [ "$SCHEME" = "https-only" ]; then
            echo "  HTTP port 80 on Service/$name_val" >&2
            http_violations=$((http_violations + 1))
          fi
        fi
        ;;
      Deployment|StatefulSet|DaemonSet|Job|ReplicaSet)
        # Check container ports for port 80
        local ctr_port
        ctr_port=$(yq "select(di == $di) | .spec.template.spec.containers[].ports[] | select(.containerPort == 80) | .containerPort" "$rendered_file" 2>/dev/null || echo "")
        if [ -n "$ctr_port" ]; then
          http_found=$((http_found + 1))
          if [ "$SCHEME" = "https-only" ]; then
            echo "  HTTP containerPort 80 on $kind_val/$name_val" >&2
            http_violations=$((http_violations + 1))
          fi
        fi
        # Check httpGet probes on port 80
        local probe_port
        probe_port=$(yq "select(di == $di) | [.spec.template.spec.containers[].livenessProbe.httpGet.port, .spec.template.spec.containers[].readinessProbe.httpGet.port, .spec.template.spec.containers[].startupProbe.httpGet.port] | flatten | .[] | select(. == 80)" "$rendered_file" 2>/dev/null || echo "")
        if [ -n "$probe_port" ]; then
          http_found=$((http_found + 1))
          if [ "$SCHEME" = "https-only" ]; then
            echo "  HTTP httpGet probe on port 80 on $kind_val/$name_val" >&2
            http_violations=$((http_violations + 1))
          fi
        fi
        ;;
      Ingress)
        # Check for http rules
        local http_rules
        http_rules=$(yq "select(di == $di) | .spec.rules[] | select(.http != null) | .http" "$rendered_file" 2>/dev/null || echo "")
        if [ -n "$http_rules" ]; then
          http_found=$((http_found + 1))
          if [ "$SCHEME" = "https-only" ]; then
            echo "  HTTP rule on Ingress/$name_val" >&2
            http_violations=$((http_violations + 1))
          fi
        fi
        ;;
    esac
    di=$((di + 1))
  done

  if [ "$SCHEME" = "https-only" ]; then
    if [ "$http_violations" -gt 0 ]; then
      echo "FAIL: $http_violations HTTP exposure(s) found (scheme=https-only)" >&2
      return 1
    fi
    echo "PASS: no HTTP port 80 exposure found (scheme=https-only)"
    return 0
  else
    # allow-http: must have at least one HTTP port
    if [ "$http_found" -eq 0 ]; then
      echo "FAIL: no HTTP port 80 found (scheme=allow-http requires at least one)" >&2
      return 1
    fi
    echo "PASS: HTTP port 80 found ($http_found instance(s)), scheme=allow-http satisfied"
    return 0
  fi
}

check_live_scheme() {
  local http_violations=0 http_found=0

  # Check Service — release-scoped
  local svc_yaml
  svc_yaml=$(kubectl "${kubectl_args[@]}" get svc -n "$NS" -l "app.kubernetes.io/instance=${RELEASE}" -o yaml 2>/dev/null || echo "items: []")
  local svc_count; svc_count=$(printf '%s' "$svc_yaml" | yq '.items | length' 2>/dev/null || echo "0")
  local i=0
  while [ "$i" -lt "$svc_count" ]; do
    local sname; sname=$(printf '%s' "$svc_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")
    local port80; port80=$(printf '%s' "$svc_yaml" | yq ".items[$i].spec.ports[] | select(.port == 80) | .port" 2>/dev/null || echo "")
    if [ -n "$port80" ]; then
      http_found=$((http_found + 1))
      if [ "$SCHEME" = "https-only" ]; then echo "  HTTP port 80 on Service/$sname" >&2; http_violations=$((http_violations + 1)); fi
    fi
    i=$((i + 1))
  done

  # Check Deployment container ports — release-scoped
  local dep_yaml
  dep_yaml=$(kubectl "${kubectl_args[@]}" get deploy -n "$NS" -l "app.kubernetes.io/instance=${RELEASE}" -o yaml 2>/dev/null || echo "items: []")
  local dep_count; dep_count=$(printf '%s' "$dep_yaml" | yq '.items | length' 2>/dev/null || echo "0")
  i=0
  while [ "$i" -lt "$dep_count" ]; do
    local dname; dname=$(printf '%s' "$dep_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")
    local cport; cport=$(printf '%s' "$dep_yaml" | yq ".items[$i].spec.template.spec.containers[].ports[] | select(.containerPort == 80) | .containerPort" 2>/dev/null || echo "")
    if [ -n "$cport" ]; then
      http_found=$((http_found + 1))
      if [ "$SCHEME" = "https-only" ]; then echo "  HTTP containerPort 80 on Deployment/$dname" >&2; http_violations=$((http_violations + 1)); fi
    fi
    i=$((i + 1))
  done

  # Check Ingress — release-scoped
  local ing_yaml
  ing_yaml=$(kubectl "${kubectl_args[@]}" get ingress -n "$NS" -l "app.kubernetes.io/instance=${RELEASE}" -o yaml 2>/dev/null || echo "items: []")
  local ing_count; ing_count=$(printf '%s' "$ing_yaml" | yq '.items | length' 2>/dev/null || echo "0")
  i=0
  while [ "$i" -lt "$ing_count" ]; do
    local iname; iname=$(printf '%s' "$ing_yaml" | yq ".items[$i].metadata.name // \"\"" 2>/dev/null || echo "")
    local hrules; hrules=$(printf '%s' "$ing_yaml" | yq ".items[$i].spec.rules[] | select(.http != null) | .http" 2>/dev/null || echo "")
    if [ -n "$hrules" ]; then
      http_found=$((http_found + 1))
      if [ "$SCHEME" = "https-only" ]; then echo "  HTTP rule on Ingress/$iname" >&2; http_violations=$((http_violations + 1)); fi
    fi
    i=$((i + 1))
  done

  if [ "$SCHEME" = "https-only" ]; then
    if [ "$http_violations" -gt 0 ]; then echo "FAIL: $http_violations HTTP exposure(s) in live objects" >&2; return 1; fi
    echo "PASS: no HTTP port 80 exposure in live objects (scheme=https-only)"
    return 0
  else
    if [ "$http_found" -eq 0 ]; then echo "FAIL: no HTTP port 80 in live objects (scheme=allow-http)" >&2; return 1; fi
    echo "PASS: HTTP port 80 found in live objects ($http_found instance(s)), scheme=allow-http"
    return 0
  fi
}

overall=0
if [ "$SOURCE" = "rendered" ] || [ "$SOURCE" = "both" ]; then
  render_helm_template
  if [ ! -s "$rendered_file" ]; then
    echo "FAIL: helm template produced no output" >&2
    overall=1
  elif ! check_rendered_scheme; then
    overall=1
  fi
fi
if [ "$SOURCE" = "live" ] || [ "$SOURCE" = "both" ]; then
  if ! check_live_scheme; then overall=1; fi
fi
exit "$overall"
