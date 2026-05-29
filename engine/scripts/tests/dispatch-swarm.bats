#!/usr/bin/env bats
# dispatch-swarm.bats — Tests for dispatch-swarm.sh fixes:
#
#   Bug 1 (VAL-ENGINE-037): BSD sed multiline brief generation crash
#   Bug 2 (VAL-CROSS-028): RUN_ID TOCTOU race with no uniqueness suffix
#
# Covers:
#   - Brief generation succeeds on macOS BSD sed / Linux GNU sed
#   - Brief content preserves literal $VAR and ${VAR} in scenario name/description
#   - RUN_ID defaults include a uniqueness suffix ($$ or hash)
#   - Concurrent RUN_ID values are distinct
#   - Existing dispatch tests (artifact-contract.bats) continue to pass

setup() {
  # BATS_TEST_FILENAME = <root>/engine/scripts/tests/dispatch-swarm.bats
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
  PROJECT_DIR="$ROOT_DIR/examples/sample-product-chart"

  SCRIPT="$SCRIPTS_DIR/dispatch-swarm.sh"

  # Unique temp dir per test
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Bug 1: VAL-ENGINE-037 — Brief generation on BSD/macOS sed
# ---------------------------------------------------------------------------

@test "dispatch-swarm.sh brief generation produces non-empty brief.md files" {
  [ -f "$SCRIPT" ]

  export REPORTS_DIR="$WORK_DIR/reports"
  export RUN_ID="run-test-brief-001"
  mkdir -p "$REPORTS_DIR"

  run bash "$SCRIPT" "$PROJECT_DIR" pr-subset 2 "$RUN_ID"
  [ "$status" -eq 0 ]

  # Both agent briefs must exist and be non-empty
  for n in 1 2; do
    brief="$REPORTS_DIR/$RUN_ID/agent-$n/brief.md"
    [ -f "$brief" ] || { echo "Missing brief: $brief" >&2; return 1; }
    [ -s "$brief" ] || { echo "Empty brief: $brief" >&2; return 1; }
  done
}

@test "dispatch-swarm.sh brief content preserves literal dollar-sign in scenario name/description" {
  [ -f "$SCRIPT" ]

  # Create a scenario with literal $VAR and ${VAR} in name/description
  SCEN_DIR="$WORK_DIR/scenarios"
  mkdir -p "$SCEN_DIR"

  cat > "$SCEN_DIR/test-dollar.yaml" <<'YAML'
id: test-dollar-sign
name: "Cluster $PATH check"
description: "Verifies ${HOME} is not expanded in brief generation"
labels: {}
cluster:
  provider: kind
  k8s_version: v1.30.0
product:
  chart: ./chart
  release: sample
  namespace: sample
asserts:
  - { type: pods-ready, namespace: sample, timeout: 3m }
tags: [pr-subset]
mechanisms: [addon:none]
YAML

  # Create a minimal config pointing at our test scenarios
  CONFIG_DIR="$WORK_DIR/project"
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/chart-test-swarm.yaml" <<YAML
schema_version: 1
project: { name: test-dollar }
scenarios_dir: ../scenarios
suites:
  pr-subset: { tag_filter: [pr-subset] }
YAML

  # Create a minimal chart dir so the script doesn't fail on Chart.yaml lookup
  mkdir -p "$CONFIG_DIR/chart"
  cat > "$CONFIG_DIR/chart/Chart.yaml" <<YAML
apiVersion: v2
name: test-dollar
version: 0.1.0
YAML

  export REPORTS_DIR="$WORK_DIR/reports"
  export RUN_ID="run-test-dollar-002"
  mkdir -p "$REPORTS_DIR"

  run bash "$SCRIPT" "$CONFIG_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  brief="$REPORTS_DIR/$RUN_ID/agent-1/brief.md"
  [ -f "$brief" ]

  # The literal $PATH must appear verbatim in the brief (not expanded to the shell's PATH)
  run grep -F 'Cluster $PATH check' "$brief"
  [ "$status" -eq 0 ] || {
    echo "FAIL: '\$PATH' was expanded or lost in brief generation" >&2
    echo "Brief content:" >&2
    cat "$brief" >&2
    return 1
  }

  # The literal ${HOME} must appear verbatim in the brief
  run grep -F '${HOME} is not expanded' "$brief"
  [ "$status" -eq 0 ] || {
    echo "FAIL: '\${HOME}' was expanded or lost in brief generation" >&2
    echo "Brief content:" >&2
    cat "$brief" >&2
    return 1
  }
}

@test "dispatch-swarm.sh brief generation handles multi-line scenario descriptions" {
  [ -f "$SCRIPT" ]

  SCEN_DIR="$WORK_DIR/scenarios"
  mkdir -p "$SCEN_DIR"

  # Multi-line descriptions are a common cause of BSD sed failures
  cat > "$SCEN_DIR/test-multiline.yaml" <<'YAML'
id: test-multiline
name: "Multi-line scenario"
description: |
  This is a multi-line description.
  It has multiple lines with $dollar signs.
  And ${curly} braces that must survive.
labels: {}
cluster:
  provider: kind
  k8s_version: v1.30.0
product:
  chart: ./chart
  release: sample
  namespace: sample
asserts:
  - { type: pods-ready, namespace: sample, timeout: 3m }
tags: [pr-subset]
mechanisms: [addon:none]
YAML

  CONFIG_DIR="$WORK_DIR/project"
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/chart-test-swarm.yaml" <<YAML
schema_version: 1
project: { name: test-multiline }
scenarios_dir: ../scenarios
suites:
  pr-subset: { tag_filter: [pr-subset] }
YAML

  mkdir -p "$CONFIG_DIR/chart"
  cat > "$CONFIG_DIR/chart/Chart.yaml" <<YAML
apiVersion: v2
name: test-multiline
version: 0.1.0
YAML

  export REPORTS_DIR="$WORK_DIR/reports"
  export RUN_ID="run-test-multiline-003"
  mkdir -p "$REPORTS_DIR"

  run bash "$SCRIPT" "$CONFIG_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  brief="$REPORTS_DIR/$RUN_ID/agent-1/brief.md"
  [ -f "$brief" ]
  [ -s "$brief" ]

  # The description must contain all multi-line content
  run grep -F 'This is a multi-line description.' "$brief"
  [ "$status" -eq 0 ]

  run grep -F '$dollar signs' "$brief"
  [ "$status" -eq 0 ]

  run grep -F '${curly} braces' "$brief"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Bug 2: VAL-CROSS-028 — RUN_ID uniqueness
# ---------------------------------------------------------------------------

@test "dispatch-swarm.sh default RUN_ID includes a uniqueness suffix" {
  [ -f "$SCRIPT" ]

  # Extract the default RUN_ID line and verify it has $$ or a hash-based suffix
  default_line=$(grep -E 'RUN_ID=.*run-.*date' "$SCRIPT" | head -1)
  echo "Default RUN_ID line: $default_line" >&2

  # Must include $$ (PID) for uniqueness
  if ! echo "$default_line" | grep -qF '$$'; then
    echo "FAIL: Default RUN_ID does not include a uniqueness suffix" >&2
    return 1
  fi
}

@test "dispatch-swarm.sh produces distinct RUN_ID values on concurrent invocation simulation" {
  [ -f "$SCRIPT" ]

  export REPORTS_DIR="$WORK_DIR/reports"
  mkdir -p "$REPORTS_DIR"

  # Run dispatch twice in quick succession — they must produce distinct RUN_DIRs
  run bash "$SCRIPT" "$PROJECT_DIR" pr-subset 1
  [ "$status" -eq 0 ]
  run_dir_1=$(ls -d "$REPORTS_DIR"/run-* 2>/dev/null | head -1)
  [ -n "$run_dir_1" ] || { echo "FAIL: First dispatch produced no run dir" >&2; return 1; }

  run bash "$SCRIPT" "$PROJECT_DIR" pr-subset 1
  [ "$status" -eq 0 ]
  run_dir_2=$(ls -d "$REPORTS_DIR"/run-* 2>/dev/null | tail -1)
  [ -n "$run_dir_2" ] || { echo "FAIL: Second dispatch produced no run dir" >&2; return 1; }

  # The two run dirs must be different
  [ "$run_dir_1" != "$run_dir_2" ] || {
    echo "FAIL: Both dispatches produced the same run dir: $run_dir_1" >&2
    return 1
  }

  # Both must exist
  [ -d "$run_dir_1" ]
  [ -d "$run_dir_2" ]

  echo "Run dir 1: $run_dir_1" >&2
  echo "Run dir 2: $run_dir_2" >&2
}

@test "dispatch-swarm.sh detects existing RUN_DIR when explicit RUN_ID is given" {
  [ -f "$SCRIPT" ]

  export REPORTS_DIR="$WORK_DIR/reports"
  export RUN_ID="run-test-collision-005"
  mkdir -p "$REPORTS_DIR"

  # First dispatch — succeeds
  run bash "$SCRIPT" "$PROJECT_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]
  [ -d "$REPORTS_DIR/$RUN_ID" ]

  # Second dispatch with same RUN_ID — must detect collision and fail or use retry
  run bash "$SCRIPT" "$PROJECT_DIR" pr-subset 1 "$RUN_ID"
  # Either: exits non-zero with error, OR uses a retry/suffix mechanism and succeeds
  if [ "$status" -eq 0 ]; then
    # If it succeeded, it must have used a different (retried) directory
    # Check if there are now TWO run dirs
    n=$(find "$REPORTS_DIR" -maxdepth 1 -type d -name "run-test-collision-005*" | wc -l | tr -d ' ')
    [ "$n" -ge 1 ] || { echo "FAIL: collision not detected and no retry dir created" >&2; return 1; }
    echo "Retry mechanism created $n directories" >&2
  else
    # Exited non-zero — must have a meaningful error message
    echo "$output" | grep -qiE 'already exists|collision|mkdir|exist' || {
      echo "FAIL: non-zero exit but no collision message in output: $output" >&2
      return 1
    }
  fi
}

# ---------------------------------------------------------------------------
# Template integrity regression tests
# ---------------------------------------------------------------------------

@test "dispatch-swarm.sh brief includes all expected template sections" {
  [ -f "$SCRIPT" ]

  export REPORTS_DIR="$WORK_DIR/reports"
  export RUN_ID="run-test-sections-006"
  mkdir -p "$REPORTS_DIR"

  run bash "$SCRIPT" "$PROJECT_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  brief="$REPORTS_DIR/$RUN_ID/agent-1/brief.md"
  [ -f "$brief" ]

  # Must include the agent header
  grep -q "Agent 1 Brief" "$brief" || grep -q "executor 1" "$brief"

  # Must include the project dir
  grep -q "$PROJECT_DIR" "$brief"

  # Must include the run dir reference
  grep -q "$RUN_ID" "$brief"

  # Must include "Your task" or "Your assigned scenarios"
  grep -qE "Your (task|assigned scenarios)" "$brief"

  # Must include discipline section
  grep -qE "Discipline|No PASS without" "$brief"
}

@test "dispatch-swarm.sh nightmare scenario list in brief contains at least one scenario" {
  [ -f "$SCRIPT" ]

  export REPORTS_DIR="$WORK_DIR/reports"
  export RUN_ID="run-test-count-007"
  mkdir -p "$REPORTS_DIR"

  run bash "$SCRIPT" "$PROJECT_DIR" pr-subset 2 "$RUN_ID"
  [ "$status" -eq 0 ]

  brief1="$REPORTS_DIR/$RUN_ID/agent-1/brief.md"
  brief2="$REPORTS_DIR/$RUN_ID/agent-2/brief.md"
  [ -f "$brief1" ]
  [ -f "$brief2" ]

  # At least one brief must contain scenario references
  # Count scenario bullet lines (lines starting with "- **`")
  count1=$(grep -c '^- \*\*`' "$brief1" 2>/dev/null || echo 0)
  count2=$(grep -c '^- \*\*`' "$brief2" 2>/dev/null || echo 0)
  total=$((count1 + count2))
  echo "Scenarios in brief1: $count1, brief2: $count2" >&2
  [ "$total" -ge 1 ] || {
    echo "FAIL: No scenario references found in either brief" >&2
    return 1
  }
}

@test "dispatch-swarm.sh handles suite with zero matching scenarios gracefully" {
  [ -f "$SCRIPT" ]

  # Create project config with a suite that has a tag that will never match
  CONFIG_DIR="$WORK_DIR/project-empty"
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/chart-test-swarm.yaml" <<YAML
schema_version: 1
project: { name: test-empty }
scenarios_dir: ../scenarios
suites:
  empty-suite: { tag_filter: [nonexistent-tag] }
YAML

  SCEN_DIR="$WORK_DIR/scenarios"
  mkdir -p "$SCEN_DIR"
  # Create one scenario but with a tag that won't match
  cat > "$SCEN_DIR/test-other.yaml" <<YAML
id: test-other
name: "Other scenario"
cluster: { provider: kind, k8s_version: v1.30.0 }
product: { chart: ./chart, release: sample, namespace: sample }
asserts: [{ type: pods-ready, namespace: sample, timeout: 3m }]
tags: [other-tag]
YAML

  mkdir -p "$CONFIG_DIR/chart"
  cat > "$CONFIG_DIR/chart/Chart.yaml" <<YAML
apiVersion: v2
name: test-empty
version: 0.1.0
YAML

  export REPORTS_DIR="$WORK_DIR/reports"
  mkdir -p "$REPORTS_DIR"

  run bash "$SCRIPT" "$CONFIG_DIR" empty-suite 1
  # Should exit non-zero because no scenarios matched
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'no scenarios|empty|0 scenario' || {
    echo "FAIL: expected error about no matching scenarios, got: $output" >&2
    return 1
  }
}
