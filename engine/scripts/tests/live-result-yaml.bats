#!/usr/bin/env bats
# live-result-yaml.bats — Verifies dispatch-swarm --run writes result.yaml incrementally,
# after EVERY scenario completes, not only at suite end.
#
# ROOT CAUSE BEING FIXED: dispatch-swarm.sh writes the run-level result.yaml exactly ONCE,
# after the scenario loop completes.  The dashboard (--watch mode) sees nothing mid-run.
#
# FIX: Extract the write block into _write_run_result_yaml() and call it inside the loop
# after each scenario completes, in addition to the existing final call.
#
# TDD RED: These tests FAIL before the fix (result.yaml only written at suite end).
# TDD GREEN: These tests PASS after the fix (result.yaml written after every scenario).

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

  WORK_DIR="$(mktemp -d)"

  # State dir for the stub run-scenario.sh to communicate back
  export DISPATCH_TEST_STATE="$WORK_DIR/state"
  mkdir -p "$DISPATCH_TEST_STATE"
}

teardown() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Set up a temp scripts dir with a copy of dispatch-swarm.sh and stub helpers.
# Stubs: run-scenario.sh (creates fake scenario result dirs) + cluster-down.sh (no-op).
_setup_fake_scripts() {
  FAKE_SCRIPTS="$WORK_DIR/scripts"
  mkdir -p "$FAKE_SCRIPTS/lib"

  # Copy dispatch-swarm.sh so SCRIPT_DIR resolves to FAKE_SCRIPTS.
  cp "$SCRIPTS_DIR/dispatch-swarm.sh" "$FAKE_SCRIPTS/"

  # Symlink lib/ (prefix-check.sh, etc.)
  for f in "$SCRIPTS_DIR/lib/"*; do
    [ -e "$f" ] || continue
    ln -sf "$f" "$FAKE_SCRIPTS/lib/$(basename "$f")"
  done

  # Stub cluster-down.sh — no-op; we don't create real clusters.
  cat > "$FAKE_SCRIPTS/cluster-down.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$FAKE_SCRIPTS/cluster-down.sh"

  # ENGINE_DIR = FAKE_SCRIPTS/.. = WORK_DIR
  # dispatch-swarm.sh needs: $ENGINE_DIR/templates/agent-brief.md.tmpl
  mkdir -p "$WORK_DIR/templates"
  ln -sf "$ENGINE_DIR/templates/agent-brief.md.tmpl" \
         "$WORK_DIR/templates/agent-brief.md.tmpl"
}

# Create the stub run-scenario.sh.
# The stub:
#   1. Increments a per-invocation counter (file-based, since each call is a new process).
#   2. Snapshots $REPORTS_DIR/result.yaml to $DISPATCH_TEST_STATE/snapshot-before-N.yaml
#      (captures whatever result.yaml looks like BEFORE this scenario creates its result dir,
#       i.e., the state written AFTER the PREVIOUS scenario completed).
#   3. Creates a fake scenario result directory with result.yaml status=PASS.
_setup_stub_run_scenario() {
  # NOTE: single-quote heredoc (<<'STUBEOF') — no variable expansion at write time.
  # DISPATCH_TEST_STATE and REPORTS_DIR are expanded at RUNTIME when the stub runs.
  cat > "$FAKE_SCRIPTS/run-scenario.sh" <<'STUBEOF'
#!/usr/bin/env bash
set -euo pipefail

SCENARIO_FILE="${1:?scenario file required}"
SCENARIO_ID=$(grep '^id:' "$SCENARIO_FILE" | head -1 | sed 's/^id:[[:space:]]*//')

# Track call number using a counter file (one call per scenario).
CALL_COUNTER_FILE="${DISPATCH_TEST_STATE}/call_count"
if [ -f "$CALL_COUNTER_FILE" ]; then
  CALL_NUM=$(( $(cat "$CALL_COUNTER_FILE") + 1 ))
else
  CALL_NUM=1
fi
echo "$CALL_NUM" > "$CALL_COUNTER_FILE"

# Snapshot result.yaml state BEFORE this scenario creates its result dir.
# This tells us what result.yaml looked like AFTER the PREVIOUS scenario completed
# (i.e., whether _write_run_result_yaml was called incrementally by dispatch-swarm.sh).
SNAPSHOT_FILE="${DISPATCH_TEST_STATE}/snapshot-before-call-${CALL_NUM}.yaml"
if [ -f "${REPORTS_DIR}/result.yaml" ]; then
  cp "${REPORTS_DIR}/result.yaml" "$SNAPSHOT_FILE"
else
  echo "NOT_PRESENT" > "$SNAPSHOT_FILE"
fi

# Create a fake scenario result dir that dispatch-swarm.sh can find.
# Naming must match: scenario-<id>-* (dispatch-swarm.sh uses find -name "scenario-${_sid}-*")
RESULT_DIR="${REPORTS_DIR}/scenario-${SCENARIO_ID}-$(date +%s)-$$"
mkdir -p "$RESULT_DIR"
cat > "$RESULT_DIR/result.yaml" <<YAML
run_id: fake
id: ${SCENARIO_ID}
status: PASS
fail_stage: ""
fail_msg: ""
asserts: []
YAML

exit 0
STUBEOF
  chmod +x "$FAKE_SCRIPTS/run-scenario.sh"
}

