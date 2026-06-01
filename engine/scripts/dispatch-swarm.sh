#!/usr/bin/env bash
# Resolve a suite into a list of scenarios, round-robin them across N agents,
# write per-agent briefs + run-meta.yaml + scenarios-snapshot.yaml.
#
# Usage:   dispatch-swarm.sh <project-dir> [suite] [num-agents] [run-id]
# Env:     overrides PROJECT_DIR / SUITE / NUM_AGENTS / RUN_ID / CLUSTER_NAME
#          REPORTS_DIR  override reports root (default: $PROJECT_DIR/chart-test/reports
#                       if chart-test/ exists, else $ROOT_DIR/reports)
set -euo pipefail

# ---- Usage banner (checked before bash version preflight so --help always works) ----
usage() {
  cat <<EOF
Usage: $(basename "$0") <project-dir> [suite] [num-agents] [run-id] [OPTIONS]

Resolve a suite into a list of scenarios, round-robin them across N agents,
write per-agent briefs + run-meta.yaml + scenarios-snapshot.yaml.

Options:
  --help    Show this usage banner and exit

Arguments:
  project-dir  Path to the consumer chart project (containing chart-test-swarm.yaml)
  suite        Suite name defined in chart-test-swarm.yaml (default: pr-subset)
  num-agents   Number of parallel agents (default: 2)
  run-id       Run identifier (default: run-<timestamp>)

Environment:
  PROJECT_DIR   Override project directory
  SUITE         Override suite name
  NUM_AGENTS    Override number of agents
  RUN_ID        Override run identifier
  CLUSTER_NAME  Cluster name (must match ^chart-test-swarm-[a-z0-9-]+\$)
  REPORTS_DIR   Override reports root directory
EOF
  exit 0
}

case "${1:-}" in
  --help|-h) usage ;;
esac

# ---- Bash version preflight (VAL-ENGINE-039) ----
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "ERROR: bash >= 4 required (running ${BASH_VERSION:-unknown})." >&2
  echo "       Install modern bash: brew install bash" >&2
  echo "       Then re-run with: /opt/homebrew/bin/bash $0 $*" >&2
  exit 1
fi

PROJECT_DIR="${PROJECT_DIR:-${1:?usage: dispatch-swarm.sh <project-dir> [suite] [num-agents] [run-id]}}"
SUITE="${SUITE:-${2:-pr-subset}}"
NUM_AGENTS="${NUM_AGENTS:-${3:-2}}"
# Default RUN_ID includes PID ($$) for uniqueness across concurrent dispatches (VAL-CROSS-028)
RUN_ID="${RUN_ID:-${4:-run-$(date +%Y%m%d-%H%M%S)-$$}}"

# Default cluster name satisfies ^chart-test-swarm-[a-z0-9-]+$
CLUSTER_NAME="${CLUSTER_NAME:-chart-test-swarm-default}"

