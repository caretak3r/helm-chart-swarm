#!/usr/bin/env bash
# Resolve a suite into a list of scenarios, round-robin them across N agents,
# write per-agent briefs + run-meta.yaml + scenarios-snapshot.yaml.
#
# Usage:   dispatch-swarm.sh <project-dir> [suite] [num-agents] [run-id]
# Env:     overrides PROJECT_DIR / SUITE / NUM_AGENTS / RUN_ID
#          REPORTS_DIR  override reports root (default: $PROJECT_DIR/chart-test/reports
#                       if chart-test/ exists, else $ROOT_DIR/reports)
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-${1:?usage: dispatch-swarm.sh <project-dir> [suite] [num-agents] [run-id]}}"
SUITE="${SUITE:-${2:-pr-subset}}"
NUM_AGENTS="${NUM_AGENTS:-${3:-2}}"
RUN_ID="${RUN_ID:-${4:-run-$(date +%Y%m%d-%H%M%S)}}"

command -v yq >/dev/null 2>&1 || { echo "ERROR: yq required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
TEMPLATE="$ENGINE_DIR/templates/agent-brief.md.tmpl"

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

# Collect matching scenarios (any tag overlap with filter)
mapfile -t ALL_FILES < <(find "$SCEN_DIR" -type f \( -name "*.yaml" -o -name "*.yml" \) | sort)
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

# Reports root: explicit env > project's chart-test/reports > engine root reports
if [ -n "${REPORTS_DIR:-}" ]; then
  _REPORTS_ROOT="$REPORTS_DIR"
elif [ -d "$PROJECT_DIR/chart-test" ]; then
  _REPORTS_ROOT="$PROJECT_DIR/chart-test/reports"
else
  _REPORTS_ROOT="$ROOT_DIR/reports"
fi
RUN_DIR="$_REPORTS_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"

# run-meta.yaml
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

cat > "$RUN_DIR/run-meta.yaml" <<META
run_id: $RUN_ID
timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)
num_agents: $NUM_AGENTS
suite: $SUITE
cluster_provider: $(yq '.cluster.provider // "kind"' "${MATCHED[0]}")
k8s_version: $(yq '.cluster.k8s_version // ""' "${MATCHED[0]}")
project:
  name: $PROJECT_NAME
  dir: $PROJECT_DIR
chart:
  name: ${CHART_NAME:-unknown}
  version: ${CHART_VERSION:-unknown}
META

# scenarios-snapshot.yaml — frozen copy of each scenario's metadata
{
  echo "scenarios:"
  for f in "${MATCHED[@]}"; do
    yq '{
      "id": .id,
      "name": .name // "",
      "description": .description // "",
      "labels": .labels // {},
      "cluster": .cluster,
      "tags": .tags // [],
      "mechanisms": .mechanisms // []
    }' "$f" | sed 's/^/  /' | sed '1s/^  /- /'
  done
} > "$RUN_DIR/scenarios-snapshot.yaml"

# Round-robin scenarios into N agent buckets
declare -a BUCKETS
for i in $(seq 1 "$NUM_AGENTS"); do BUCKETS[$i]=""; done
i=0
for f in "${MATCHED[@]}"; do
  slot=$(( (i % NUM_AGENTS) + 1 ))
  BUCKETS[$slot]="${BUCKETS[$slot]}${f}"$'\n'
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
for n in $(seq 1 "$NUM_AGENTS"); do
  agent_dir="$RUN_DIR/agent-$n"
  mkdir -p "$agent_dir"
  brief="$agent_dir/brief.md"

  # Build a markdown bullet list of this agent's scenarios
  assigned_md=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    sid=$(yq   '.id'                "$f")
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

  # Render template via simple substitution
  AGENT_N="$n" \
  NUM_AGENTS="$NUM_AGENTS" \
  RUN_ID="$RUN_ID" \
  PROJECT_DIR="$PROJECT_DIR" \
  ASSIGNED_SCENARIOS="$assigned_md" \
  PRIOR_PITFALLS="$pitfalls_md" \
  envsubst < "$TEMPLATE" > "$brief"
done

echo "==> Briefs ready under $RUN_DIR/agent-*/brief.md"
echo "==> RUN_ID=$RUN_ID"
