#!/usr/bin/env bash
# Run ONE scenario end-to-end: cluster up → preinstall → product chart → asserts.
# Emits result.yaml + artifacts/ bundle under $REPORTS_DIR/scenario-<id>-<ts>/.
#
# Artifact bundle (self-contained for re-application from artifacts alone):
#   artifacts/scenario.yaml           — scenario with bundle-relative paths (./chart, ./fixtures/<name>)
#   artifacts/chart/                  — vendored Helm chart (verbatim copy from source)
#   artifacts/applied-overrides.yaml  — helm_values map (single merged) + raw_manifest_refs seq
#   artifacts/fixtures/               — byte-identical copies of ALL referenced fixture files
#   artifacts/manifests/              — kubectl get -o yaml dumps of created resources
#   artifacts/versions.json           — {helm, kubectl, kind, minikube, k8s_server}
#   artifacts/logs/                   — all captured logs
#
# Usage:   run-scenario.sh <scenario.yaml>
# Env:
#   KEEP_CLUSTER=1     keep cluster on success (default)
#   KEEP_CLUSTER=0     tear down cluster on success
#   KEEP_ON_FAILURE=0  tear down on failure/signal (default)
#   KEEP_ON_FAILURE=1  keep cluster on failure/signal for debugging
#   REPORTS_DIR      override reports root (default: $PROJECT_DIR/chart-test/reports
#                    if PROJECT_DIR has chart-test/, else $ROOT_DIR/reports)
set -euo pipefail

