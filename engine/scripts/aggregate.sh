#!/usr/bin/env bash
# Aggregate per-agent results into scenario-matrix.csv + lessons-learned.md,
# then refresh the dashboard (best-effort).
#
# Usage: aggregate.sh <run-id>
# Env:   REPORTS_DIR   override reports root (default: $PROJECT_DIR/chart-test/reports
#                      if discoverable, else $ROOT_DIR/reports)
#        PROJECT_DIR   consumer chart repo (used to compute default REPORTS_DIR)
set -euo pipefail

# ---- Usage banner ----
usage() {
  cat <<EOF
Usage: $(basename "$0") <run-id> [OPTIONS]

Aggregate per-agent results into scenario-matrix.csv + lessons-learned.md,
then refresh the dashboard (best-effort).

Options:
  --help    Show this usage banner and exit

Arguments:
  run-id    Run identifier (e.g. run-20260520-101500)

Environment:
  REPORTS_DIR   Override reports root (default: auto-detected)
  PROJECT_DIR   Consumer chart repo (for computing default REPORTS_DIR)
EOF
  exit 0
}

case "${1:-}" in
  --help|-h) usage ;;
esac

RUN_ID="${1:?usage: aggregate.sh <run-id>}"
command -v yq >/dev/null 2>&1 || { echo "ERROR: yq required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 || { echo "ERROR: python required for CSV round-trip" >&2; exit 1; }

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
  EXPECTED_IDS=()
  while IFS= read -r sid; do
    EXPECTED_IDS+=("$sid")
  done < <(yq '.scenarios[].id' "$SNAPSHOT")
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

# CSV — use Python csv module for proper round-trip of commas/newlines/quotes
# (VAL-ENGINE-034: assertion notes with commas, newlines, and quotes must survive CSV round-trip)
{
  python3 -c '
import csv, json, sys
rows = []
expected_ids = []
# Read snapshot for expected IDs
try:
    with open("'"$SNAPSHOT"'") as f:
        import yaml
        snap = yaml.safe_load(f)
        for s in snap.get("scenarios", []):
            expected_ids.append(s["id"])
except Exception:
    pass

# Read all agent results
all_results = []
try:
    with open("'"$TMP"'") as f:
        for line in f:
            line = line.strip()
            if line:
                all_results.append(json.loads(line))
except Exception:
    pass

# Build lookup by scenario_id
by_id = {}
for r in all_results:
    sid = r.get("scenario_id", "")
    by_id.setdefault(sid, []).append(r)

writer = csv.writer(sys.stdout)
writer.writerow(["scenario_id","status","agent","asserts_passed","asserts_total","fail_stage","notes"])

# Emit one row per expected scenario; UNTESTED if no agent reported.
for sid in expected_ids:
    matches = by_id.get(sid, [])
    if not matches:
        writer.writerow([sid, "UNTESTED", "", "0", "0", "", "no agent reported"])
    else:
        for m in matches:
            notes = str(m.get("notes", ""))
            writer.writerow([
                m.get("scenario_id", ""),
                m.get("status", ""),
                m.get("agent", ""),
                m.get("asserts_passed", "0"),
                m.get("asserts_total", "0"),
                m.get("fail_stage", ""),
                notes
            ])

# Append any orphan results (scenario_id present but not in snapshot)
expected_set = set(expected_ids)
seen_orphans = set()
for r in all_results:
    sid = r.get("scenario_id", "")
    if sid and sid not in expected_set and sid not in seen_orphans:
        notes = str(r.get("notes", ""))
        writer.writerow([
            sid,
            r.get("status", ""),
            r.get("agent", ""),
            r.get("asserts_passed", "0"),
            r.get("asserts_total", "0"),
            r.get("fail_stage", ""),
            notes
        ])
        seen_orphans.add(sid)
' 2>/dev/null || {
    # Fallback: use jq @csv if python fails
    echo "scenario_id,status,agent,asserts_passed,asserts_total,fail_stage,notes"
    for sid in "${EXPECTED_IDS[@]+"${EXPECTED_IDS[@]}"}"; do
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
  }
} > "$CSV"

# Status counts — use sort+uniq for Bash 3.2 compatibility
STATUS_COUNTS=$(awk -F, 'NR>1 && $2!="" {print $2}' "$CSV" | sort | uniq -c | awk '{print $2": "$1}' | sort)

# lessons-learned.md
{
  echo "# Lessons learned — $RUN_ID"
  echo ""
  echo "## Status counts"
  echo ""
  echo "$STATUS_COUNTS" | while read -r line; do
    [ -n "$line" ] && echo "- $line"
  done
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
    echo "$fails" | while IFS=, read -r sid status agent ap at _fs notes; do
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
