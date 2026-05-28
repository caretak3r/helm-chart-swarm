#!/usr/bin/env bash
# Run ONE scenario end-to-end: cluster up → preinstall → product chart → asserts.
# Emits result.yaml + artifacts/ bundle under $REPORTS_DIR/scenario-<id>-<ts>/.
#
# Artifact bundle (self-contained for re-application):
#   artifacts/scenario.yaml           — verbatim copy of the input scenario
#   artifacts/applied-overrides.yaml  — helm_values map + raw_manifest_refs seq
#   artifacts/fixtures/               — byte-identical copies of referenced fixtures
#   artifacts/manifests/              — kubectl get -o yaml dumps of created resources
#   artifacts/versions.json           — {helm, kubectl, kind, minikube, k8s_server}
#   artifacts/logs/                   — all captured logs
#
# Usage:   run-scenario.sh <scenario.yaml>
# Env:
#   KEEP_CLUSTER=1   skip teardown (default: keep — explicit teardown via make down)
#                     KEEP_CLUSTER=0 tears down after run.
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
  KEEP_CLUSTER   1 = keep cluster after run (default), 0 = tear down
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

# Default cluster name satisfies ^chart-test-swarm-[a-z0-9-]+$
CLUSTER_NAME="${CLUSTER_NAME:-chart-test-swarm-default}"
# KEEP_CLUSTER=1 means keep cluster (default), =0 means tear it down.
KEEP_CLUSTER="${KEEP_CLUSTER:-1}"
export KEEP_CLUSTER

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
# scenario.yaml (verbatim copy of input)
cp "$SCENARIO" "$ARTIFACTS_DIR/scenario.yaml"

# versions.json — capture tool versions immediately
write_versions_json() {
  local _helm="" _kubectl="" _kind="" _minikube="" _k8s_server=""
  _helm=$(helm version --short 2>/dev/null | head -1 || echo "unknown")
  _kubectl=$(kubectl version --client --short 2>/dev/null | head -1 || kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // "unknown"' || echo "unknown")
  _kind=$(kind version --short 2>/dev/null | head -1 || echo "unknown")
  _minikube=$(minikube version --short 2>/dev/null | head -1 || echo "unknown")
  _k8s_server="unknown"
  # Try to get server version if cluster is reachable
  _k8s_server=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"' || echo "unknown")
  jq -n \
    --arg helm "$_helm" \
    --arg kubectl "$_kubectl" \
    --arg kind "$_kind" \
    --arg minikube "$_minikube" \
    --arg k8s_server "$_k8s_server" \
    '{helm: $helm, kubectl: $kubectl, kind: $kind, minikube: $minikube, k8s_server: $k8s_server}' \
    > "$ARTIFACTS_DIR/versions.json"
}
write_versions_json || true

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
  # $1=type $2=status $3=notes
  local t="$1" s="$2" n="$3"
  {
    echo "  - type: $t"
    echo "    status: $s"
    printf '    notes: |\n'
    printf '      %s\n' "${n//$'\n'/$'\n      '}"
  } >> "$RESULT"
}