# ---- Usage banner (checked before bash version preflight so --help always works) ----
usage() {
  cat <<EOF
Usage: $(basename "$0") <scenario.yaml> [OPTIONS]

Run a single scenario end-to-end: cluster up → preinstall → product chart → asserts.
Emits result.yaml + artifacts/ bundle under the reports directory.

Options:
  --help    Show this usage banner and exit

Environment:
  KEEP_CLUSTER      1 = keep cluster after successful run (default), 0 = tear down
  KEEP_ON_FAILURE   1 = keep cluster on failure/signal, 0 = tear down (default)
  REPORTS_DIR    Override reports root directory
  PROJECT_DIR    Consumer chart project root (for path resolution)
  CLUSTER_NAME   Cluster name (must match ^chart-test-swarm-[a-z0-9-]+\$)
  PROVIDER       Cluster provider: kind|minikube|k3d (from scenario YAML)
EOF
  exit 0
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
fi

# ---- Bash version preflight (VAL-ENGINE-039) ----
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "ERROR: bash >= 4 required (running ${BASH_VERSION:-unknown})." >&2
  echo "       Install modern bash: brew install bash" >&2
  echo "       Then re-run with: /opt/homebrew/bin/bash $0 $*" >&2
  exit 1
fi

SCENARIO="${1:?usage: run-scenario.sh <scenario.yaml>}"
[ -f "$SCENARIO" ] || { echo "ERROR: scenario not found: $SCENARIO" >&2; exit 1; }
command -v yq   >/dev/null 2>&1 || { echo "ERROR: yq required" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "ERROR: helm required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
ASSERTS_DIR="$ENGINE_DIR/asserts"

ORIGINAL_KUBE_CONTEXT="$(kubectl config current-context 2>/dev/null || echo "")"
restore_original_context() {
  if [ -n "${ORIGINAL_KUBE_CONTEXT:-}" ]; then
    current="$(kubectl config current-context 2>/dev/null || echo "")"
    if [ "$current" != "$ORIGINAL_KUBE_CONTEXT" ]; then
      kubectl config use-context "$ORIGINAL_KUBE_CONTEXT" >/dev/null 2>&1 || true
    fi
  fi
}
trap 'restore_original_context' EXIT

# Default cluster name satisfies ^chart-test-swarm-[a-z0-9-]+$
CLUSTER_NAME="${CLUSTER_NAME:-chart-test-swarm-default}"
# KEEP_CLUSTER=1 means keep cluster (default), =0 means tear it down.
KEEP_CLUSTER="${KEEP_CLUSTER:-1}"
# KEEP_ON_FAILURE=0 means tear down on failure/signal by default.
KEEP_ON_FAILURE="${KEEP_ON_FAILURE:-0}"
export KEEP_CLUSTER
export KEEP_ON_FAILURE

# Interrupt guard: prevents fail() from overwriting INTERRUPTED with FAIL
# when set -e races the SIGINT trap handler (VAL-ENGINE-027).
_interrupted=0

# Source the shared prefix guard — exits 1 if CLUSTER_NAME doesn't match ^chart-test-swarm-[a-z0-9-]+$
. "$SCRIPT_DIR/lib/prefix-check.sh"

# Resolve PROJECT_DIR (same logic as apply-scenario.sh; could share but keep
# explicit for greppability).
resolve_project_dir() {
  local d; d="$(cd "$(dirname "$SCENARIO")" && pwd)"
  while [ "$d" != "/" ]; do
    [ -f "$d/chart-test-swarm.yaml" ] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  local s; s="$(cd "$(dirname "$SCENARIO")" && pwd)"
  echo "$(cd "$s/../.." && pwd)"
}
PROJECT_DIR="${PROJECT_DIR:-$(resolve_project_dir)}"
export PROJECT_DIR

resolve_path() {
  case "$1" in /*) echo "$1" ;; *) echo "$PROJECT_DIR/$1" ;; esac
}

SCEN_ID=$(yq   '.id'              "$SCENARIO")
PROVIDER=$(yq  '.cluster.provider' "$SCENARIO")
K8S_VER=$(yq  '.cluster.k8s_version // ""' "$SCENARIO")
KIND_CFG=$(yq  '.cluster.config // ""'      "$SCENARIO")
PRODUCT_CHART=$(yq    '.product.chart'     "$SCENARIO")
PRODUCT_RELEASE=$(yq  '.product.release'   "$SCENARIO")
PRODUCT_NS=$(yq       '.product.namespace' "$SCENARIO")
PRODUCT_VALUES=$(yq   '.product.values // ""' "$SCENARIO")

# ---- Cilium CNI config ----
CNI_PROVIDER=$(yq      '.cluster.cni.provider // ""'               "$SCENARIO")
CNI_VERSION=$(yq       '.cluster.cni.version // ""'                "$SCENARIO")
CNI_VALUES=$(yq        '.cluster.cni.values // ""'                 "$SCENARIO")
CNI_KPR=$(yq           '.cluster.cni.kube_proxy_replacement // ""' "$SCENARIO")
CTS_CNI="${CNI_PROVIDER:-}"
CTS_CNI_VERSION="${CNI_VERSION:-}"
CTS_CNI_VALUES=""
CTS_CNI_KPR="${CNI_KPR:-}"
[ "$CNI_PROVIDER" != "null" ] && [ -n "$CNI_PROVIDER" ] && CTS_CNI="$CNI_PROVIDER" || CTS_CNI=""
[ "$CNI_VERSION"  != "null" ] && [ -n "$CNI_VERSION" ]  && CTS_CNI_VERSION="$CNI_VERSION"   || CTS_CNI_VERSION=""
[ -n "$CNI_VALUES" ] && [ "$CNI_VALUES" != "null" ] && [ -n "$CNI_VALUES" ] && CTS_CNI_VALUES="$(resolve_path "$CNI_VALUES")" || CTS_CNI_VALUES=""
[ "$CNI_KPR"      != "null" ] && [ -n "$CNI_KPR" ]      && CTS_CNI_KPR="$CNI_KPR"           || CTS_CNI_KPR=""
# Export Cilium CNI vars for cluster-up.sh
export CTS_CNI CTS_CNI_VERSION CTS_CNI_VALUES CTS_CNI_KPR

scenario_context() {
  case "$PROVIDER" in
    kind) echo "kind-${CLUSTER_NAME}" ;;
    minikube) echo "${CLUSTER_NAME}" ;;
    k3d) echo "k3d-${CLUSTER_NAME}" ;;
    *) echo "" ;;
  esac
}

# ---- Cloud-native authored-only guard (VAL-CLOUDX-008) ----
# Cloud-native scenarios (gke, eks, aks) are authored only — they must NOT
# trigger any cluster operations, cloud CLI calls, or kubectl --context.
# Exit 0 from the MAIN script (not a subshell) with a skip message.
case "$PROVIDER" in
  gke|eks|aks)
    echo "==> Cloud-native provider '$PROVIDER' — authored only; skipping cluster operations." >&2
    echo "    This repo does not run cloud-native scenarios. Apply the scenario to your own" >&2
    echo "    $PROVIDER cluster following the primer instructions." >&2
    exit 0
    ;;
esac

KUBE_CONTEXT="${KUBE_CONTEXT:-$(scenario_context)}"
export KUBE_CONTEXT
export HELM_KUBECONTEXT="$KUBE_CONTEXT"

kubectl_ctx() {
  kubectl --context "$KUBE_CONTEXT" "$@"
}

helm_ctx() {
  helm --kube-context "$KUBE_CONTEXT" "$@"
}

TS="$(date +%Y%m%d-%H%M%S)"
# Reports root: explicit env > project's chart-test/reports > engine root reports
if [ -n "${REPORTS_DIR:-}" ]; then
  _REPORTS_ROOT="$REPORTS_DIR"
elif [ -d "$PROJECT_DIR/chart-test" ]; then
  _REPORTS_ROOT="$PROJECT_DIR/chart-test/reports"
else
  _REPORTS_ROOT="$ROOT_DIR/reports"
fi
REPORT_DIR="$_REPORTS_ROOT/scenario-${SCEN_ID}-${TS}"
ARTIFACTS_DIR="$REPORT_DIR/artifacts"
LOG_DIR="$ARTIFACTS_DIR/logs"

# ---- Scenario id collision detection (VAL-ENGINE-029) ----
# Check if a scenario subdirectory with the same ID already exists under
# the same reports root (e.g., from a prior run into the same run-<id>/).
# If a collision is found, append a deterministic suffix rather than silently
# overwriting.
_collision_base="$_REPORTS_ROOT"
if [ -n "${RUN_ID:-}" ] && [ -d "$_REPORTS_ROOT/$RUN_ID" ]; then
  _collision_base="$_REPORTS_ROOT/$RUN_ID"
fi
_existing=$(find "$_collision_base" -maxdepth 1 -type d -name "scenario-${SCEN_ID}-*" 2>/dev/null || true)
if [ -n "$_existing" ]; then
  # Count existing directories with this scenario ID
  _count=$(printf '%s\n' "$_existing" | grep -c . || echo 0)
  _suffix=$(( _count + 1 ))
  REPORT_DIR="$_collision_base/scenario-${SCEN_ID}-${TS}-${_suffix}"
  echo "WARN: scenario id collision — ${SCEN_ID} already has ${_count} result dir(s); using suffix -${_suffix}" >&2
  ARTIFACTS_DIR="$REPORT_DIR/artifacts"
  LOG_DIR="$ARTIFACTS_DIR/logs"
fi
mkdir -p "$LOG_DIR" "$ARTIFACTS_DIR/fixtures" "$ARTIFACTS_DIR/manifests"
RESULT="$REPORT_DIR/result.yaml"
echo "==> Scenario:   $SCEN_ID"
echo "==> Report dir: $REPORT_DIR"

# ---- Emit partial artifacts early so even crashed runs leave breadcrumbs ----
# scenario.yaml (verbatim copy of input — will be rewritten with bundle-relative paths below)
cp "$SCENARIO" "$ARTIFACTS_DIR/scenario.yaml"

# ---- Vendor chart into artifacts/chart/ (F1.4 bundle replay) ----
vendor_chart() {
  local chart_src
  chart_src=$(resolve_path "$PRODUCT_CHART")
  mkdir -p "$ARTIFACTS_DIR/chart"
  if [ -d "$chart_src" ]; then
    cp -R "$chart_src"/* "$ARTIFACTS_DIR/chart/"
    echo "==> Chart vendored to $ARTIFACTS_DIR/chart/"
  elif [[ "$PRODUCT_CHART" == oci://* ]] || [[ "$PRODUCT_CHART" == *://* ]]; then
    # OCI/URL refs can't be vendored; write a pointer file
    echo "chart_ref: $PRODUCT_CHART" > "$ARTIFACTS_DIR/chart/CHART_REF.yaml"
    echo "==> Chart is remote (OCI/URL), wrote pointer to $ARTIFACTS_DIR/chart/CHART_REF.yaml"
  else
    echo "WARN: chart path '$chart_src' is not a directory, cannot vendor" >&2
  fi
}
vendor_chart

# ---- Copy fixtures into artifacts/fixtures/ (early, so rewrite can reference them) ----
copy_fixtures_early() {
  local preinstall_count
  preinstall_count=$(yq '.cluster.preinstall // [] | length' "$SCENARIO")
  if [ "$preinstall_count" -gt 0 ]; then
    local i item_kind manifest_path resolved
    for i in $(seq 0 $((preinstall_count - 1))); do
      item_kind=$(yq ".cluster.preinstall[$i].kind // \"helm\"" "$SCENARIO")
      if [ "$item_kind" = "raw_manifest" ]; then
        manifest_path=$(yq ".cluster.preinstall[$i].path" "$SCENARIO")
        case "$manifest_path" in http://*|https://*) continue ;; esac
        resolved=$(resolve_path "$manifest_path")
        if [ -f "$resolved" ]; then
          cp -f "$resolved" "$ARTIFACTS_DIR/fixtures/$(basename "$resolved")"
        fi
      fi
      if [ "$item_kind" = "helm" ] || [ "$item_kind" = "" ]; then
        local values_kind
        values_kind=$(yq ".cluster.preinstall[$i].values | type" "$SCENARIO" 2>/dev/null || echo "!!null")
        if [ "$values_kind" = "!!str" ]; then
          local vpath
          vpath=$(yq ".cluster.preinstall[$i].values" "$SCENARIO")
          local resolved_vpath
          resolved_vpath=$(resolve_path "$vpath")
          if [ -f "$resolved_vpath" ]; then
            cp -f "$resolved_vpath" "$ARTIFACTS_DIR/fixtures/$(basename "$resolved_vpath")"
          fi
        fi
      fi
    done
  fi

  # Also copy product.values file if it references a fixture
  if [ -n "$PRODUCT_VALUES" ] && [ "$PRODUCT_VALUES" != "null" ]; then
    local vpath
    vpath=$(resolve_path "$PRODUCT_VALUES")
    if [ -f "$vpath" ]; then
      cp -f "$vpath" "$ARTIFACTS_DIR/fixtures/$(basename "$vpath")"
    fi
  fi

  # Copy cluster.config if it's a local file
  local cluster_cfg
  cluster_cfg=$(yq '.cluster.config // ""' "$SCENARIO")
  if [ -n "$cluster_cfg" ] && [ "$cluster_cfg" != "null" ]; then
    local cfg_resolved
    cfg_resolved=$(resolve_path "$cluster_cfg")
    if [ -f "$cfg_resolved" ]; then
      cp -f "$cfg_resolved" "$ARTIFACTS_DIR/fixtures/$(basename "$cfg_resolved")"
    fi
  fi

  # Copy CNI values file if specified
  if [ -n "$CTS_CNI_VALUES" ] && [ -f "$CTS_CNI_VALUES" ]; then
    cp -f "$CTS_CNI_VALUES" "$ARTIFACTS_DIR/fixtures/$(basename "$CTS_CNI_VALUES")"
  fi
}
copy_fixtures_early

# ---- Rewrite artifacts/scenario.yaml with bundle-relative paths (F1.4 bundle replay) ----
rewrite_scenario_for_bundle() {
  local bundle_scenario="$ARTIFACTS_DIR/scenario.yaml"

  # Rewrite product.chart to ./chart (unless it's a remote ref)
  local chart_path="$PRODUCT_CHART"
  case "$chart_path" in
    oci://*|https://*|http://*) ;;  # Keep remote refs as-is
    *)
      yq -i '.product.chart = "./chart"' "$bundle_scenario"
      ;;
  esac

  # Rewrite product.values to ./fixtures/<basename>
  if [ -n "$PRODUCT_VALUES" ] && [ "$PRODUCT_VALUES" != "null" ]; then
    local vbasename
    vbasename=$(basename "$PRODUCT_VALUES")
    yq -i ".product.values = \"./fixtures/$vbasename\"" "$bundle_scenario"
  fi

  # Rewrite cluster.config if present
  local _cfg
  _cfg=$(yq '.cluster.config // ""' "$SCENARIO")
  if [ -n "$_cfg" ] && [ "$_cfg" != "null" ] && [ "$_cfg" != "" ]; then
    local cfg_basename
    cfg_basename=$(basename "$_cfg")
    yq -i ".cluster.config = \"./fixtures/$cfg_basename\"" "$bundle_scenario"
  fi

  # Rewrite preinstall paths
  local preinstall_count
  preinstall_count=$(yq '.cluster.preinstall // [] | length' "$SCENARIO")
  if [ "$preinstall_count" -gt 0 ]; then
    local i
    for i in $(seq 0 $((preinstall_count - 1))); do
      local item_kind
      item_kind=$(yq ".cluster.preinstall[$i].kind // \"helm\"" "$SCENARIO")

      # raw_manifest: rewrite path
      if [ "$item_kind" = "raw_manifest" ]; then
        local manifest_path
        manifest_path=$(yq ".cluster.preinstall[$i].path" "$SCENARIO")
        case "$manifest_path" in
          http://*|https://*) ;;  # Keep URLs as-is
          *)
            local mbasename
            mbasename=$(basename "$manifest_path")
            yq -i ".cluster.preinstall[$i].path = \"./fixtures/$mbasename\"" "$bundle_scenario"
            ;;
        esac
      fi

      # helm: rewrite values if it's a file path (string), not inline object
      if [ "$item_kind" = "helm" ] || [ "$item_kind" = "" ]; then
        local values_kind
        values_kind=$(yq ".cluster.preinstall[$i].values | type" "$SCENARIO" 2>/dev/null || echo "!!null")
        if [ "$values_kind" = "!!str" ]; then
          local vnode
          vnode=$(yq ".cluster.preinstall[$i].values" "$SCENARIO")
          if [ -n "$vnode" ] && [ "$vnode" != "null" ]; then
            local vbasename
            vbasename=$(basename "$vnode")
            yq -i ".cluster.preinstall[$i].values = \"./fixtures/$vbasename\"" "$bundle_scenario"
          fi
        fi
      fi
    done
  fi

  # Rewrite CNI values path if set
  if [ -n "$CTS_CNI_VALUES" ] && [ -f "$CTS_CNI_VALUES" ]; then
    local cni_values_basename
    cni_values_basename=$(basename "$CTS_CNI_VALUES")
    yq -i ".cluster.cni.values = \"./fixtures/$cni_values_basename\"" "$bundle_scenario"
  fi
}
rewrite_scenario_for_bundle

# ---- Resolve preinstall versions from versions.yaml config ----
# Global associative arrays populated by _resolve_versions():
#   _RESOLVED_VERSIONS[release_name] = resolved version string
#   _RESOLVED_SOURCES[release_name]  = "scenario" | "versions-config"
declare -A _RESOLVED_VERSIONS=()
declare -A _RESOLVED_SOURCES=()

# _resolve_versions: for each helm preinstall item in the scenario, determine
# the resolved version and its source ("scenario" when the YAML specifies it
# explicitly, "versions-config" when it is looked up from the merged
# engine/defaults/versions.yaml + project chart-test/versions.yaml config).
# Results are stored in _RESOLVED_VERSIONS and _RESOLVED_SOURCES.
_resolve_versions() {
  local engine_defaults="$ENGINE_DIR/defaults/versions.yaml"
  local project_versions="$PROJECT_DIR/chart-test/versions.yaml"
  local merged_yaml=""

  # Build merged config YAML string (project wins over engine defaults)
  if command -v yq >/dev/null 2>&1 && [ -f "$engine_defaults" ]; then
    if [ -f "$project_versions" ]; then
      # shellcheck disable=SC2016  # single quotes intentional: $item is a yq variable, not shell
      merged_yaml=$(yq eval-all '. as $item ireduce ({}; . * $item)' \
        "$engine_defaults" "$project_versions" 2>/dev/null || \
        yq '.' "$engine_defaults" 2>/dev/null || echo "")
    else
      merged_yaml=$(yq '.' "$engine_defaults" 2>/dev/null || echo "")
    fi
  fi

  local preinstall_count
  preinstall_count=$(yq '.cluster.preinstall // [] | length' "$SCENARIO")
  [ "$preinstall_count" -gt 0 ] || return 0

  local i
  for i in $(seq 0 $((preinstall_count - 1))); do
    local item_kind
    item_kind=$(yq ".cluster.preinstall[$i].kind // \"helm\"" "$SCENARIO")
    [ "$item_kind" = "helm" ] || continue

    local release version
    release=$(yq ".cluster.preinstall[$i].release" "$SCENARIO")
    if [ -z "$release" ] || [ "$release" = "null" ]; then continue; fi

    version=$(yq ".cluster.preinstall[$i].version // \"\"" "$SCENARIO")

    if [ -n "$version" ] && [ "$version" != "null" ]; then
      # Scenario YAML specifies version explicitly — takes precedence
      _RESOLVED_VERSIONS["$release"]="$version"
      _RESOLVED_SOURCES["$release"]="scenario"
    elif [ -n "$merged_yaml" ]; then
      # Look up from merged versions config
      local config_version
      config_version=$(echo "$merged_yaml" | yq ".preinstalls.\"$release\".version // \"\"" 2>/dev/null || echo "")
      if [ -n "$config_version" ] && [ "$config_version" != "null" ] && [ "$config_version" != "" ]; then
        _RESOLVED_VERSIONS["$release"]="$config_version"
        _RESOLVED_SOURCES["$release"]="versions-config"
      fi
    fi
  done
}
_resolve_versions || true

# versions.json — capture tool versions immediately (including resolved preinstall info)
write_versions_json() {
  local _helm="" _kubectl="" _kind="" _minikube="" _k8s_server=""
  _helm=$(helm version --short 2>/dev/null | head -1 || echo "unknown")
  _kubectl=$(kubectl version --client --short 2>/dev/null | head -1 || kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // "unknown"' || echo "unknown")
  _kind=$(kind version -q 2>/dev/null || echo "unknown")
  _minikube=$(minikube version --short 2>/dev/null | head -1 || echo "unknown")
  _k8s_server="unknown"
  # Try to get server version if cluster is reachable
  _k8s_server=$(kubectl_ctx version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"' || echo "unknown")

  # Base versions object (tool versions)
  local base_json
  base_json=$(jq -n \
    --arg helm "$_helm" \
    --arg kubectl "$_kubectl" \
    --arg kind "$_kind" \
    --arg minikube "$_minikube" \
    --arg k8s_server "$_k8s_server" \
    '{helm: $helm, kubectl: $kubectl, kind: $kind, minikube: $minikube, k8s_server: $k8s_server}')

  # Add preinstall version entries with 'source' tracking
  # Each entry: { "release-name": { "version": "...", "source": "scenario"|"versions-config" } }
  local preinstalls_json="{}"
  if [ "${#_RESOLVED_VERSIONS[@]}" -gt 0 ]; then
    local name
    for name in "${!_RESOLVED_VERSIONS[@]}"; do
      local ver="${_RESOLVED_VERSIONS[$name]}"
      local src="${_RESOLVED_SOURCES[$name]:-versions-config}"
      preinstalls_json=$(printf '%s' "$preinstalls_json" | jq \
        --arg name "$name" \
        --arg version "$ver" \
        --arg source "$src" \
        '. + {($name): {version: $version, source: $source}}')
    done
  fi

  echo "$base_json" | jq --argjson preinstalls "$preinstalls_json" \
    '. + {preinstalls: $preinstalls}' \
    > "$ARTIFACTS_DIR/versions.json"
}
write_versions_json || true

# Capture Gateway API CRD version as an extension key in versions.json.
# Detects installed CRDs from gateway.networking.k8s.io and merges a
# gateway_api_crds key into the existing versions.json (preserving other keys).
capture_gateway_crds_version() {
  local _gw_crds=""
  # Check if GatewayClass CRD exists (indicates Gateway API CRDs are installed)
  if kubectl_ctx get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
    # Try to extract the version from the CRD's stored generation or app label
    _gw_crds=$(kubectl_ctx get crd gatewayclasses.gateway.networking.k8s.io \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || echo "")
    # Fallback: try annotations
    if [ -z "$_gw_crds" ]; then
      _gw_crds=$(kubectl_ctx get crd gatewayclasses.gateway.networking.k8s.io \
        -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || echo "")
    fi
    # Fallback: derive from the CRD apiVersion in its stored manifest
    if [ -z "$_gw_crds" ]; then
      local _api_ver
      _api_ver=$(kubectl_ctx get crd gatewayclasses.gateway.networking.k8s.io \
        -o jsonpath='{.spec.versions[0].name}' 2>/dev/null || echo "")
      _gw_crds="$_api_ver"
    fi
    [ -z "$_gw_crds" ] && _gw_crds="v1"
  fi
  if [ -n "$_gw_crds" ] && [ -f "$ARTIFACTS_DIR/versions.json" ]; then
    jq --arg val "$_gw_crds" '. + {gateway_api_crds: $val}' \
      "$ARTIFACTS_DIR/versions.json" > "$ARTIFACTS_DIR/versions.json.tmp" \
      && mv -f "$ARTIFACTS_DIR/versions.json.tmp" "$ARTIFACTS_DIR/versions.json"
  fi
}

# Start result.yaml as we go so a crashed run still leaves breadcrumbs.
{
  echo "scenario_id: $SCEN_ID"
  echo "scenario_path: $SCENARIO"
  echo "project_dir: $PROJECT_DIR"
  echo "started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "provider: $PROVIDER"
  echo "asserts:"
} > "$RESULT"

emit_assert() {
  # $1=type $2=status $3=notes [$4=depth_level] [$5=detail]
  local t="$1" s="$2" n="$3"
  local depth="${4:-}"
  local detail="${5:-}"
  {
    echo "  - type: $t"
    echo "    status: $s"
    [ -n "$depth" ] && echo "    depth_level: $depth"
    [ -n "$detail" ] && echo "    detail: $detail"
    printf '    notes: |\n'
    printf '      %s\n' "${n//$'\n'/$'\n      '}"
  } >> "$RESULT"
}

# ── Source the output-contract helpers (lookup_depth / parse_assert_log) ──
. "$SCRIPT_DIR/lib/output-contract.sh"

fail() {
  local stage="$1" msg="$2"

  # If _interrupted is set (by cleanup_on_signal SIGINT trap), do NOT
  # overwrite the INTERRUPTED status already written by the signal handler.
  # This prevents set -e from racing the SIGINT trap and writing FAIL
  # when the user hit Ctrl+C (VAL-ENGINE-027).
  if [ "${_interrupted:-0}" = "0" ]; then
    {
      echo "status: FAIL"
      echo "fail_stage: $stage"
      echo "fail_msg: |"
      printf '  %s\n' "${msg//$'\n'/$'\n  '}"
      echo "finished_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >> "$RESULT"
    echo ""; echo "FAIL ($stage): $msg" >&2
  fi

  # Write partial applied-overrides.yaml if helm merge happened
  write_applied_overrides || true

  # Failure/Interrupt path defaults to teardown. KEEP_ON_FAILURE=1 opts into keeping.
  if [ "$KEEP_ON_FAILURE" != "1" ]; then
    echo "==> Tearing down cluster after failure (KEEP_ON_FAILURE=$KEEP_ON_FAILURE)" >&2
    PROVIDER="$PROVIDER" CLUSTER_NAME="$CLUSTER_NAME" bash "$SCRIPT_DIR/cluster-down.sh" 2>/dev/null || true
  else
    echo "==> Keeping cluster after failure (KEEP_ON_FAILURE=1)" >&2
  fi

  exit 1
}

# ---- Generate applied-overrides.yaml (uniform shape) ----
# Shape: { helm_values: <merged-map>, raw_manifest_refs: [<seq of paths>] }
# helm_values = SINGLE merged map computed from:
#   Layer 1: chart defaults (helm show values)
#   Layer 2: product.values file (if specified)
#   Layer 3: product.set inline values (if specified)
#   Precedence: set > values file > defaults (Helm semantics — rightmost wins in yq *)
# raw_manifest_refs = sequence of paths from raw_manifest preinstall items
write_applied_overrides() {
  local ao="$ARTIFACTS_DIR/applied-overrides.yaml"

  # -- Compute merged helm_values via temp files --
  local _tmp_defaults _tmp_values _tmp_set
  _tmp_defaults=$(mktemp)
  _tmp_values=$(mktemp)
  _tmp_set=$(mktemp)

  # Layer 1: chart defaults from helm show values
  local chart_src
  chart_src=$(resolve_path "$PRODUCT_CHART")
  if [ -d "$chart_src" ] && command -v helm >/dev/null 2>&1; then
    helm show values "$chart_src" > "$_tmp_defaults" 2>/dev/null || echo "{}" > "$_tmp_defaults"
  else
    echo "{}" > "$_tmp_defaults"
  fi

  # Layer 2: product.values file (if specified)
  if [ -n "$PRODUCT_VALUES" ] && [ "$PRODUCT_VALUES" != "null" ]; then
    local vpath
    vpath=$(resolve_path "$PRODUCT_VALUES")
    if [ -f "$vpath" ]; then
      cat "$vpath" > "$_tmp_values"
    else
      echo "{}" > "$_tmp_values"
    fi
  else
    echo "{}" > "$_tmp_values"
  fi

  # Layer 3: product.set inline overrides
  local set_count
  set_count=$(yq '.product.set // {} | length' "$SCENARIO")
  if [ "$set_count" -gt 0 ]; then
    yq '.product.set // {}' "$SCENARIO" > "$_tmp_set"
  else
    echo "{}" > "$_tmp_set"
  fi

  # Merge: set > values > defaults (rightmost wins) using yq ireduce
  local merged
  # shellcheck disable=SC2016  # single quotes are intentional: $item is a yq variable, not a shell variable
  merged=$(yq eval-all '. as $item ireduce ({}; . * $item)' "$_tmp_defaults" "$_tmp_values" "$_tmp_set" 2>/dev/null || echo "{}")
  rm -f "$_tmp_defaults" "$_tmp_values" "$_tmp_set"

  # -- Write applied-overrides.yaml --
  {
    echo "helm_values:"
    if [ "$merged" = "{}" ]; then
      echo "  {}"
    else
      echo "$merged" | sed 's/^/  /'
    fi
    echo "raw_manifest_refs:"
    # Collect raw_manifest paths from preinstall
    local preinstall_count refs_written
    preinstall_count=$(yq '.cluster.preinstall // [] | length' "$SCENARIO")
    refs_written=0
    if [ "$preinstall_count" -gt 0 ]; then
      local i item_kind manifest_path
      for i in $(seq 0 $((preinstall_count - 1))); do
        item_kind=$(yq ".cluster.preinstall[$i].kind // \"helm\"" "$SCENARIO")
        if [ "$item_kind" = "raw_manifest" ]; then
          manifest_path=$(yq ".cluster.preinstall[$i].path" "$SCENARIO")
          echo "  - ${manifest_path}"
          refs_written=1
        fi
      done
    fi
    if [ "$refs_written" -eq 0 ]; then
      echo "  []"
    fi
  } > "$ao"
}

# ---- Dump manifests via kubectl get -o yaml ----
capture_manifests() {
  local out_dir="$ARTIFACTS_DIR/manifests"
  # Capture resources in the product namespace
  local ns="$PRODUCT_NS"
  # Deployments
  kubectl_ctx get deployments -n "$ns" -o yaml > "$out_dir/deployments.yaml" 2>/dev/null || true
  # Services
  kubectl_ctx get services -n "$ns" -o yaml > "$out_dir/services.yaml" 2>/dev/null || true
  # ConfigMaps
  kubectl_ctx get configmaps -n "$ns" -o yaml > "$out_dir/configmaps.yaml" 2>/dev/null || true
  # Secrets (metadata only for safety — not the data)
  kubectl_ctx get secrets -n "$ns" -o yaml > "$out_dir/secrets.yaml" 2>/dev/null || true
  # Ingresses
  kubectl_ctx get ingress -n "$ns" -o yaml > "$out_dir/ingress.yaml" 2>/dev/null || true
  # Helm releases
  helm_ctx list -n "$ns" -o yaml > "$out_dir/helm-releases.yaml" 2>/dev/null || true

  # Also capture preinstall namespaces
  local preinstall_count
  preinstall_count=$(yq '.cluster.preinstall // [] | length' "$SCENARIO")
  if [ "$preinstall_count" -gt 0 ]; then
    local i pns
    for i in $(seq 0 $((preinstall_count - 1))); do
      pns=$(yq ".cluster.preinstall[$i].namespace // \"\"" "$SCENARIO")
      if [ -n "$pns" ] && [ "$pns" != "null" ] && [ "$pns" != "$ns" ]; then
        mkdir -p "$out_dir/ns-$pns"
        kubectl_ctx get all -n "$pns" -o yaml > "$out_dir/ns-$pns/resources.yaml" 2>/dev/null || true
      fi
    done
  fi

  # Capture Gateway API resources (cluster-scoped + namespace-scoped) — VAL-GW-020
  if kubectl_ctx get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
    kubectl_ctx get gatewayclasses -o yaml > "$out_dir/gatewayclasses.yaml" 2>/dev/null || true
    kubectl_ctx get gateways -A -o yaml > "$out_dir/gateways.yaml" 2>/dev/null || true
    kubectl_ctx get httproutes -A -o yaml > "$out_dir/httproutes.yaml" 2>/dev/null || true
    kubectl_ctx get grpcroutes -A -o yaml > "$out_dir/grpcroutes.yaml" 2>/dev/null || true
    kubectl_ctx get backendtlspolicies -A -o yaml > "$out_dir/backendtlspolicies.yaml" 2>/dev/null || true
  fi

  # Capture Istio CRD resources (ServiceEntry, VirtualService, DestinationRule,
  # istio Gateway, Sidecar, AuthorizationPolicy, PeerAuthentication) when present
  if kubectl_ctx get crd serviceentries.networking.istio.io >/dev/null 2>&1; then
    kubectl_ctx get serviceentries -A -o yaml > "$out_dir/istio-serviceentries.yaml" 2>/dev/null || true
    kubectl_ctx get virtualservices -A -o yaml > "$out_dir/istio-virtualservices.yaml" 2>/dev/null || true
    kubectl_ctx get destinationrules -A -o yaml > "$out_dir/istio-destinationrules.yaml" 2>/dev/null || true
    kubectl_ctx get gateways.networking.istio.io -A -o yaml > "$out_dir/istio-gateways.yaml" 2>/dev/null || true
    kubectl_ctx get sidecars -A -o yaml > "$out_dir/istio-sidecars.yaml" 2>/dev/null || true
    kubectl_ctx get authorizationpolicies -A -o yaml > "$out_dir/istio-authorizationpolicies.yaml" 2>/dev/null || true
    kubectl_ctx get peerauthentications -A -o yaml > "$out_dir/istio-peerauthentications.yaml" 2>/dev/null || true
  fi

  # Remove empty/invalid YAML files
  for f in "$out_dir"/*.yaml "$out_dir"/**/*.yaml; do
    [ -f "$f" ] || continue
    if [ ! -s "$f" ] || ! yq '.' "$f" >/dev/null 2>&1; then
      rm -f "$f"
    fi
  done
}

# ---- SIGINT cleanup: tear down cluster and mark result as INTERRUPTED ----
cleanup_on_signal() {
  echo "" >&2
  echo "==> SIGINT/SIGTERM received — cleaning up" >&2

  # Set interrupt guard BEFORE writing status so fail() cannot overwrite it.
  # This prevents set -e from racing the SIGINT trap and writing FAIL
  # when the user hit Ctrl+C (VAL-ENGINE-027).
  _interrupted=1

  {
    echo "status: INTERRUPTED"
    echo "fail_stage: signal"
    echo "fail_msg: |"
    printf '  Interrupted by signal (SIGINT or SIGTERM)\n'
    echo "finished_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >> "$RESULT"

  # Write partial artifacts on signal
  write_applied_overrides || true

  # Interrupt path defaults to teardown. KEEP_ON_FAILURE=1 opts into keeping.
  if [ "$KEEP_ON_FAILURE" != "1" ]; then
    echo "==> Tearing down cluster after interrupt (KEEP_ON_FAILURE=$KEEP_ON_FAILURE)" >&2
    PROVIDER="$PROVIDER" CLUSTER_NAME="$CLUSTER_NAME" bash "$SCRIPT_DIR/cluster-down.sh" 2>/dev/null || true
  else
    echo "==> Keeping cluster after interrupt (KEEP_ON_FAILURE=1)" >&2
  fi
  exit 1
}
trap 'cleanup_on_signal' INT TERM

# ---- 1. Bring up cluster ---------------------------------------------------
export CLUSTER_NAME PROVIDER
[ -n "$K8S_VER"  ] && [ "$K8S_VER"  != "null" ] && export K8S_VERSION="$K8S_VER"
if [ -n "$KIND_CFG" ] && [ "$KIND_CFG" != "null" ]; then
  KIND_CONFIG="$(resolve_path "$KIND_CFG")"
  export KIND_CONFIG
fi

# ---- Pre-boot fixture path validation (VAL-ENGINE-025) ----
# Check ALL referenced fixture/manifest paths BEFORE any cluster operation.
# If any path is missing, emit an actionable error naming the scenario id,
# the preinstall index, and the missing path — then exit with no cluster created.
validate_fixture_paths() {
  local preinstall_count
  preinstall_count=$(yq '.cluster.preinstall // [] | length' "$SCENARIO")
  if [ "$preinstall_count" -gt 0 ]; then
    local i item_kind manifest_path resolved
    for i in $(seq 0 $((preinstall_count - 1))); do
      item_kind=$(yq ".cluster.preinstall[$i].kind // \"helm\"" "$SCENARIO")

      # raw_manifest: validate path field exists and resolves
      if [ "$item_kind" = "raw_manifest" ]; then
        manifest_path=$(yq ".cluster.preinstall[$i].path" "$SCENARIO")
        if [ -z "$manifest_path" ] || [ "$manifest_path" = "null" ]; then
          echo "ERROR: scenario '$SCEN_ID' preinstall[$i] (kind: raw_manifest) missing required 'path' field" >&2
          echo "       No cluster will be created." >&2
          exit 1
        fi
        case "$manifest_path" in http://*|https://*) continue ;; esac
        resolved=$(resolve_path "$manifest_path")
        if [ ! -f "$resolved" ]; then
          echo "ERROR: scenario '$SCEN_ID' preinstall[$i] (kind: raw_manifest) path not found: $resolved" >&2
          echo "       No cluster will be created. Fix the path and re-run." >&2
          exit 1
        fi
      fi

      # helm: validate values file path if it's a string reference
      if [ "$item_kind" = "helm" ] || [ "$item_kind" = "" ]; then
        local values_kind
        values_kind=$(yq ".cluster.preinstall[$i].values | type" "$SCENARIO" 2>/dev/null || echo "!!null")
        if [ "$values_kind" = "!!str" ]; then
          local vpath
          vpath=$(yq ".cluster.preinstall[$i].values" "$SCENARIO")
          local resolved_vpath
          resolved_vpath=$(resolve_path "$vpath")
          if [ ! -f "$resolved_vpath" ]; then
            echo "ERROR: scenario '$SCEN_ID' preinstall[$i] (kind: helm) values file not found: $resolved_vpath" >&2
            echo "       No cluster will be created. Fix the path and re-run." >&2
            exit 1
          fi
        fi
      fi
    done
  fi

  # Also validate product values file
  if [ -n "$PRODUCT_VALUES" ] && [ "$PRODUCT_VALUES" != "null" ]; then
    local vpath
    vpath=$(resolve_path "$PRODUCT_VALUES")
    if [ ! -f "$vpath" ]; then
      echo "ERROR: scenario '$SCEN_ID' product.values file not found: $vpath" >&2
      echo "       No cluster will be created. Fix the path and re-run." >&2
      exit 1
    fi
  fi

  # Validate CNI values file if specified
  if [ -n "$CTS_CNI_VALUES" ] && [ ! -f "$CTS_CNI_VALUES" ]; then
    echo "ERROR: scenario '$SCEN_ID' cluster.cni.values file not found: $CTS_CNI_VALUES" >&2
    echo "       No cluster will be created. Fix the path and re-run." >&2
    exit 1
  fi
}
validate_fixture_paths

echo "==> Cluster up (provider=$PROVIDER cluster=$CLUSTER_NAME)"
# Defer context restore to run-scenario.sh so the scenario workflow never
# races the caller's kubectl by restoring the global context prematurely.
CTS_NO_CONTEXT_RESTORE=1 bash "$SCRIPT_DIR/cluster-up.sh" 2>&1 | tee "$LOG_DIR/cluster-up.log" \
  || fail cluster-up "see $LOG_DIR/cluster-up.log"

# Pin all subsequent kubectl/helm operations to the scenario cluster context.
kubectl config use-context "$KUBE_CONTEXT" >/dev/null 2>&1 \
  || fail cluster-up "unable to switch to kube context '$KUBE_CONTEXT'"

# Re-write versions.json now that cluster is up (k8s_server version available)
write_versions_json || true

# ---- 2. Preinstall addons --------------------------------------------------
echo "==> Apply scenario preinstall"
PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPT_DIR/apply-scenario.sh" --preinstall-only "$SCENARIO" 2>&1 \
  | tee "$LOG_DIR/preinstall.log" \
  || fail preinstall "see $LOG_DIR/preinstall.log"

# Capture Gateway API CRD version if preinstall installed them (VAL-GW-020)
capture_gateway_crds_version || true

# ---- 3. Install product chart ---------------------------------------------
echo "==> Install product chart: $PRODUCT_RELEASE ($PRODUCT_CHART)"
kubectl_ctx get ns "$PRODUCT_NS" >/dev/null 2>&1 || kubectl_ctx create ns "$PRODUCT_NS" >/dev/null

PCHART="$(resolve_path "$PRODUCT_CHART")"
[ -e "$PCHART" ] || [[ "$PRODUCT_CHART" == oci://* ]] || [[ "$PRODUCT_CHART" == *://* ]] \
  || fail product-install "chart not found at $PCHART (and not an OCI/URL ref)"

helm_args=(upgrade --install "$PRODUCT_RELEASE" "$PCHART" --namespace "$PRODUCT_NS" --create-namespace --wait --timeout 5m)
if [ -n "$PRODUCT_VALUES" ] && [ "$PRODUCT_VALUES" != "null" ]; then
  vpath="$(resolve_path "$PRODUCT_VALUES")"
  [ -f "$vpath" ] || fail product-install "product values file missing: $vpath"
  helm_args+=(-f "$vpath")
fi

# --set overrides (preserve escaped-dot keys as-is)
set_count=$(yq '.product.set // {} | length' "$SCENARIO")
if [ "$set_count" -gt 0 ]; then
  while IFS=$'\t' read -r k v; do
    helm_args+=(--set "$k=$v")
  done < <(yq -o=tsv '.product.set // {} | to_entries | map([.key, .value]) | .[]' "$SCENARIO")
fi

if ! helm_ctx "${helm_args[@]}" 2>&1 | tee "$LOG_DIR/product-install.log"; then
  fail product-install "helm install failed; see $LOG_DIR/product-install.log"
fi

# ---- 4. Run asserts --------------------------------------------------------
acount=$(yq '.asserts | length' "$SCENARIO")
echo "==> Running $acount assert(s)"
overall=PASS
for i in $(seq 0 $((acount - 1))); do
  atype=$(yq ".asserts[$i].type" "$SCENARIO")
  alog="$LOG_DIR/assert-$i-$atype.log"
  echo ""
  echo "==> assert[$i] type=$atype"

  # ── Resolve depth_level from the registry before dispatch ─────────
  depth=$(lookup_depth "$atype")

  if [ ! -x "$ASSERTS_DIR/${atype}.sh" ]; then
    emit_assert "$atype" FAIL "no runner at $ASSERTS_DIR/${atype}.sh" "$depth"
    overall=FAIL
    continue
  fi

  # Export everything an assert might need.
  export RELEASE="$PRODUCT_RELEASE"
  export NAMESPACE="$PRODUCT_NS"
  export PROJECT_DIR
  export ASSERT_INDEX="$i"
  export SCENARIO

  set +e
  PROJECT_DIR="$PROJECT_DIR" bash "$ASSERTS_DIR/${atype}.sh" "$SCENARIO" "$i" \
       > "$alog" 2>&1
  _assert_ec=$?
  set -e

  # ── Parse structured output contract, with exit-code fallback ─────
  parse_assert_log "$alog" "$_assert_ec"

  # ── Capture notes (PASS → tail 20, FAIL → tail 40) ────────────────
  notes="$(tail -n 20 "$alog" | sed 's/[[:cntrl:]]//g')"
  [ "$_PARSED_RESULT" != "PASS" ] && notes="$(tail -n 40 "$alog" | sed 's/[[:cntrl:]]//g')"

  emit_assert "$atype" "$_PARSED_RESULT" "$notes" "$depth" "${_PARSED_DETAIL:-}"

  if [ "$_PARSED_RESULT" = "FAIL" ]; then
    overall=FAIL
  fi
done

# ---- 5. Capture artifacts --------------------------------------------------
echo "==> Capturing artifacts"

# applied-overrides.yaml (uniform shape — merged helm_values map)
write_applied_overrides

# Manifests (kubectl get -o yaml dumps)
capture_manifests

# ---- 6. Wrap result --------------------------------------------------------
{
  echo "status: $overall"
  echo "finished_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "log_dir: $LOG_DIR"
} >> "$RESULT"

# ---- 7. Teardown (if KEEP_CLUSTER=0) --------------------------------------
if [ "$KEEP_CLUSTER" = "0" ]; then
  echo "==> Tearing down cluster (KEEP_CLUSTER=0)"
  PROVIDER="$PROVIDER" CLUSTER_NAME="$CLUSTER_NAME" bash "$SCRIPT_DIR/cluster-down.sh" || true
else
  echo "==> Keeping cluster (KEEP_CLUSTER=$KEEP_CLUSTER)"
fi

echo ""
echo "==> $overall   ($RESULT)"
[ "$overall" = "PASS" ] || exit 1
