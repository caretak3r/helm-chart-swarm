#!/usr/bin/env bash
# Apply a scenario's preinstall list — helm install each addon in order,
# wait per spec. Assumes cluster is already up and current kubectl context.
#
# Usage:   apply-scenario.sh <scenario.yaml>
# Env:     PROJECT_DIR (default: parent of scenario file's chart-test/ dir)
set -euo pipefail

SCENARIO="${1:?usage: apply-scenario.sh <scenario.yaml>}"
[ -f "$SCENARIO" ] || { echo "ERROR: scenario not found: $SCENARIO" >&2; exit 1; }
command -v yq   >/dev/null 2>&1 || { echo "ERROR: yq required (brew install yq)" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "ERROR: helm required" >&2; exit 1; }

# Resolve PROJECT_DIR — walk up from the scenario file until we hit
# chart-test-swarm.yaml. Lets values/paths be repo-relative.
resolve_project_dir() {
  local d; d="$(cd "$(dirname "$SCENARIO")" && pwd)"
  while [ "$d" != "/" ]; do
    [ -f "$d/chart-test-swarm.yaml" ] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  # Fallback: parent of chart-test/scenarios/
  local s; s="$(cd "$(dirname "$SCENARIO")" && pwd)"
  echo "$(cd "$s/../.." && pwd)"
}
PROJECT_DIR="${PROJECT_DIR:-$(resolve_project_dir)}"
[ -d "$PROJECT_DIR" ] || { echo "ERROR: PROJECT_DIR not a dir: $PROJECT_DIR" >&2; exit 1; }
echo "==> PROJECT_DIR=$PROJECT_DIR"

count=$(yq '.cluster.preinstall // [] | length' "$SCENARIO")
if [ "$count" -eq 0 ]; then
  echo "==> No preinstall items; skipping addon phase"
  exit 0
fi

resolve_path() {
  # Make a path absolute, relative to PROJECT_DIR if it isn't already.
  case "$1" in
    /*) echo "$1" ;;
    *)  echo "$PROJECT_DIR/$1" ;;
  esac
}

echo "==> Applying $count preinstall item(s)"
for i in $(seq 0 $((count - 1))); do
  chart=$(yq ".cluster.preinstall[$i].chart"     "$SCENARIO")
  version=$(yq ".cluster.preinstall[$i].version // \"\""   "$SCENARIO")
  release=$(yq ".cluster.preinstall[$i].release"   "$SCENARIO")
  ns=$(yq      ".cluster.preinstall[$i].namespace" "$SCENARIO")
  wait_mode=$(yq ".cluster.preinstall[$i].wait // \"pods-ready\"" "$SCENARIO")
  wait_to=$(yq   ".cluster.preinstall[$i].wait_timeout // \"5m\"" "$SCENARIO")
  repo_name=$(yq ".cluster.preinstall[$i].repo.name // \"\""      "$SCENARIO")
  repo_url=$(yq  ".cluster.preinstall[$i].repo.url  // \"\""      "$SCENARIO")
  values_node=$(yq ".cluster.preinstall[$i].values // \"\""       "$SCENARIO")

  echo ""
  echo "==> [$((i+1))/$count] $release ($chart${version:+ @ $version}) in ns/$ns"

  if [ -n "$repo_name" ] && [ -n "$repo_url" ]; then
    helm repo add "$repo_name" "$repo_url" >/dev/null
    helm repo update "$repo_name" >/dev/null
  fi

  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns" >/dev/null

  # Values handling: file path (string) vs inline object.
  values_args=()
  if [ -n "$values_node" ] && [ "$values_node" != "null" ]; then
    kind_of=$(yq ".cluster.preinstall[$i].values | type" "$SCENARIO")
    if [ "$kind_of" = "!!str" ]; then
      vpath=$(resolve_path "$values_node")
      [ -f "$vpath" ] || { echo "ERROR: values file missing: $vpath" >&2; exit 1; }
      values_args+=(-f "$vpath")
    else
      # Inline object — write to a temp file
      tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
      yq ".cluster.preinstall[$i].values" "$SCENARIO" > "$tmp"
      values_args+=(-f "$tmp")
    fi
  fi

  helm_args=(upgrade --install "$release" "$chart" --namespace "$ns" --create-namespace)
  [ -n "$version" ] && [ "$version" != "null" ] && helm_args+=(--version "$version")
  helm_args+=("${values_args[@]}")

  case "$wait_mode" in
    none)           ;;
    helm-deployed)  helm_args+=(--wait --timeout "$wait_to") ;;
    pods-ready)     helm_args+=(--wait --timeout "$wait_to") ;;
    *) echo "ERROR: unknown wait mode '$wait_mode'" >&2; exit 1 ;;
  esac

  helm "${helm_args[@]}"

  if [ "$wait_mode" = "pods-ready" ]; then
    kubectl -n "$ns" wait --for=condition=Ready pods --all --timeout="$wait_to" || {
      echo "WARN: not all pods Ready in ns/$ns after $wait_to" >&2
      kubectl -n "$ns" get pods
      exit 1
    }
  fi
done

echo ""
echo "==> OK: preinstall complete"
