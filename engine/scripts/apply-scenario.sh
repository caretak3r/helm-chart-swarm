#!/usr/bin/env bash
# Apply a scenario's preinstall list — helm install or kubectl apply each
# item in order, wait per spec. Assumes cluster is already up and current
# kubectl context. By default, also installs the product chart from the
# scenario's product section. Use --preinstall-only to skip product install.
#
# Supported preinstall kinds:
#   helm          — helm upgrade --install (default when kind is omitted)
#   raw_manifest  — kubectl apply -f <path> [—namespace <ns>]
#
# Usage:   apply-scenario.sh [--preinstall-only] <scenario.yaml>
# Env:     PROJECT_DIR (default: parent of scenario file's chart-test/ dir)
#          KUBE_CONTEXT (optional kubectl/helm context name to pin all calls)
set -euo pipefail

# ---- Usage banner (checked before bash version preflight so --help always works) ----
PREINSTALL_ONLY=0

usage() {
  cat <<EOF
Usage: $(basename "$0") <scenario.yaml> [OPTIONS]

Apply a scenario's preinstall list (helm charts and/or raw manifests)
to the current kubectl context, then install the product chart (unless
--preinstall-only is given). Assumes the cluster is already running.

Options:
  --help              Show this usage banner and exit
  --preinstall-only   Apply only cluster.preinstall items; skip product
                      chart install (backward compat for run-scenario.sh).

Environment:
  PROJECT_DIR  Root directory of the consumer chart project (for resolving
               relative paths). Defaults to walking up from the scenario file
               until chart-test-swarm.yaml is found.
  KUBE_CONTEXT Optional kube context; when set, all kubectl/helm calls are
               pinned to this context.
EOF
  exit 0
}

# ---- Argument parsing ----
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage ;;
    --preinstall-only) PREINSTALL_ONLY=1; shift ;;
    --*) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

# ---- Bash version preflight (VAL-ENGINE-039) ----
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "ERROR: bash >= 4 required (running ${BASH_VERSION:-unknown})." >&2
  echo "       Install modern bash: brew install bash" >&2
  echo "       Then re-run with: /opt/homebrew/bin/bash $0 $*" >&2
  exit 1
fi

SCENARIO="${1:?usage: apply-scenario.sh <scenario.yaml>}"
[ -f "$SCENARIO" ] || { echo "ERROR: scenario not found: $SCENARIO" >&2; exit 1; }
command -v yq   >/dev/null 2>&1 || { echo "ERROR: yq required (brew install yq)" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl required" >&2; exit 1; }

kubectl_ctx() {
  if [ -n "${KUBE_CONTEXT:-}" ]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

helm_ctx() {
  if [ -n "${KUBE_CONTEXT:-}" ]; then
    helm --kube-context "$KUBE_CONTEXT" "$@"
  else
    helm "$@"
  fi
}

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

  # Ensure target namespace exists (idempotent), mirroring apply_helm's namespace create.
  # Uses dry-run + apply so it's safe even when the namespace already exists.
  if [ -n "$raw_ns" ] && [ "$raw_ns" != "null" ]; then
    kubectl_ctx create namespace "$raw_ns" --dry-run=client -o yaml | kubectl_ctx apply -f - || {
      echo "ERROR: failed to ensure namespace '$raw_ns' for raw_manifest path=$resolved" >&2
      exit 1
    }
  fi

  # Build kubectl apply command.
  local kubectl_args=(apply -f "$resolved")
  if [ -n "$raw_ns" ] && [ "$raw_ns" != "null" ]; then
    kubectl_args+=(--namespace "$raw_ns")
  fi

  kubectl_ctx "${kubectl_args[@]}" || {
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
    if helm_ctx repo list 2>/dev/null | grep -q "^${repo_name}[[:space:]]"; then
      existing_url=$(helm_ctx repo list 2>/dev/null | awk -v rn="$repo_name" '$1 == rn {print $2}')
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
      helm_ctx repo add "$repo_name" "$repo_url" >/dev/null
    fi
    helm_ctx repo update "$repo_name" >/dev/null
  fi

  kubectl_ctx get ns "$ns" >/dev/null 2>&1 || kubectl_ctx create ns "$ns" >/dev/null

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

  helm_ctx "${helm_args[@]}"

  if [ "$wait_mode" = "pods-ready" ]; then
    kubectl_ctx -n "$ns" wait --for=condition=Ready pods --all --timeout="$wait_to" || {
      echo "WARN: not all pods Ready in ns/$ns after $wait_to" >&2
      kubectl_ctx -n "$ns" get pods
      exit 1
    }
  fi
}

count=$(yq '.cluster.preinstall // [] | length' "$SCENARIO")
if [ "$count" -eq 0 ]; then
  echo "==> No preinstall items; skipping addon phase"
else
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
fi

echo ""
echo "==> OK: preinstall complete"

# ---- Product chart install (unless --preinstall-only) ----
if [ "$PREINSTALL_ONLY" -eq 1 ]; then
  echo ""
  echo "==> Skipping product chart install (--preinstall-only)"
  exit 0
fi

echo ""
echo "==> Installing product chart"

# Read product section from scenario YAML
PRODUCT_CHART=$(yq    '.product.chart'     "$SCENARIO")
PRODUCT_RELEASE=$(yq  '.product.release'   "$SCENARIO")
PRODUCT_NS=$(yq       '.product.namespace' "$SCENARIO")
PRODUCT_VALUES=$(yq   '.product.values // ""' "$SCENARIO")

# Resolve chart path relative to PROJECT_DIR (respects PROJECT_DIR for ./chart etc.)
PCHART=$(resolve_path "$PRODUCT_CHART")

# Fail fast with named error if chart is not resolvable
if [ ! -e "$PCHART" ]; then
  case "$PRODUCT_CHART" in
    oci://*|https://*|http://*) ;;
    *)
      echo "ERROR: product.chart not found: $PRODUCT_CHART (resolved: $PCHART)" >&2
      echo "       Ensure PROJECT_DIR is set correctly and the chart exists." >&2
      exit 1
      ;;
  esac
fi

echo "==> Chart:  $PRODUCT_CHART (resolved: $PCHART)"
echo "==> Release: $PRODUCT_RELEASE in ns/$PRODUCT_NS"

# Ensure product namespace exists
kubectl_ctx get ns "$PRODUCT_NS" >/dev/null 2>&1 || kubectl_ctx create ns "$PRODUCT_NS" >/dev/null

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm required" >&2; exit 1; }

helm_args=(upgrade --install "$PRODUCT_RELEASE" "$PCHART" --namespace "$PRODUCT_NS" --create-namespace --wait --timeout 5m)

# Handle product.values file
if [ -n "$PRODUCT_VALUES" ] && [ "$PRODUCT_VALUES" != "null" ]; then
  vpath=$(resolve_path "$PRODUCT_VALUES")
  [ -f "$vpath" ] || { echo "ERROR: product.values file missing: $vpath" >&2; exit 1; }
  helm_args+=(-f "$vpath")
fi

# Handle product.set inline values
set_count=$(yq '.product.set // {} | length' "$SCENARIO")
if [ "$set_count" -gt 0 ]; then
  while IFS=$'\t' read -r k v; do
    helm_args+=(--set "$k=$v")
  done < <(yq -o=tsv '.product.set // {} | to_entries | map([.key, .value]) | .[]' "$SCENARIO")
fi

echo "    helm: ${helm_args[*]}"
helm_ctx "${helm_args[@]}" || {
  echo "ERROR: product chart install failed" >&2
  exit 1
}

echo ""
echo "==> OK: product chart installed"