fail() {
  local stage="$1" msg="$2"
  {
    echo "status: FAIL"
    echo "fail_stage: $stage"
    echo "fail_msg: |"
    printf '  %s\n' "${msg//$'\n'/$'\n  '}"
    echo "finished_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >> "$RESULT"
  echo ""; echo "FAIL ($stage): $msg" >&2

  # Write partial applied-overrides.yaml if helm merge happened
  write_applied_overrides || true

  # Teardown cluster unless KEEP_CLUSTER=1
  if [ "$KEEP_CLUSTER" = "0" ]; then
    echo "==> Tearing down cluster (KEEP_CLUSTER=0) after failure" >&2
    PROVIDER="$PROVIDER" CLUSTER_NAME="$CLUSTER_NAME" bash "$SCRIPT_DIR/cluster-down.sh" 2>/dev/null || true
  fi

  exit 1
}

# ---- Generate applied-overrides.yaml (uniform shape) ----
# Shape: { helm_values: <map>, raw_manifest_refs: [<seq of paths>] }
# helm_values = final merged values from product.set + product.values + preinstall values
# raw_manifest_refs = list of paths from raw_manifest preinstall items
write_applied_overrides() {
  local ao="$ARTIFACTS_DIR/applied-overrides.yaml"
  {
    echo "helm_values:"
    # Product values file (if specified)
    if [ -n "$PRODUCT_VALUES" ] && [ "$PRODUCT_VALUES" != "null" ]; then
      local vpath
      vpath=$(resolve_path "$PRODUCT_VALUES")
      if [ -f "$vpath" ]; then
        # Indent the values file content under helm_values
        sed 's/^/  /' "$vpath"
      fi
    fi

    # Inline product.set overrides — merge on top of values file
    local set_count
    set_count=$(yq '.product.set // {} | length' "$SCENARIO")
    if [ "$set_count" -gt 0 ]; then
      # Write product.set entries as helm_values
      # Use yq to render the product.set map, then indent
      yq '.product.set // {}' "$SCENARIO" | sed 's/^/  /'
    fi

    # If neither values nor set, write empty map
    if [ -z "$PRODUCT_VALUES" ] || [ "$PRODUCT_VALUES" = "null" ]; then
      if [ "$set_count" -eq 0 ] 2>/dev/null; then
        echo "  {}"
      fi
    fi

    echo "raw_manifest_refs:"
    # Collect raw_manifest paths from preinstall
    local preinstall_count
    preinstall_count=$(yq '.cluster.preinstall // [] | length' "$SCENARIO")
    if [ "$preinstall_count" -gt 0 ]; then
      local i item_kind manifest_path
      for i in $(seq 0 $((preinstall_count - 1))); do
        item_kind=$(yq ".cluster.preinstall[$i].kind // \"helm\"" "$SCENARIO")
        if [ "$item_kind" = "raw_manifest" ]; then
          manifest_path=$(yq ".cluster.preinstall[$i].path" "$SCENARIO")
          echo "  - ${manifest_path}"
        fi
      done
    fi
    # If no raw_manifest refs, write empty seq
    echo "  []"
  } > "$ao"

  # Clean up: remove the trailing "  []" if we already have entries
  # (the "  []" is a fallback — remove it when there are real entries)
  if grep -q '^  - ' "$ao" 2>/dev/null; then
    # Has real entries — remove the empty seq fallback line
    sed -i '' '/^  \[\]$/d' "$ao" 2>/dev/null || sed -i '/^  \[\]$/d' "$ao" 2>/dev/null || true
  fi
}

# ---- Copy referenced fixture files into artifacts/fixtures/ ----
copy_fixtures() {
  local preinstall_count
  preinstall_count=$(yq '.cluster.preinstall // [] | length' "$SCENARIO")
  if [ "$preinstall_count" -gt 0 ]; then
    local i item_kind manifest_path resolved
    for i in $(seq 0 $((preinstall_count - 1))); do
      item_kind=$(yq ".cluster.preinstall[$i].kind // \"helm\"" "$SCENARIO")
      if [ "$item_kind" = "raw_manifest" ]; then
        manifest_path=$(yq ".cluster.preinstall[$i].path" "$SCENARIO")
        # Skip URLs
        case "$manifest_path" in http://*|https://*) continue ;; esac
        resolved=$(resolve_path "$manifest_path")
        if [ -f "$resolved" ]; then
          cp -f "$resolved" "$ARTIFACTS_DIR/fixtures/$(basename "$resolved")"
        fi
      fi
      # Also copy inline values files referenced by helm preinstall items
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
}

# ---- Dump manifests via kubectl get -o yaml ----
capture_manifests() {
  local out_dir="$ARTIFACTS_DIR/manifests"
  # Capture resources in the product namespace
  local ns="$PRODUCT_NS"
  # Deployments
  kubectl get deployments -n "$ns" -o yaml > "$out_dir/deployments.yaml" 2>/dev/null || true
  # Services
  kubectl get services -n "$ns" -o yaml > "$out_dir/services.yaml" 2>/dev/null || true
  # ConfigMaps
  kubectl get configmaps -n "$ns" -o yaml > "$out_dir/configmaps.yaml" 2>/dev/null || true
  # Secrets (metadata only for safety — not the data)
  kubectl get secrets -n "$ns" -o yaml > "$out_dir/secrets.yaml" 2>/dev/null || true
  # Ingresses
  kubectl get ingress -n "$ns" -o yaml > "$out_dir/ingress.yaml" 2>/dev/null || true
  # Helm releases
  helm list -n "$ns" -o yaml > "$out_dir/helm-releases.yaml" 2>/dev/null || true

  # Also capture preinstall namespaces
  local preinstall_count
  preinstall_count=$(yq '.cluster.preinstall // [] | length' "$SCENARIO")
  if [ "$preinstall_count" -gt 0 ]; then
    local i pns
    for i in $(seq 0 $((preinstall_count - 1))); do
      pns=$(yq ".cluster.preinstall[$i].namespace // \"\"" "$SCENARIO")
      if [ -n "$pns" ] && [ "$pns" != "null" ] && [ "$pns" != "$ns" ]; then
        mkdir -p "$out_dir/ns-$pns"
        kubectl get all -n "$pns" -o yaml > "$out_dir/ns-$pns/resources.yaml" 2>/dev/null || true
      fi
    done
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
  {
    echo "status: INTERRUPTED"
    echo "fail_stage: signal"
    echo "fail_msg: |"
    printf '  Interrupted by signal (SIGINT or SIGTERM)\n'
    echo "finished_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >> "$RESULT"

  # Write partial artifacts on signal
  write_applied_overrides || true

  # Tear down cluster unless KEEP_CLUSTER=1
  if [ "$KEEP_CLUSTER" = "0" ]; then
    echo "==> Tearing down cluster (KEEP_CLUSTER=0) after interrupt" >&2
    PROVIDER="$PROVIDER" CLUSTER_NAME="$CLUSTER_NAME" bash "$SCRIPT_DIR/cluster-down.sh" 2>/dev/null || true
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
}
validate_fixture_paths

echo "==> Cluster up (provider=$PROVIDER cluster=$CLUSTER_NAME)"
bash "$SCRIPT_DIR/cluster-up.sh" 2>&1 | tee "$LOG_DIR/cluster-up.log" \
  || fail cluster-up "see $LOG_DIR/cluster-up.log"

# Re-write versions.json now that cluster is up (k8s_server version available)
write_versions_json || true

# ---- 2. Preinstall addons --------------------------------------------------
echo "==> Apply scenario preinstall"
PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPT_DIR/apply-scenario.sh" "$SCENARIO" 2>&1 \
  | tee "$LOG_DIR/preinstall.log" \
  || fail preinstall "see $LOG_DIR/preinstall.log"

# ---- 3. Install product chart ---------------------------------------------
echo "==> Install product chart: $PRODUCT_RELEASE ($PRODUCT_CHART)"
kubectl get ns "$PRODUCT_NS" >/dev/null 2>&1 || kubectl create ns "$PRODUCT_NS" >/dev/null

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

if ! helm "${helm_args[@]}" 2>&1 | tee "$LOG_DIR/product-install.log"; then
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

  if [ ! -x "$ASSERTS_DIR/${atype}.sh" ]; then
    emit_assert "$atype" FAIL "no runner at $ASSERTS_DIR/${atype}.sh"
    overall=FAIL
    continue
  fi

  # Export everything an assert might need.
  export RELEASE="$PRODUCT_RELEASE"
  export NAMESPACE="$PRODUCT_NS"
  export PROJECT_DIR
  export ASSERT_INDEX="$i"
  export SCENARIO

  if PROJECT_DIR="$PROJECT_DIR" bash "$ASSERTS_DIR/${atype}.sh" "$SCENARIO" "$i" \
       > "$alog" 2>&1; then
    notes="$(tail -n 20 "$alog" | sed 's/[[:cntrl:]]//g')"
    emit_assert "$atype" PASS "$notes"
  else
    notes="$(tail -n 40 "$alog" | sed 's/[[:cntrl:]]//g')"
    emit_assert "$atype" FAIL "$notes"
    overall=FAIL
  fi
done

# ---- 5. Capture artifacts --------------------------------------------------
echo "==> Capturing artifacts"

# applied-overrides.yaml (uniform shape)
write_applied_overrides

# Fixture copies (byte-identical)
copy_fixtures

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