# Create a minimal fake project with N scenarios tagged 'test'.
_setup_fake_project() {
  local n="${1:-3}"
  FAKE_PROJECT="$WORK_DIR/project"
  mkdir -p "$FAKE_PROJECT/chart-test/scenarios"
  mkdir -p "$FAKE_PROJECT/chart"

  cat > "$FAKE_PROJECT/chart/Chart.yaml" <<YAML
apiVersion: v2
name: fake-chart
version: 0.1.0
YAML

  cat > "$FAKE_PROJECT/chart-test-swarm.yaml" <<YAML
schema_version: 1
project:
  name: fake
scenarios_dir: chart-test/scenarios
suites:
  test-suite:
    tag_filter: [test]
YAML

  for i in $(seq 1 "$n"); do
    cat > "$FAKE_PROJECT/chart-test/scenarios/fake-$i.yaml" <<YAML
id: fake-scenario-$i
name: "Fake scenario $i"
cluster:
  provider: kind
  k8s_version: v1.36.1
product:
  chart: chart
  release: fake
  namespace: fake
asserts:
  - type: pods-ready
    namespace: fake
    timeout: 1m
tags: [test]
mechanisms: [addon:none]
YAML
  done
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "dispatch-swarm --run writes result.yaml AFTER the first scenario (not only at suite end)" {
  # This test is RED before the fix: result.yaml does not exist between scenarios.
  # After the fix (_write_run_result_yaml called inside the loop), it's GREEN.

  _setup_fake_scripts
  _setup_stub_run_scenario
  _setup_fake_project 3

  export REPORTS_DIR="$WORK_DIR/reports"
  mkdir -p "$REPORTS_DIR"

  local RUN_ID="run-incremental-first-001"

  run bash "$FAKE_SCRIPTS/dispatch-swarm.sh" \
    "$FAKE_PROJECT" test-suite 1 "$RUN_ID" --run

  echo "=== dispatch-swarm exit: $status ===" >&3
  echo "=== output ===" >&3
  echo "$output" >&3

  [ "$status" -eq 0 ] || {
    echo "FAIL: dispatch-swarm.sh exited non-zero: $status" >&2
    echo "Output: $output" >&2
    return 1
  }

  local RUN_DIR="$REPORTS_DIR/$RUN_ID"

  # Sanity: final result.yaml must exist at the end.
  [ -f "$RUN_DIR/result.yaml" ] || {
    echo "FAIL: final result.yaml not created: $RUN_DIR/result.yaml" >&2
    return 1
  }

  # snapshot-before-call-1: captured BEFORE any scenario ran.
  # Expect NOT_PRESENT (no result.yaml yet at start of run).
  [ -f "$DISPATCH_TEST_STATE/snapshot-before-call-1.yaml" ] || {
    echo "FAIL: snapshot-before-call-1.yaml not created; stub run-scenario.sh may not have run" >&2
    return 1
  }
  run cat "$DISPATCH_TEST_STATE/snapshot-before-call-1.yaml"
  [ "$output" = "NOT_PRESENT" ] || {
    echo "FAIL: expected NOT_PRESENT before first scenario, got: $output" >&2
    return 1
  }

  # KEY ASSERTION: snapshot-before-call-2 reflects the state AFTER scenario 1 completed
  # and BEFORE scenario 2 started.
  #
  # Before the fix: result.yaml does not yet exist → snapshot = NOT_PRESENT → FAIL.
  # After  the fix: result.yaml has pass: 1         → snapshot has pass: 1  → PASS.
  [ -f "$DISPATCH_TEST_STATE/snapshot-before-call-2.yaml" ] || {
    echo "FAIL: snapshot-before-call-2.yaml not created" >&2
    return 1
  }

  local snap2
  snap2=$(cat "$DISPATCH_TEST_STATE/snapshot-before-call-2.yaml")
  echo "snapshot-before-call-2: $snap2" >&3

  [ "$snap2" != "NOT_PRESENT" ] || {
    echo "FAIL: result.yaml was NOT written after scenario 1" >&2
    echo "This is the root-cause bug: result.yaml is only written at suite end, not incrementally." >&2
    return 1
  }

  grep -q '^pass: 1' "$DISPATCH_TEST_STATE/snapshot-before-call-2.yaml" || {
    echo "FAIL: expected 'pass: 1' in result.yaml after first scenario, got:" >&2
    cat "$DISPATCH_TEST_STATE/snapshot-before-call-2.yaml" >&2
    return 1
  }
}

@test "dispatch-swarm --run result.yaml pass count grows scenario-by-scenario (3 scenarios)" {
  # Proves incremental write: pass count is 1 after scenario 1, 2 after scenario 2, 3 at the end.

  _setup_fake_scripts
  _setup_stub_run_scenario
  _setup_fake_project 3

  export REPORTS_DIR="$WORK_DIR/reports"
  mkdir -p "$REPORTS_DIR"

  local RUN_ID="run-incremental-grow-002"

  run bash "$FAKE_SCRIPTS/dispatch-swarm.sh" \
    "$FAKE_PROJECT" test-suite 1 "$RUN_ID" --run

  [ "$status" -eq 0 ] || {
    echo "FAIL: dispatch-swarm.sh exited non-zero: $status" >&2
    echo "Output: $output" >&2
    return 1
  }

  local RUN_DIR="$REPORTS_DIR/$RUN_ID"

  # After scenario 1 (= snapshot before scenario 2): pass must be 1.
  [ -f "$DISPATCH_TEST_STATE/snapshot-before-call-2.yaml" ] || {
    echo "FAIL: snapshot-before-call-2.yaml not created" >&2
    return 1
  }
  grep -q '^pass: 1' "$DISPATCH_TEST_STATE/snapshot-before-call-2.yaml" || {
    echo "FAIL: expected pass: 1 after scenario 1, snapshot-before-call-2 contains:" >&2
    cat "$DISPATCH_TEST_STATE/snapshot-before-call-2.yaml" >&2
    return 1
  }

  # After scenario 2 (= snapshot before scenario 3): pass must be 2.
  [ -f "$DISPATCH_TEST_STATE/snapshot-before-call-3.yaml" ] || {
    echo "FAIL: snapshot-before-call-3.yaml not created" >&2
    return 1
  }
  grep -q '^pass: 2' "$DISPATCH_TEST_STATE/snapshot-before-call-3.yaml" || {
    echo "FAIL: expected pass: 2 after scenario 2, snapshot-before-call-3 contains:" >&2
    cat "$DISPATCH_TEST_STATE/snapshot-before-call-3.yaml" >&2
    return 1
  }

  # Final result.yaml: pass must be 3.
  [ -f "$RUN_DIR/result.yaml" ]
  grep -q '^pass: 3' "$RUN_DIR/result.yaml" || {
    echo "FAIL: expected pass: 3 in final result.yaml, got:" >&2
    cat "$RUN_DIR/result.yaml" >&2
    return 1
  }
}

@test "dispatch-swarm --run result.yaml total field stays COUNT (all planned) not scenarios done so far" {
  # total: must reflect COUNT (the full planned count) so the dashboard can
  # show "X of COUNT done" rather than ever-changing total.

  _setup_fake_scripts
  _setup_stub_run_scenario
  _setup_fake_project 3

  export REPORTS_DIR="$WORK_DIR/reports"
  mkdir -p "$REPORTS_DIR"

  local RUN_ID="run-incremental-total-003"

  run bash "$FAKE_SCRIPTS/dispatch-swarm.sh" \
    "$FAKE_PROJECT" test-suite 1 "$RUN_ID" --run

  [ "$status" -eq 0 ] || {
    echo "FAIL: dispatch-swarm.sh exited non-zero: $status" >&2
    echo "Output: $output" >&2
    return 1
  }

  # After scenario 1, total: should be 3 (the full planned count, not 1).
  [ -f "$DISPATCH_TEST_STATE/snapshot-before-call-2.yaml" ]

  grep -q '^total: 3' "$DISPATCH_TEST_STATE/snapshot-before-call-2.yaml" || {
    echo "FAIL: expected 'total: 3' after first scenario (total should be COUNT=3, not 1), got:" >&2
    cat "$DISPATCH_TEST_STATE/snapshot-before-call-2.yaml" >&2
    return 1
  }
}
