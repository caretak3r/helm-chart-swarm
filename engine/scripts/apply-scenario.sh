#!/usr/bin/env bash
# Apply a scenario's preinstall list — helm install or kubectl apply each
# item in order, wait per spec. Assumes cluster is already up and current
# kubectl context.
#
# Supported preinstall kinds:
#   helm          — helm upgrade --install (default when kind is omitted)
#   raw_manifest  — kubectl apply -f <path> [—namespace <ns>]
#
# Usage:   apply-scenario.sh <scenario.yaml>
# Env:     PROJECT_DIR (default: parent of scenario file's chart-test/ dir)
set -euo pipefail

SCENARIO="${1:?usage: apply-scenario.sh <scenario.yaml>}"
[ -f "$SCENARIO" ] || { echo "ERROR: scenario not found: $SCENARIO" >&2; exit 1; }
command -v yq   >/dev/null 2>&1 || { echo "ERROR: yq required (brew install yq)" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl required" >&2; exit 1; }

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

# Temp files to clean up on exit — tracks all mktemp files so we never leak.
_CTS_TEMPFILES=()
cts_cleanup_tempfiles() {
  for f in "${_CTS_TEMPFILES[@]+"${_CTS_TEMPFILES[@]}"}"; do
    rm -f "$f" 2>/dev/null || true
  done
}
# Trap EXIT, INT, TERM so tempfiles are cleaned up even on SIGTERM mid-loop
trap 'cts_cleanup_tempfiles' EXIT INT TERM

count=$(yq '.cluster.preinstall // [] | length' "$SCENARIO")
if [ "$count" -eq 0 ]; then
  echo "==> No preinstall items; skipping addon phase"
  exit 0
fi

resolve_path() {
  # Make a path absolute, relative to PROJECT_DIR if it isn't already.
  # URLs (http://, https://) are returned as-is.
  case "$1" in
    http://*|https://*) echo "$1" ;;
    /*) echo "$1" ;;
    *)  echo "$PROJECT_DIR/$1" ;;
  esac
}

# Apply a raw_manifest preinstall item via kubectl apply -f.
# Arguments:
#   $1  item index
# Precondition: the preinstall item at index $1 has kind=raw_manifest.
apply_raw_manifest() {
  local i="$1"
  local manifest_path raw_ns
  manifest_path=$(yq ".cluster.preinstall[$i].path" "$SCENARIO")
  raw_ns=$(yq ".cluster.preinstall[$i].namespace // \"\"" "$SCENARIO")

  if [ -z "$manifest_path" ] || [ "$manifest_path" = "null" ]; then
    local scen_id
    scen_id=$(yq '.id' "$SCENARIO")
    echo "ERROR: scenario '$scen_id' preinstall[$i] (kind: raw_manifest) missing required 'path' field" >&2
    exit 1
  fi

  # Resolve path (may be a URL or a local file).
  local resolved
  resolved=$(resolve_path "$manifest_path")

  # For local files, verify existence before we touch the cluster.
  case "$resolved" in
    http://*|https://*) ;;
    *)
      if [ ! -f "$resolved" ]; then
        local scen_id
        scen_id=$(yq '.id' "$SCENARIO")
        echo "ERROR: scenario '$scen_id' preinstall[$i] (kind: raw_manifest) path not found: $resolved" >&2
        exit 1
      fi
      ;;
  esac

  echo "    raw_manifest: $manifest_path${raw_ns:+ in ns/$raw_ns}"

  # Build kubectl apply command.
  local kubectl_args=(apply -f "$resolved")
  if [ -n "$raw_ns" ] && [ "$raw_ns" != "null" ]; then
    kubectl_args+=(--namespace "$raw_ns")
  fi

  kubectl "${kubectl_args[@]}" || {
    echo "ERROR: kubectl apply failed for raw_manifest path=$resolved" >&2
    exit 1
  }
}

# Apply a helm preinstall item via helm upgrade --install.
# Arguments:
#   $1  item index
# Precondition: the preinstall item at index $1 has kind=helm (or kind omitted).
apply_helm() {
  local i="$1"
  local chart version release ns wait_mode wait_to repo_name repo_url values_node

  chart=$(yq   ".cluster.preinstall[$i].chart"                        "$SCENARIO")
  version=$(yq ".cluster.preinstall[$i].version // \"\""              "$SCENARIO")
  release=$(yq ".cluster.preinstall[$i].release"                      "$SCENARIO")
  ns=$(yq      ".cluster.preinstall[$i].namespace"                    "$SCENARIO")
  wait_mode=$(yq ".cluster.preinstall[$i].wait // \"pods-ready\""     "$SCENARIO")
  wait_to=$(yq   ".cluster.preinstall[$i].wait_timeout // \"5m\""     "$SCENARIO")
  repo_name=$(yq ".cluster.preinstall[$i].repo.name // \"\""          "$SCENARIO")
  repo_url=$(yq  ".cluster.preinstall[$i].repo.url  // \"\""          "$SCENARIO")
  values_node=$(yq ".cluster.preinstall[$i].values // \"\""           "$SCENARIO")

  echo "    helm: $release ($chart${version:+ @ $version}) in ns/$ns"

  command -v helm >/dev/null 2>&1 || { echo "ERROR: helm required" >&2; exit 1; }

  if [ -n "$repo_name" ] && [ -n "$repo_url" ]; then
    # Idempotent helm repo add (VAL-ENGINE-032):
    # If the repo already exists with the same URL, that's fine (no error).
    # If it exists with a DIFFERENT URL, that's an error — refuse with named details.
    if helm repo list 2>/dev/null | grep -q "^${repo_name}[[:space:]]"; then
      existing_url=$(helm repo list 2>/dev/null | awk -v rn="$repo_name" '$1 == rn {print $2}')
      if [ "$existing_url" = "$repo_url" ]; then
        # Same repo+URL — idempotent no-op (informational, not an error)
        echo "    repo '$repo_name' already exists with URL $repo_url (skipping add)"
      else
        echo "ERROR: helm repo '$repo_name' already exists with different URL" >&2
        echo "       existing: $existing_url" >&2
        echo "       requested: $repo_url" >&2
        exit 1
      fi
    else
      helm repo add "$repo_name" "$repo_url" >/dev/null
    fi
    helm repo update "$repo_name" >/dev/null
  fi

  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns" >/dev/null

  # Values handling: file path (string) vs inline object.
  local values_args=()
  if [ -n "$values_node" ] && [ "$values_node" != "null" ]; then
    local kind_of
    kind_of=$(yq ".cluster.preinstall[$i].values | type" "$SCENARIO")
    if [ "$kind_of" = "!!str" ]; then
      local vpath
      vpath=$(resolve_path "$values_node")
      [ -f "$vpath" ] || { echo "ERROR: values file missing: $vpath" >&2; exit 1; }
      values_args+=(-f "$vpath")
    else
      # Inline object — write to a temp file
      local tmp
      tmp=$(mktemp)
      _CTS_TEMPFILES+=("$tmp")
      yq ".cluster.preinstall[$i].values" "$SCENARIO" > "$tmp"
      values_args+=(-f "$tmp")
    fi
  fi

  local helm_args=(upgrade --install "$release" "$chart" --namespace "$ns" --create-namespace)
  [ -n "$version" ] && [ "$version" != "null" ] && helm_args+=(--version "$version")
  helm_args+=("${values_args[@]+"${values_args[@]}"}")

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
}

echo "==> Applying $count preinstall item(s)"
for i in $(seq 0 $((count - 1))); do
  # Determine kind — defaults to "helm" for backward compatibility.
  item_kind=$(yq ".cluster.preinstall[$i].kind // \"helm\"" "$SCENARIO")

  echo ""
  echo "==> [$((i+1))/$count] kind=$item_kind"

  case "$item_kind" in
    helm)
      apply_helm "$i"
      ;;
    raw_manifest)
      apply_raw_manifest "$i"
      ;;
    *)
      scen_id=$(yq '.id' "$SCENARIO")
      echo "ERROR: scenario '$scen_id' preinstall[$i] has unknown kind '$item_kind'; expected 'helm' or 'raw_manifest'" >&2
      exit 1
      ;;
  esac
done

echo ""
echo "==> OK: preinstall complete"
