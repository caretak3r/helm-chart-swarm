#!/usr/bin/env bash
# Aggregate per-agent results into scenario-matrix.csv + lessons-learned.md,
# then refresh the dashboard (best-effort).
#
# Usage: aggregate.sh <run-id>
# Env:   REPORTS_DIR   override reports root (default: $PROJECT_DIR/chart-test/reports
#                      if discoverable, else $ROOT_DIR/reports)
#        PROJECT_DIR   consumer chart repo (used to compute default REPORTS_DIR)
set -euo pipefail

RUN_ID="${1:?usage: aggregate.sh <run-id>}"
command -v yq >/dev/null 2>&1 || { echo "ERROR: yq required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"

# Reports root: explicit env > project's chart-test/reports > engine root reports
if [ -n "${REPORTS_DIR:-}" ]; then
  _REPORTS_ROOT="$REPORTS_DIR"
elif [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR/chart-test" ]; then
  _REPORTS_ROOT="$PROJECT_DIR/chart-test/reports"
else
  _REPORTS_ROOT="$ROOT_DIR/reports"
fi
RUN_DIR="$_REPORTS_ROOT/$RUN_ID"
[ -d "$RUN_DIR" ] || { echo "ERROR: $RUN_DIR not found" >&2; exit 1; }

SNAPSHOT="$RUN_DIR/scenarios-snapshot.yaml"
CSV="$RUN_DIR/scenario-matrix.csv"
LESSONS="$RUN_DIR/lessons-learned.md"

# All scenario IDs from the snapshot (the source of truth for what *should* have run)
EXPECTED_IDS=()
if [ -f "$SNAPSHOT" ]; then
  mapfile -t EXPECTED_IDS < <(yq '.scenarios[].id' "$SNAPSHOT")
fi

# Collect agent results into a single JSON stream:
#   { scenario_id, status, agent, asserts_passed, asserts_total, fail_stage, notes }
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
: > "$TMP"

for rfile in "$RUN_DIR"/agent-*/result.yaml; do
  [ -f "$rfile" ] || continue
  agent_n=$(basename "$(dirname "$rfile")" | sed 's/agent-//')

  # Two shapes: {agent, results: [...]} OR a single-scenario doc
  has_results=$(yq '.results | length' "$rfile" 2>/dev/null || echo 0)
  if [ "$has_results" -gt 0 ]; then
    yq -o=json '
      .results[] | {
        "scenario_id": .scenario_id,
        "status": .status,
        "agent": '"$agent_n"',
        "asserts_passed": ((.asserts // []) | map(select(.status=="PASS")) | length),
        "asserts_total":  ((.asserts // []) | length),
        "fail_stage": (.fail_stage // ""),
        "notes": ((.fail_msg // "") | tostring)
      }
    ' "$rfile" >> "$TMP"
  elif [ "$(yq '.scenario_id // ""' "$rfile")" != "" ]; then
    yq -o=json '
      {
        "scenario_id": .scenario_id,
        "status": .status,
        "agent": '"$agent_n"',
        "asserts_passed": ((.asserts // []) | map(select(.status=="PASS")) | length),
        "asserts_total":  ((.asserts // []) | length),
        "fail_stage": (.fail_stage // ""),
        "notes": ((.fail_msg // "") | tostring)
      }
    ' "$rfile" >> "$TMP"
  fi
done

# CSV
{
  echo "scenario_id,status,agent,asserts_passed,asserts_total,fail_stage,notes"
  # Emit one row per expected scenario; UNTESTED if no agent reported.
  for sid in "${EXPECTED_IDS[@]}"; do
    matches=$(jq -s --arg id "$sid" '[.[] | select(.scenario_id == $id)]' "$TMP")
    if [ "$(echo "$matches" | jq 'length')" -eq 0 ]; then
      echo "$sid,UNTESTED,,0,0,,no agent reported"
    else
      echo "$matches" | jq -r '.[] | [
        .scenario_id, .status, .agent, .asserts_passed, .asserts_total,
        .fail_stage, (.notes | gsub("[\r\n]+"; " ") | gsub("\""; "\"\""))
      ] | @csv'
    fi
  done
  # Append any orphan results (scenario_id present but not in snapshot)
  for sid in "${EXPECTED_IDS[@]}"; do echo "$sid"; done > "$TMP.expected" || true
  jq -r '.scenario_id' "$TMP" 2>/dev/null | sort -u > "$TMP.seen" || true
  if [ -s "$TMP.expected" ] && [ -s "$TMP.seen" ]; then
    comm -23 <(sort -u "$TMP.seen") <(sort -u "$TMP.expected") | while read -r orphan; do
      [ -z "$orphan" ] && continue
      jq -s --arg id "$orphan" '.[] | select(.scenario_id == $id) | [
        .scenario_id, .status, .agent, .asserts_passed, .asserts_total,
        .fail_stage, (.notes | gsub("[\r\n]+"; " ") | gsub("\""; "\"\""))
      ] | @csv' "$TMP" -r
    done
  fi
  rm -f "$TMP.expected" "$TMP.seen"
} > "$CSV"

# Status counts
declare -A COUNTS
while IFS=, read -r sid status _; do
  [ "$sid" = "scenario_id" ] && continue
  COUNTS[$status]=$(( ${COUNTS[$status]:-0} + 1 ))
done < "$CSV"

# lessons-learned.md
{
  echo "# Lessons learned — $RUN_ID"
  echo ""
  echo "## Status counts"
  echo ""
  for k in "${!COUNTS[@]}"; do
    echo "- $k: ${COUNTS[$k]}"
  done | sort
  echo ""

  # Untested
  un=$(awk -F, 'NR>1 && $2=="UNTESTED" {print $1}' "$CSV")
  if [ -n "$un" ]; then
    echo "## Scenarios not exercised this run"
    echo ""
    echo "$un" | sed 's/^/- /'
    echo ""
  fi

  # Failures
  fails=$(awk -F, 'NR>1 && ($2=="FAIL" || $2=="PARTIAL") {print}' "$CSV")
  if [ -n "$fails" ]; then
    echo "## Failures / partials"
    echo ""
    echo "$fails" | while IFS=, read -r sid status agent ap at fs notes; do
      printf -- "- **%s** (%s, agent %s, %s/%s asserts) — %s\n" \
        "$sid" "$status" "$agent" "$ap" "$at" "${notes//\"/}"
    done
    echo ""
  fi

  echo "## Pitfalls to feed into next run's briefs"
  echo ""
  echo "(Aggregator: append agent-misread, unexpected behavior, or environmental"
  echo "gotchas here. These get prepended to next dispatch as KNOWN PITFALLS.)"
} > "$LESSONS"

echo "==> Wrote $CSV"
echo "==> Wrote $LESSONS"

# Refresh dashboard (best-effort)
bash "$SCRIPT_DIR/build-dashboard.sh" "$RUN_ID" || true

echo "==> Aggregate complete: $RUN_DIR/"