command -v yq >/dev/null 2>&1 || { echo "ERROR: yq required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
TEMPLATE="$ENGINE_DIR/templates/agent-brief.md.tmpl"

# Source the shared prefix guard — exits 1 if CLUSTER_NAME doesn't match ^chart-test-swarm-[a-z0-9-]+$
. "$SCRIPT_DIR/lib/prefix-check.sh"

export CLUSTER_NAME

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
CONFIG="$PROJECT_DIR/chart-test-swarm.yaml"
[ -f "$CONFIG" ] || { echo "ERROR: no chart-test-swarm.yaml at $CONFIG" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "ERROR: missing brief template at $TEMPLATE" >&2; exit 1; }

PROJECT_NAME=$(yq '.project.name // "unknown"' "$CONFIG")
SCEN_REL=$(yq    '.scenarios_dir // "chart-test/scenarios"' "$CONFIG")
SCEN_DIR="$PROJECT_DIR/$SCEN_REL"
[ -d "$SCEN_DIR" ] || { echo "ERROR: scenarios dir missing: $SCEN_DIR" >&2; exit 1; }

# Tag filter for this suite (JSON array)
TAG_FILTER=$(yq -o=json ".suites.\"$SUITE\".tag_filter // []" "$CONFIG")
if [ "$(echo "$TAG_FILTER" | jq 'length')" -eq 0 ]; then
  echo "ERROR: suite '$SUITE' not defined or has empty tag_filter in $CONFIG" >&2
  exit 1
fi

# Collect matching scenarios (any tag overlap with filter).
# CTS_SCENARIOS (from CLI wrapper) takes precedence: newline-separated list of
# absolute scenario file paths.
if [ -n "${CTS_SCENARIOS:-}" ]; then
  MATCHED=()
  while IFS= read -r f; do
    [ -n "$f" ] && MATCHED+=("$f")
  done <<< "$CTS_SCENARIOS"
  COUNT=${#MATCHED[@]}
  if [ "$COUNT" -eq 0 ]; then
    echo "ERROR: CTS_SCENARIOS was set but empty" >&2
    exit 1
  fi
  echo "==> CLI provided $COUNT scenario(s); dispatching to $NUM_AGENTS agent(s)"
else
  # Bash 3.2 compatible: avoid mapfile, use while-read loop
  ALL_FILES=()
  while IFS= read -r f; do
    ALL_FILES+=("$f")
  done < <(find "$SCEN_DIR" -type f \( -name "*.yaml" -o -name "*.yml" \) | sort)

  MATCHED=()
  for f in "${ALL_FILES[@]}"; do
    s_tags=$(yq -o=json '.tags // []' "$f")
    hit=$(jq -n --argjson a "$TAG_FILTER" --argjson b "$s_tags" \
          '[ $a[] | select(. as $x | $b | index($x) != null) ] | length')
    [ "$hit" -gt 0 ] && MATCHED+=("$f")
  done

  COUNT=${#MATCHED[@]}
  if [ "$COUNT" -eq 0 ]; then
    echo "ERROR: no scenarios matched suite '$SUITE' (tag_filter=$TAG_FILTER)" >&2
    exit 1
  fi
  echo "==> Suite '$SUITE' matched $COUNT scenario(s); dispatching to $NUM_AGENTS agent(s)"
fi

# ---- Cloud-native authored-only guard (VAL-CLOUD-012) ----
# Cloud-native scenarios (gke, eks, aks) are authored only — they must NOT
# trigger any cluster operations, cloud CLI calls, or kubectl --context.
# Filter them out unless CTS_INCLUDE_CLOUD_NATIVE=1 is set.
CLOUD_PROVIDERS='gke\|eks\|aks'
_LOCAL_ONLY=()
_CLOUD_SKIPPED=()
_CLOUD_INCLUDE="${CTS_INCLUDE_CLOUD_NATIVE:-0}"

for f in "${MATCHED[@]}"; do
  _prov=$(yq '.cluster.provider // ""' "$f")
  if echo "$_prov" | grep -qE "$CLOUD_PROVIDERS"; then
    if [ "$_CLOUD_INCLUDE" = "1" ]; then
      _LOCAL_ONLY+=("$f")
      echo "  (authored-only) $f" >&2
    else
      _CLOUD_SKIPPED+=("$f")
    fi
  else
    _LOCAL_ONLY+=("$f")
  fi
done

# If ALL matched scenarios are cloud-native and not explicitly included,
# emit the skip message and exit 0 — do not start any cluster ops.
if [ "${#_CLOUD_SKIPPED[@]}" -gt 0 ] && [ "${#_LOCAL_ONLY[@]}" -eq "${#_CLOUD_SKIPPED[@]}" ]; then
  echo "==> All ${#_CLOUD_SKIPPED[@]} matched scenario(s) are cloud-native — authored only; skipping cluster operations." >&2
  echo "    Re-run with CTS_INCLUDE_CLOUD_NATIVE=1 to include them (note: they will still be" >&2
  echo "    authored only — no real GKE/EKS/AKS cluster operations are invoked)." >&2
  exit 0
fi

# If some cloud-native scenarios were skipped, note it
if [ "${#_CLOUD_SKIPPED[@]}" -gt 0 ]; then
  echo "==> Skipped ${#_CLOUD_SKIPPED[@]} cloud-native scenario(s) (authored only)." >&2
  echo "    Re-run with CTS_INCLUDE_CLOUD_NATIVE=1 to include them in the dispatch." >&2
fi

# Replace MATCHED with local-only scenarios (plus cloud-native if opted in)
MATCHED=("${_LOCAL_ONLY[@]}")
COUNT=${#MATCHED[@]}

if [ "$COUNT" -eq 0 ]; then
  echo "==> No local-backend scenarios to dispatch after filtering cloud-native." >&2
  exit 0
fi

echo "==> $COUNT local-backend scenario(s) will be dispatched."

# Reports root: explicit env > project's chart-test/reports > engine root reports
if [ -n "${REPORTS_DIR:-}" ]; then
  _REPORTS_ROOT="$REPORTS_DIR"
elif [ -d "$PROJECT_DIR/chart-test" ]; then
  _REPORTS_ROOT="$PROJECT_DIR/chart-test/reports"
else
  _REPORTS_ROOT="$ROOT_DIR/reports"
fi
RUN_DIR="$_REPORTS_ROOT/$RUN_ID"

# ---- RUN_ID collision detection (VAL-CROSS-028) ----
# Ensure the parent reports directory exists
mkdir -p "$_REPORTS_ROOT"

# Use atomic mkdir (without -p) so we can detect collisions.
# Default RUN_ID includes PID ($$) for per-process uniqueness; explicit
# RUN_ID collisions are handled with a retry counter.
_attempt=0
_original_run_id="$RUN_ID"
while ! mkdir "$RUN_DIR" 2>/dev/null; do
  _attempt=$((_attempt + 1))
  if [ "$_attempt" -gt 9 ]; then
    echo "ERROR: could not create unique run directory after 10 attempts: $RUN_DIR" >&2
    echo "       Use a different RUN_ID to avoid collisions." >&2
    exit 1
  fi
  RUN_ID="${_original_run_id}-${_attempt}"
  RUN_DIR="$_REPORTS_ROOT/$RUN_ID"
done

# run-meta.yaml — reflect actual mix of providers/k8s_versions (VAL-ENGINE-036)
CHART_NAME=""
CHART_VERSION=""
# Best-effort: parse the first scenario's product.chart, then look for Chart.yaml.
first_chart=$(yq '.product.chart' "${MATCHED[0]}")
case "$first_chart" in
  /*) cabs="$first_chart" ;;
  *)  cabs="$PROJECT_DIR/$first_chart" ;;
esac
if [ -f "$cabs/Chart.yaml" ]; then
  CHART_NAME=$(yq '.name'    "$cabs/Chart.yaml")
  CHART_VERSION=$(yq '.version' "$cabs/Chart.yaml")
fi

# Collect all unique providers and k8s_versions across matched scenarios
ALL_PROVIDERS=()
ALL_K8S_VERSIONS=()
for f in "${MATCHED[@]}"; do
  p=$(yq '.cluster.provider // "kind"' "$f")
  k=$(yq '.cluster.k8s_version // ""' "$f")
  ALL_PROVIDERS+=("$p")
  ALL_K8S_VERSIONS+=("$k")
done

# Check for mixed providers and either list them or refuse
UNIQUE_PROVIDERS=$(printf '%s\n' "${ALL_PROVIDERS[@]}" | sort -u)
PROVIDER_COUNT=$(printf '%s\n' "${UNIQUE_PROVIDERS[@]}" | wc -l | tr -d ' ')

if [ "$PROVIDER_COUNT" -gt 1 ]; then
  # Record all providers as a YAML list
  PROVIDER_YAML=$(printf '%s\n' "${UNIQUE_PROVIDERS[@]}" | sed 's/^/  - /')
  K8S_YAML=$(printf '%s\n' "${ALL_K8S_VERSIONS[@]}" | sort -u | grep -v '^$' | sed 's/^/  - /')
  cat > "$RUN_DIR/run-meta.yaml" <<META
run_id: $RUN_ID
timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)
num_agents: $NUM_AGENTS
suite: $SUITE
cluster_provider:
${PROVIDER_YAML}
k8s_version:
${K8S_YAML}
project:
  name: $PROJECT_NAME
  dir: $PROJECT_DIR
chart:
  name: ${CHART_NAME:-unknown}
  version: ${CHART_VERSION:-unknown}
META
else
  # Homogeneous — use scalar (backward compatible)
  FIRST_PROVIDER=$(printf '%s\n' "${UNIQUE_PROVIDERS[@]}" | head -1)
  FIRST_K8S=$(printf '%s\n' "${ALL_K8S_VERSIONS[@]}" | head -1)
  cat > "$RUN_DIR/run-meta.yaml" <<META
run_id: $RUN_ID
timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)
num_agents: $NUM_AGENTS
suite: $SUITE
cluster_provider: ${FIRST_PROVIDER}
k8s_version: "${FIRST_K8S}"
project:
  name: $PROJECT_NAME
  dir: $PROJECT_DIR
chart:
  name: ${CHART_NAME:-unknown}
  version: ${CHART_VERSION:-unknown}
META
fi

# scenarios-snapshot.yaml — frozen copy of each scenario's metadata
# Includes product + asserts per scenario (VAL-ENGINE-031)
{
  echo "scenarios:"
  for f in "${MATCHED[@]}"; do
    yq '{
      "id": .id,
      "name": .name // "",
      "description": .description // "",
      "labels": .labels // {},
      "cluster": .cluster,
      "product": .product,
      "asserts": .asserts,
      "tags": .tags // [],
      "mechanisms": .mechanisms // []
    }' "$f" | sed 's/^/  /' | sed '1s/^  /- /'
  done
} > "$RUN_DIR/scenarios-snapshot.yaml"

# Round-robin scenarios into N agent buckets (Bash 3.2 compatible)
declare -a BUCKETS
for i in $(seq 1 "$NUM_AGENTS"); do BUCKETS[i]=""; done
i=0
for f in "${MATCHED[@]}"; do
  slot=$(( (i % NUM_AGENTS) + 1 ))
  BUCKETS[slot]="${BUCKETS[slot]}${f}"$'\n'
  i=$((i + 1))
done

# Most recent prior lessons (skip current run dir)
PRIOR_LESSONS=""
while IFS= read -r d; do
  [ "$d" = "$RUN_DIR" ] && continue
  if [ -f "$d/lessons-learned.md" ]; then
    PRIOR_LESSONS="$d/lessons-learned.md"
    break
  fi
done < <(find "$_REPORTS_ROOT" -mindepth 1 -maxdepth 1 -type d -name "run-*" 2>/dev/null | sort -r)

# Per-agent brief generation
# IMPORTANT (VAL-ENGINE-037): We use awk-based substitution instead of envsubst
# or sed to prevent re-expansion of $VAR / ${VAR} in scenario name/description
# fields AND to handle multi-line replacement strings correctly on both GNU
# and BSD (macOS) platforms.
for n in $(seq 1 "$NUM_AGENTS"); do
  agent_dir="$RUN_DIR/agent-$n"
  mkdir -p "$agent_dir"
  brief="$agent_dir/brief.md"

  # Build a markdown bullet list of this agent's scenarios
  # Use single-quoted yq expressions and printf '%s' to prevent shell expansion
  # of any $VAR in scenario name/description fields.
  assigned_md=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    sid=$(yq   '.id'                "$f")
    # Use printf '%s' to avoid shell interpreting $ in names/descriptions
    snam=$(yq  '.name // ""'        "$f")
    sdesc=$(yq '.description // ""' "$f")
    assigned_md+="- **\`$sid\`** — $snam"$'\n'
    assigned_md+="  - scenario: \`$f\`"$'\n'
    [ -n "$sdesc" ] && [ "$sdesc" != "null" ] && assigned_md+="  - desc: $sdesc"$'\n'
  done <<< "${BUCKETS[$n]}"

  pitfalls_md=""
  if [ -n "$PRIOR_LESSONS" ]; then
    pitfalls_md=$'## KNOWN PITFALLS (from prior runs — read carefully)\n\n'
    pitfalls_md+="$(cat "$PRIOR_LESSONS")"
    pitfalls_md+=$'\n'
  fi

  # Render template via awk — NOT envsubst — to prevent
  # re-expansion of $VAR / ${VAR} in scenario fields (VAL-ENGINE-037).
  # Use ENVIRON instead of -v to pass multi-line replacement strings,
  # which awk -v cannot handle. This works on both GNU and BSD awk.
  export _AWK_AGENT_N="$n"
  export _AWK_NUM_AGENTS="$NUM_AGENTS"
  export _AWK_RUN_ID="$RUN_ID"
  export _AWK_PROJECT_DIR="$PROJECT_DIR"
  export _AWK_ASSIGNED_SCENARIOS="$assigned_md"
  export _AWK_PRIOR_PITFALLS="$pitfalls_md"
  awk '{
        gsub(/\$\{AGENT_N\}/, ENVIRON["_AWK_AGENT_N"]);
        gsub(/\$\{NUM_AGENTS\}/, ENVIRON["_AWK_NUM_AGENTS"]);
        gsub(/\$\{RUN_ID\}/, ENVIRON["_AWK_RUN_ID"]);
        gsub(/\$\{PROJECT_DIR\}/, ENVIRON["_AWK_PROJECT_DIR"]);
        gsub(/\$\{ASSIGNED_SCENARIOS\}/, ENVIRON["_AWK_ASSIGNED_SCENARIOS"]);
        gsub(/\$\{PRIOR_PITFALLS\}/, ENVIRON["_AWK_PRIOR_PITFALLS"]);
        print;
      }' "$TEMPLATE" > "$brief"
done

echo "==> Briefs ready under $RUN_DIR/agent-*/brief.md"
echo "==> RUN_ID=$RUN_ID"
