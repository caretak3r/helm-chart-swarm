#!/usr/bin/env bash
# Run ONE scenario end-to-end: cluster up → preinstall → product chart → asserts.
# Emits a result.yaml under $REPORTS_DIR/scenario-<id>-<ts>/.
#
# Usage:   run-scenario.sh <scenario.yaml>
# Env:
#   KEEP_CLUSTER=1   skip teardown (default: keep — explicit teardown via make down)
#   REPORTS_DIR      override reports root (default: $PROJECT_DIR/chart-test/reports
#                    if PROJECT_DIR has chart-test/, else $ROOT_DIR/reports)
set -euo pipefail

SCENARIO="${1:?usage: run-scenario.sh <scenario.yaml>}"
[ -f "$SCENARIO" ] || { echo "ERROR: scenario not found: $SCENARIO" >&2; exit 1; }
command -v yq   >/dev/null 2>&1 || { echo "ERROR: yq required" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "ERROR: helm required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
ASSERTS_DIR="$ENGINE_DIR/asserts"

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
K8S_VER=$(yq   '.cluster.k8s_version // ""' "$SCENARIO")
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
LOG_DIR="$REPORT_DIR/logs"
mkdir -p "$LOG_DIR"
RESULT="$REPORT_DIR/result.yaml"
echo "==> Scenario:   $SCEN_ID"
echo "==> Report dir: $REPORT_DIR"

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
  exit 1
}

# ---- 1. Bring up cluster ---------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-chart-test-swarm}"
export CLUSTER_NAME PROVIDER
[ -n "$K8S_VER"  ] && [ "$K8S_VER"  != "null" ] && export K8S_VERSION="$K8S_VER"
[ -n "$KIND_CFG" ] && [ "$KIND_CFG" != "null" ] && export KIND_CONFIG="$(resolve_path "$KIND_CFG")"

echo "==> Cluster up (provider=$PROVIDER cluster=$CLUSTER_NAME)"
bash "$SCRIPT_DIR/cluster-up.sh" 2>&1 | tee "$LOG_DIR/cluster-up.log" \
  || fail cluster-up "see $LOG_DIR/cluster-up.log"

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

# --set overrides
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

# ---- 5. Wrap result --------------------------------------------------------
{
  echo "status: $overall"
  echo "finished_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "log_dir: $LOG_DIR"
} >> "$RESULT"

echo ""
echo "==> $overall   ($RESULT)"
[ "$overall" = "PASS" ] || exit 1
