#!/usr/bin/env bats
# aggregate.bats — Tests for aggregate.sh CSV round-trip and edge cases
#
# Covers:
#   VAL-ENGINE-034: CSV round-trip for commas, newlines, quotes in notes
#   Empty all_results produces header-only CSV without set -e abort

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
  AGGREGATE="$SCRIPTS_DIR/aggregate.sh"

  # Unique temp dir per test
  WORK_DIR="$(mktemp -d)"
  REPORTS_DIR="$WORK_DIR/reports"
  RUN_DIR="$REPORTS_DIR/run-test-001"
  mkdir -p "$RUN_DIR/agent-1"
}

teardown() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
}

# Helper: write a scenarios-snapshot.yaml
write_snapshot() {
  local scenario_id="$1"
  cat > "$RUN_DIR/scenarios-snapshot.yaml" <<YAML
scenarios:
  - id: $scenario_id
    name: "Test scenario"
    mechanisms: [test]
    cluster:
      provider: kind
      k8s_version: "v1.30.0"
    product:
      chart: test-chart
      release: test-release
      namespace: test-ns
    asserts:
      - type: pods-ready
YAML
}

# ---------------------------------------------------------------------------
# VAL-ENGINE-034: CSV round-trip for pathological notes (comma, newline, quote)
# ---------------------------------------------------------------------------
@test "aggregate.sh CSV round-trips pathological notes (comma, newline, double-quote)" {

  write_snapshot "scenario-a"

  # result.yaml with pathological fail_msg: comma, newline, double-quote
  cat > "$RUN_DIR/agent-1/result.yaml" <<'YAML'
agent: 1
results:
  - scenario_id: scenario-a
    status: FAIL
    duration_s: 10
    fail_msg: "FAIL: pod x, container y; got HTTP 500\nresponse body: \"not ok\""
    fail_stage: preinstall
    asserts:
      - type: pods-ready
        status: FAIL
        notes: "crash loop on container y"
YAML

  # Report-only: this test exercises CSV round-trip, not the exit policy.
  CTS_AGGREGATE_STRICT=0 REPORTS_DIR="$REPORTS_DIR" run bash "$AGGREGATE" "run-test-001"
  echo "exit=$status" >&2
  echo "output=$output" >&2

  [ "$status" -eq 0 ]

  CSV="$RUN_DIR/scenario-matrix.csv"
  [ -f "$CSV" ]

  # Verify round-trip with python3 csv.reader
  result=$(python3 -c "
import csv
with open('$CSV', newline='') as f:
    reader = csv.reader(f)
    header = next(reader)
    rows = list(reader)
# Find the row for scenario-a
for row in rows:
    if row[0] == 'scenario-a':
        notes = row[6]
        expected = 'FAIL: pod x, container y; got HTTP 500\\nresponse body: \"not ok\"'
        if notes == expected:
            print('MATCH')
        else:
            print('MISMATCH')
            print('expected: ' + repr(expected))
            print('got:      ' + repr(notes))
        break
else:
    print('NO_ROW')
" 2>&1)

  echo "round-trip result: $result" >&2
  [ "$result" = "MATCH" ]
}

# ---------------------------------------------------------------------------
# Empty all_results produces valid CSV header only (no set -e abort)
# ---------------------------------------------------------------------------
@test "aggregate.sh empty all_results produces header-only CSV" {

  write_snapshot "scenario-b"

  # Empty result.yaml (no results array) to trigger empty all_results path
  cat > "$RUN_DIR/agent-1/result.yaml" <<'YAML'
agent: 1
results: []
YAML

  REPORTS_DIR="$REPORTS_DIR" run bash "$AGGREGATE" "run-test-001"
  echo "exit=$status" >&2
  echo "output=$output" >&2

  [ "$status" -eq 0 ]

  CSV="$RUN_DIR/scenario-matrix.csv"
  [ -f "$CSV" ]

  # CSV should have header row and at least UNTESTED rows for expected scenarios
  # (or just header if expected_ids is empty)
  header=$(head -1 "$CSV" | tr -d '\r')
  echo "header=$header" >&2
  [[ "$header" == "scenario_id,status,agent,asserts_passed,asserts_total,fail_stage,notes" ]]
}

# ---------------------------------------------------------------------------
# Source-grep: aggregate.sh uses proper CSV quoting mechanism
# ---------------------------------------------------------------------------
@test "aggregate.sh uses python csv module or jq @csv for CSV generation" {
  script="$AGGREGATE"
  [ -f "$script" ]

  # Must use either python csv module or jq @csv for proper CSV quoting
  if grep -q 'csv.writer\|csv.reader\|csv\.DictWriter' "$script"; then
    # Python csv module path — check for proper quoting
    true
  elif grep -q '@csv' "$script"; then
    # jq @csv path — check for proper quoting
    true
  else
    echo "ERROR: aggregate.sh must use python csv module or jq @csv for CSV generation" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# VAL-ENGINE-034 also: aggregate.sh handles multi-result agent files correctly
# ---------------------------------------------------------------------------
@test "aggregate.sh handles results array with multiple scenarios per agent" {

  write_snapshot "scenario-x"
  # Append a second scenario to the snapshot
  cat >> "$RUN_DIR/scenarios-snapshot.yaml" <<YAML
  - id: scenario-y
    name: "Second test scenario"
    mechanisms: [test]
    cluster:
      provider: kind
      k8s_version: "v1.30.0"
    product:
      chart: test-chart
      release: test-release
      namespace: test-ns
    asserts:
      - type: pods-ready
YAML

  # Agent result with two scenarios
  cat > "$RUN_DIR/agent-1/result.yaml" <<'YAML'
agent: 1
results:
  - scenario_id: scenario-x
    status: PASS
    duration_s: 5
    asserts:
      - type: pods-ready
        status: PASS
        notes: "all good"
  - scenario_id: scenario-y
    status: FAIL
    duration_s: 8
    fail_msg: "pod crash detected"
    fail_stage: asserts
    asserts:
      - type: pods-ready
        status: FAIL
        notes: "CrashLoopBackOff"
YAML

  # Report-only: this test exercises multi-result handling, not the exit policy.
  CTS_AGGREGATE_STRICT=0 REPORTS_DIR="$REPORTS_DIR" run bash "$AGGREGATE" "run-test-001"
  echo "exit=$status" >&2
  [ "$status" -eq 0 ]

  CSV="$RUN_DIR/scenario-matrix.csv"
  [ -f "$CSV" ]

  # Should have rows for both scenarios
  count=$(tail -n +2 "$CSV" | wc -l | tr -d ' ')
  echo "row count=$count" >&2
  [ "$count" -ge 2 ]

  # Verify scenario-x is PASS and scenario-y is FAIL
  python3 -c "
import csv
with open('$CSV', newline='') as f:
    reader = csv.DictReader(f)
    rows = {r['scenario_id']: r for r in reader}
assert rows['scenario-x']['status'] == 'PASS', f'Expected PASS, got {rows[\"scenario-x\"][\"status\"]}'
assert rows['scenario-y']['status'] == 'FAIL', f'Expected FAIL, got {rows[\"scenario-y\"][\"status\"]}'
print('OK')
" 2>&1
}

# ---------------------------------------------------------------------------
# Strict exit policy: an unexpected FAIL fails the job (docs/ci-integration.md)
# ---------------------------------------------------------------------------
@test "aggregate.sh strict default: unexpected FAIL exits non-zero" {
  write_snapshot "scenario-fail"
  cat > "$RUN_DIR/agent-1/result.yaml" <<'YAML'
agent: 1
results:
  - scenario_id: scenario-fail
    status: FAIL
    fail_stage: asserts
    asserts:
      - type: pods-ready
        status: FAIL
YAML

  REPORTS_DIR="$REPORTS_DIR" run bash "$AGGREGATE" "run-test-001"
  echo "exit=$status" >&2
  echo "output=$output" >&2
  [ "$status" -ne 0 ]
  # CSV is still written before the strict check fires
  [ -f "$RUN_DIR/scenario-matrix.csv" ]
}

# ---------------------------------------------------------------------------
# expected-fail tag exempts a FAIL from the strict policy
# ---------------------------------------------------------------------------
@test "aggregate.sh expected-fail tag: tagged FAIL exits 0" {
  cat > "$RUN_DIR/scenarios-snapshot.yaml" <<'YAML'
scenarios:
  - id: scenario-xfail
    name: "Transitional scenario"
    tags: [pr-subset, expected-fail]
    mechanisms: [test]
    asserts:
      - type: pods-ready
YAML
  cat > "$RUN_DIR/agent-1/result.yaml" <<'YAML'
agent: 1
results:
  - scenario_id: scenario-xfail
    status: FAIL
    fail_stage: asserts
    asserts:
      - type: pods-ready
        status: FAIL
YAML

  REPORTS_DIR="$REPORTS_DIR" run bash "$AGGREGATE" "run-test-001"
  echo "exit=$status" >&2
  echo "output=$output" >&2
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# All-PASS run exits 0 under strict default
# ---------------------------------------------------------------------------
@test "aggregate.sh strict default: all-PASS exits 0" {
  write_snapshot "scenario-pass"
  cat > "$RUN_DIR/agent-1/result.yaml" <<'YAML'
agent: 1
results:
  - scenario_id: scenario-pass
    status: PASS
    asserts:
      - type: pods-ready
        status: PASS
YAML

  REPORTS_DIR="$REPORTS_DIR" run bash "$AGGREGATE" "run-test-001"
  echo "exit=$status" >&2
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Collects direct-execution output: scenario-<id>-<ts>/result.yaml (no agents).
# This is the path CI takes via `dispatch-swarm.sh --run` / `run-scenario.sh`.
# ---------------------------------------------------------------------------
@test "aggregate.sh collects scenario-*/result.yaml from direct --run execution" {
  write_snapshot "scenario-direct"
  rmdir "$RUN_DIR/agent-1" 2>/dev/null || true   # no agents in the --run path
  mkdir -p "$RUN_DIR/scenario-direct-20260101-000000"
  cat > "$RUN_DIR/scenario-direct-20260101-000000/result.yaml" <<'YAML'
scenario_id: scenario-direct
status: PASS
asserts:
  - type: pods-ready
    status: PASS
YAML

  REPORTS_DIR="$REPORTS_DIR" run bash "$AGGREGATE" "run-test-001"
  echo "exit=$status" >&2
  echo "output=$output" >&2
  [ "$status" -eq 0 ]

  # scenario-direct must appear as PASS, not UNTESTED
  row=$(awk -F, '$1=="scenario-direct" {print $2}' "$RUN_DIR/scenario-matrix.csv")
  echo "row status=$row" >&2
  [ "$row" = "PASS" ]
}
