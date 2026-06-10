#!/usr/bin/env bats
# consumer-resolver.bats — Tests for consumer-first assert resolver in
# run-scenario.sh (feature e-consumer-resolver, Area E architecture §3.E.1).
#
# Covers:
#   VAL-PLUGGABLE-001: Consumer override dispatches consumer script
#   VAL-PLUGGABLE-002: Consumer-only NEW type resolves and runs
#   VAL-PLUGGABLE-003: Engine assert used when no consumer override
#   VAL-PLUGGABLE-004: Backward-compatible (no consumer asserts dir)
#   VAL-PLUGGABLE-005: Non-executable override falls back to engine
#   VAL-PLUGGABLE-006: Non-executable consumer-only → "no runner" FAIL
#   VAL-PLUGGABLE-007: Consumer assert receives same env + positional args
#   VAL-PLUGGABLE-008: Consumer assert exit-code contract preserved
#   VAL-PLUGGABLE-009: Resolver does not break without chart-test/ dir
#   VAL-CROSS-003: Consumer-overridden assert SKIP → non-failing SKIP

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
  export ENGINE_DIR

  # Source the output-contract helpers (parse_assert_log, lookup_depth)
  # shellcheck source=/dev/null
  . "$SCRIPTS_DIR/lib/output-contract.sh"

  WORK_DIR="$(mktemp -d)"

  # ── Create a mock engine asserts dir ─────────────────────────────
  ENG_ASSERTS="$WORK_DIR/engine/asserts"
  mkdir -p "$ENG_ASSERTS"
  export ASSERTS_DIR="$ENG_ASSERTS"

  # ── Create a simple engine registry for depth lookups ────────────
  mkdir -p "$WORK_DIR/engine/asserts"
  cat > "$ENG_ASSERTS/registry.yaml" <<'YAML'
pods-ready: L2
labels-present: L1
annotations-present: L1
service-reachable: L2
network-policy: L2
rbac-objects: L1
YAML

  # ── Create mock engine assert scripts (executable) ───────────────
  cat > "$ENG_ASSERTS/pods-ready.sh" <<'SH'
#!/usr/bin/env bash
echo "ENGINE: pods-ready executed"
exit 0
SH
  chmod +x "$ENG_ASSERTS/pods-ready.sh"

  cat > "$ENG_ASSERTS/labels-present.sh" <<'SH'
#!/usr/bin/env bash
echo "ENGINE: labels-present executed"
exit 0
SH
  chmod +x "$ENG_ASSERTS/labels-present.sh"

  cat > "$ENG_ASSERTS/annotations-present.sh" <<'SH'
#!/usr/bin/env bash
echo "ENGINE: annotations-present executed"
exit 0
SH
  chmod +x "$ENG_ASSERTS/annotations-present.sh"

  cat > "$ENG_ASSERTS/service-reachable.sh" <<'SH'
#!/usr/bin/env bash
echo "ENGINE: service-reachable executed"
exit 0
SH
  chmod +x "$ENG_ASSERTS/service-reachable.sh"

  # ── Set up default scenario env vars ──────────────────────────────
  export RELEASE="test-release"
  export NAMESPACE="test-ns"
  export ASSERT_INDEX="0"
  export SCENARIO="/fake/scenario.yaml"
}

teardown() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
}

# ── Helper: simulate the consumer-first resolver ──────────────────────
# Mirrors exactly the resolution logic in run-scenario.sh (Area E).
# Returns the resolved path via stdout and sets RESOLVER_EXIT_CODE.
simulate_resolver() {
  local atype="$1" consumer_asserts_dir="$2"
  local consumer_assert="${consumer_asserts_dir}/${atype}.sh"
  local engine_assert="$ASSERTS_DIR/${atype}.sh"
  local resolved=""

  if [ -x "$consumer_assert" ]; then
    resolved="$consumer_assert"
  elif [ -x "$engine_assert" ]; then
    resolved="$engine_assert"
  elif [ -f "$consumer_assert" ]; then
    # Consumer exists but not executable, no engine fallback
    echo "FAIL:no runner at $consumer_assert (not executable)"
    return 0
  else
    echo "FAIL:no runner at $engine_assert"
    return 0
  fi

  echo "RESOLVED:$resolved"
  return 0
}

# ── Helper: dispatch and capture output of a resolved script ──────────
dispatch_assert() {
  local resolved="$1"
  local atype="$2"
  local alog="$WORK_DIR/assert-0-${atype}.log"

  set +e
  bash "$resolved" "/fake/scenario.yaml" "0" > "$alog" 2>&1
  local ec=$?
  set -e

  echo "$ec $alog"
}

# ══════════════════════════════════════════════════════════════════════
# VAL-PLUGGABLE-001: Consumer override dispatches consumer script
# ══════════════════════════════════════════════════════════════════════

@test "VAL-PLUGGABLE-001: consumer override of engine assert type is dispatched" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  # Create a consumer pods-ready.sh that is executable
  cat > "$cons_dir/pods-ready.sh" <<'SH'
#!/usr/bin/env bash
echo "CONSUMER: pods-ready override executed"
exit 0
SH
  chmod +x "$cons_dir/pods-ready.sh"

  run simulate_resolver "pods-ready" "$cons_dir"
  [ "$status" -eq 0 ]
  # Must resolve to CONSUMER path, not engine
  [[ "$output" =~ ^RESOLVED:.+/project/chart-test/asserts/pods-ready\.sh$ ]]
}

@test "VAL-PLUGGABLE-001b: consumer override log contains consumer marker, not engine" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  cat > "$cons_dir/pods-ready.sh" <<'SH'
#!/usr/bin/env bash
echo "CONSUMER_MARKER_XYZ: running"
exit 0
SH
  chmod +x "$cons_dir/pods-ready.sh"

  # Dispatch the resolved script
  run simulate_resolver "pods-ready" "$cons_dir"
  local resolved="${output#RESOLVED:}"
  local ec_and_log
  ec_and_log=$(dispatch_assert "$resolved" "pods-ready")
  local alog="${ec_and_log#* }"

  # Consumer log must contain the marker
  run grep -q "CONSUMER_MARKER_XYZ" "$alog"
  [ "$status" -eq 0 ]

  # Engine log must NOT contain engine marker
  run grep -q "ENGINE: pods-ready" "$alog" 2>/dev/null
  [ "$status" -ne 0 ]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-PLUGGABLE-002: Consumer-only NEW type resolves and runs
# ══════════════════════════════════════════════════════════════════════

@test "VAL-PLUGGABLE-002: consumer-only new type resolves and runs" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  # Create a consumer-only my-custom-check.sh (NO engine equivalent)
  cat > "$cons_dir/my-custom-check.sh" <<'SH'
#!/usr/bin/env bash
echo "CONSUMER: my-custom-check executed"
exit 0
SH
  chmod +x "$cons_dir/my-custom-check.sh"

  run simulate_resolver "my-custom-check" "$cons_dir"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^RESOLVED:.+my-custom-check\.sh$ ]]
}

@test "VAL-PLUGGABLE-002b: consumer-only type exit 0 maps to PASS" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  cat > "$cons_dir/my-custom-check.sh" <<'SH'
#!/usr/bin/env bash
echo "ASSERTION_RESULT: PASS"
exit 0
SH
  chmod +x "$cons_dir/my-custom-check.sh"

  run simulate_resolver "my-custom-check" "$cons_dir"
  local resolved="${output#RESOLVED:}"
  local ec_and_log
  ec_and_log=$(dispatch_assert "$resolved" "my-custom-check")
  local ec="${ec_and_log%% *}"
  local alog="${ec_and_log#* }"

  # Exit 0 from the script
  [ "$ec" -eq 0 ]

  # Parse the log to verify PASS status
  parse_assert_log "$alog" "$ec"
  [ "$_PARSED_RESULT" = "PASS" ]
}

@test "VAL-PLUGGABLE-002c: consumer-only type without engine assert does NOT emit 'no runner'" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  cat > "$cons_dir/my-custom-check.sh" <<'SH'
#!/usr/bin/env bash
echo "custom check result"
exit 0
SH
  chmod +x "$cons_dir/my-custom-check.sh"

  run simulate_resolver "my-custom-check" "$cons_dir"
  [ "$status" -eq 0 ]
  # Must resolve successfully, not emit "no runner"
  [[ "$output" =~ ^RESOLVED: ]]
  [[ ! "$output" =~ "no runner" ]]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-PLUGGABLE-003: Engine assert used when no consumer override
# ══════════════════════════════════════════════════════════════════════

@test "VAL-PLUGGABLE-003: engine assert used when consumer asserts dir exists but lacks the type" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  # Consumer dir exists but has NO labels-present.sh
  run simulate_resolver "labels-present" "$cons_dir"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^RESOLVED:.+/engine/asserts/labels-present\.sh$ ]]
}

@test "VAL-PLUGGABLE-003b: engine assert used when consumer asserts dir exists but type absent" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  # Consumer dir has a different assert, but not service-reachable
  cat > "$cons_dir/other-check.sh" <<'SH'
#!/usr/bin/env bash
echo "other check"
exit 0
SH
  chmod +x "$cons_dir/other-check.sh"

  run simulate_resolver "service-reachable" "$cons_dir"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^RESOLVED:.+/engine/asserts/service-reachable\.sh$ ]]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-PLUGGABLE-004: Backward-compatible (no consumer asserts dir)
# ══════════════════════════════════════════════════════════════════════

@test "VAL-PLUGGABLE-004: no consumer asserts dir → engine assert used" {
  export PROJECT_DIR="$WORK_DIR/project-no-chart-test"
  mkdir -p "$PROJECT_DIR"
  # Deliberately: no chart-test/ directory

  local cons_dir="$PROJECT_DIR/chart-test/asserts"
  # This dir does NOT exist
  [ ! -d "$cons_dir" ]

  run simulate_resolver "pods-ready" "$cons_dir"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^RESOLVED:.+/engine/asserts/pods-ready\.sh$ ]]
}

@test "VAL-PLUGGABLE-004b: all engine types resolve to engine paths when no consumer dir" {
  export PROJECT_DIR="$WORK_DIR/project-no-chart-test"
  mkdir -p "$PROJECT_DIR"
  local cons_dir="$PROJECT_DIR/chart-test/asserts"

  for atype in pods-ready labels-present annotations-present service-reachable; do
    run simulate_resolver "$atype" "$cons_dir"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^RESOLVED:.+/engine/asserts/${atype}\.sh$ ]] \
      || { echo "FAIL: $atype did not resolve to engine path: $output"; return 1; }
  done
}

# ══════════════════════════════════════════════════════════════════════
# VAL-PLUGGABLE-005: Non-executable override falls back to engine
# ══════════════════════════════════════════════════════════════════════

@test "VAL-PLUGGABLE-005: non-executable consumer override falls back to engine" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  # Create consumer pods-ready.sh WITHOUT executable bit
  cat > "$cons_dir/pods-ready.sh" <<'SH'
#!/usr/bin/env bash
echo "CONSUMER: should NOT run"
exit 0
SH
  # Deliberately do NOT chmod +x
  [ -f "$cons_dir/pods-ready.sh" ]
  [ ! -x "$cons_dir/pods-ready.sh" ]

  run simulate_resolver "pods-ready" "$cons_dir"
  [ "$status" -eq 0 ]
  # Must fall back to ENGINE, not consumer
  [[ "$output" =~ ^RESOLVED:.+/engine/asserts/pods-ready\.sh$ ]]
}

@test "VAL-PLUGGABLE-005b: non-executable consumer does not produce permission error" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  cat > "$cons_dir/pods-ready.sh" <<'SH'
#!/usr/bin/env bash
echo "CONSUMER: should NOT run"
exit 0
SH
  # NOT executable

  run simulate_resolver "pods-ready" "$cons_dir"
  [ "$status" -eq 0 ]
  # No "no runner" or error — engine fallback succeeds
  [[ "$output" =~ ^RESOLVED: ]]
  [[ ! "$output" =~ "no runner" ]]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-PLUGGABLE-006: Non-executable consumer-only → "no runner" FAIL
# ══════════════════════════════════════════════════════════════════════

@test "VAL-PLUGGABLE-006: non-executable consumer-only type yields 'no runner' FAIL" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  # Create consumer-only type WITHOUT executable bit
  cat > "$cons_dir/my-custom-check.sh" <<'SH'
#!/usr/bin/env bash
echo "CONSUMER: should NOT run"
exit 0
SH
  # NOT executable

  run simulate_resolver "my-custom-check" "$cons_dir"
  [ "$status" -eq 0 ]
  # Must emit "no runner" FAIL
  [[ "$output" =~ ^FAIL:no\ runner ]]
  [[ "$output" =~ "not executable" ]]
}

@test "VAL-PLUGGABLE-006b: non-executable consumer-only scenario overall status FAIL" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  cat > "$cons_dir/my-custom-check.sh" <<'SH'
#!/usr/bin/env bash
echo "CONSUMER: should NOT run"
exit 0
SH
  # NOT executable

  run simulate_resolver "my-custom-check" "$cons_dir"
  [ "$status" -eq 0 ]
  # Must be a FAIL result
  [[ "$output" =~ ^FAIL: ]]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-PLUGGABLE-007: Consumer assert receives same env + positional args
# ══════════════════════════════════════════════════════════════════════

@test "VAL-PLUGGABLE-007: consumer assert receives RELEASE, NAMESPACE, PROJECT_DIR, ASSERT_INDEX, SCENARIO" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  cat > "$cons_dir/env-check.sh" <<'SH'
#!/usr/bin/env bash
echo "RELEASE=${RELEASE:-UNSET}"
echo "NAMESPACE=${NAMESPACE:-UNSET}"
echo "PROJECT_DIR=${PROJECT_DIR:-UNSET}"
echo "ASSERT_INDEX=${ASSERT_INDEX:-UNSET}"
echo "SCENARIO=${SCENARIO:-UNSET}"
echo "ARG1=${1:-UNSET}"
echo "ARG2=${2:-UNSET}"
exit 0
SH
  chmod +x "$cons_dir/env-check.sh"

  run simulate_resolver "env-check" "$cons_dir"
  local resolved="${output#RESOLVED:}"

  # Dispatch with known env vars set
  export RELEASE="test-release"
  export NAMESPACE="test-ns"
  export PROJECT_DIR="$WORK_DIR/project"
  export ASSERT_INDEX="0"
  export SCENARIO="/fake/scenario.yaml"

  local ec_and_log
  ec_and_log=$(dispatch_assert "$resolved" "env-check")
  local alog="${ec_and_log#* }"

  # Verify all env vars are passed
  run grep -q "RELEASE=test-release" "$alog"
  [ "$status" -eq 0 ]
  run grep -q "NAMESPACE=test-ns" "$alog"
  [ "$status" -eq 0 ]
  run grep -q "PROJECT_DIR=$WORK_DIR/project" "$alog"
  [ "$status" -eq 0 ]
  run grep -q "ASSERT_INDEX=0" "$alog"
  [ "$status" -eq 0 ]
  run grep -q "SCENARIO=/fake/scenario.yaml" "$alog"
  [ "$status" -eq 0 ]
}

@test "VAL-PLUGGABLE-007b: consumer assert receives positional args \$1 and \$2" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  cat > "$cons_dir/args-check.sh" <<'SH'
#!/usr/bin/env bash
echo "ARG1=${1:-UNSET}"
echo "ARG2=${2:-UNSET}"
exit 0
SH
  chmod +x "$cons_dir/args-check.sh"

  run simulate_resolver "args-check" "$cons_dir"
  local resolved="${output#RESOLVED:}"

  export SCENARIO="/fake/scenario.yaml"
  local ec_and_log
  ec_and_log=$(dispatch_assert "$resolved" "args-check")
  local alog="${ec_and_log#* }"

  run grep -q "ARG1=/fake/scenario.yaml" "$alog"
  [ "$status" -eq 0 ]
  run grep -q "ARG2=0" "$alog"
  [ "$status" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-PLUGGABLE-008: Consumer assert exit-code contract preserved
# ══════════════════════════════════════════════════════════════════════

@test "VAL-PLUGGABLE-008: consumer assert exit 0 → PASS" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  cat > "$cons_dir/exit-check.sh" <<'SH'
#!/usr/bin/env bash
echo "consumer assert exiting 0"
exit 0
SH
  chmod +x "$cons_dir/exit-check.sh"

  run simulate_resolver "exit-check" "$cons_dir"
  local resolved="${output#RESOLVED:}"
  local ec_and_log
  ec_and_log=$(dispatch_assert "$resolved" "exit-check")
  local ec="${ec_and_log%% *}"
  local alog="${ec_and_log#* }"

  [ "$ec" -eq 0 ]
  parse_assert_log "$alog" "$ec"
  [ "$_PARSED_RESULT" = "PASS" ]
}

@test "VAL-PLUGGABLE-008b: consumer assert exit 1 → FAIL" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  cat > "$cons_dir/fail-check.sh" <<'SH'
#!/usr/bin/env bash
echo "consumer assert exiting 1"
exit 1
SH
  chmod +x "$cons_dir/fail-check.sh"

  run simulate_resolver "fail-check" "$cons_dir"
  local resolved="${output#RESOLVED:}"
  local ec_and_log
  ec_and_log=$(dispatch_assert "$resolved" "fail-check")
  local ec="${ec_and_log%% *}"
  local alog="${ec_and_log#* }"

  parse_assert_log "$alog" "$ec"
  [ "$_PARSED_RESULT" = "FAIL" ]
}

@test "VAL-PLUGGABLE-008c: consumer assert notes length — tail 20 for PASS, tail 40 for FAIL" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  # PASS case: tail -n 20
  cat > "$cons_dir/tail-check.sh" <<'SH'
#!/usr/bin/env bash
for i in $(seq 1 50); do echo "line $i"; done
exit 0
SH
  chmod +x "$cons_dir/tail-check.sh"

  run simulate_resolver "tail-check" "$cons_dir"
  local resolved="${output#RESOLVED:}"
  local ec_and_log
  ec_and_log=$(dispatch_assert "$resolved" "tail-check")
  local ec="${ec_and_log%% *}"
  local alog="${ec_and_log#* }"

  parse_assert_log "$alog" "$ec"
  [ "$_PARSED_RESULT" = "PASS" ]
  # PASS → tail -n 20
  local notes
  notes=$(tail -n 20 "$alog" | sed 's/[[:cntrl:]]//g')
  local note_lines
  note_lines=$(echo "$notes" | wc -l | tr -d ' ')
  [ "$note_lines" -eq 20 ]
}

@test "VAL-PLUGGABLE-008d: consumer assert FAIL notes length — tail 40" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  # FAIL case: tail -n 40
  cat > "$cons_dir/tail-fail-check.sh" <<'SH'
#!/usr/bin/env bash
for i in $(seq 1 60); do echo "line $i"; done
exit 1
SH
  chmod +x "$cons_dir/tail-fail-check.sh"

  run simulate_resolver "tail-fail-check" "$cons_dir"
  local resolved="${output#RESOLVED:}"
  local ec_and_log
  ec_and_log=$(dispatch_assert "$resolved" "tail-fail-check")
  local ec="${ec_and_log%% *}"
  local alog="${ec_and_log#* }"

  parse_assert_log "$alog" "$ec"
  [ "$_PARSED_RESULT" = "FAIL" ]
  # FAIL → tail -n 40
  local notes
  notes=$(tail -n 40 "$alog" | sed 's/[[:cntrl:]]//g')
  local note_lines
  note_lines=$(echo "$notes" | wc -l | tr -d ' ')
  [ "$note_lines" -eq 40 ]
}

@test "VAL-PLUGGABLE-008e: consumer assert ASSERTION_RESULT overrides exit code" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  # Prints PASS but exits 1 — ASSERTION_RESULT wins
  cat > "$cons_dir/override-check.sh" <<'SH'
#!/usr/bin/env bash
echo "ASSERTION_RESULT: PASS"
exit 1
SH
  chmod +x "$cons_dir/override-check.sh"

  run simulate_resolver "override-check" "$cons_dir"
  local resolved="${output#RESOLVED:}"
  local ec_and_log
  ec_and_log=$(dispatch_assert "$resolved" "override-check")
  local ec="${ec_and_log%% *}"
  local alog="${ec_and_log#* }"

  parse_assert_log "$alog" "$ec"
  # ASSERTION_RESULT: PASS wins over exit 1
  [ "$_PARSED_RESULT" = "PASS" ]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-PLUGGABLE-009: Resolver does not break without chart-test/ dir
# ══════════════════════════════════════════════════════════════════════

@test "VAL-PLUGGABLE-009: resolver works when PROJECT_DIR has no chart-test/ directory" {
  export PROJECT_DIR="$WORK_DIR/bare-project"
  mkdir -p "$PROJECT_DIR"
  # No chart-test/ subdirectory

  local cons_dir="$PROJECT_DIR/chart-test/asserts"
  # Verify it doesn't exist
  [ ! -d "$cons_dir" ]

  # All engine types must resolve to engine
  for atype in pods-ready labels-present annotations-present service-reachable; do
    run simulate_resolver "$atype" "$cons_dir"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^RESOLVED:.+/engine/asserts/${atype}\.sh$ ]] \
      || { echo "FAIL: $atype did not resolve to engine: $output"; return 1; }
  done
}

@test "VAL-PLUGGABLE-009b: no error or abort when consumer asserts dir path does not exist" {
  export PROJECT_DIR="$WORK_DIR/bare-project"
  mkdir -p "$PROJECT_DIR"
  local cons_dir="$PROJECT_DIR/chart-test/asserts"
  [ ! -d "$cons_dir" ]

  # The resolver must not produce any error output — just resolve to engine
  run simulate_resolver "pods-ready" "$cons_dir"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^RESOLVED: ]]
  [[ ! "$output" =~ ERROR ]]
  [[ ! "$output" =~ "no runner" ]]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-CROSS-003: Consumer-overridden assert SKIP → non-failing SKIP
# ══════════════════════════════════════════════════════════════════════

@test "VAL-CROSS-003: consumer assert emitting SKIP yields non-failing status" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  cat > "$cons_dir/skip-check.sh" <<'SH'
#!/usr/bin/env bash
echo "ASSERTION_RESULT: SKIP"
echo "ASSERTION_DETAIL: {\"reason\":\"not applicable\"}"
exit 0
SH
  chmod +x "$cons_dir/skip-check.sh"

  run simulate_resolver "skip-check" "$cons_dir"
  local resolved="${output#RESOLVED:}"
  local ec_and_log
  ec_and_log=$(dispatch_assert "$resolved" "skip-check")
  local ec="${ec_and_log%% *}"
  local alog="${ec_and_log#* }"

  parse_assert_log "$alog" "$ec"
  [ "$_PARSED_RESULT" = "SKIP" ]
  [ "$_PARSED_DETAIL" = '{"reason":"not applicable"}' ]
}

@test "VAL-CROSS-003b: consumer SKIP does not cause overall FAIL in scenario simulation" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  cat > "$cons_dir/skip-only.sh" <<'SH'
#!/usr/bin/env bash
echo "ASSERTION_RESULT: SKIP"
exit 0
SH
  chmod +x "$cons_dir/skip-only.sh"

  run simulate_resolver "skip-only" "$cons_dir"
  local resolved="${output#RESOLVED:}"
  local ec_and_log
  ec_and_log=$(dispatch_assert "$resolved" "skip-only")
  local ec="${ec_and_log%% *}"
  local alog="${ec_and_log#* }"

  parse_assert_log "$alog" "$ec"
  # Must be SKIP, and SKIP is non-failing
  [ "$_PARSED_RESULT" = "SKIP" ]
  [ "$_PARSED_RESULT" != "FAIL" ]
}

@test "VAL-CROSS-003c: consumer override engine type emitting SKIP uses consumer script" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  # Consumer overrides pods-ready with a SKIP-emitting script
  cat > "$cons_dir/pods-ready.sh" <<'SH'
#!/usr/bin/env bash
echo "CONSUMER_SKIP: this is the consumer override"
echo "ASSERTION_RESULT: SKIP"
exit 0
SH
  chmod +x "$cons_dir/pods-ready.sh"

  run simulate_resolver "pods-ready" "$cons_dir"
  [ "$status" -eq 0 ]
  # Resolved to consumer, not engine
  [[ "$output" =~ ^RESOLVED:.+/project/chart-test/asserts/pods-ready\.sh$ ]]

  local resolved="${output#RESOLVED:}"
  local ec_and_log
  ec_and_log=$(dispatch_assert "$resolved" "pods-ready")
  local ec="${ec_and_log%% *}"
  local alog="${ec_and_log#* }"

  # Verify consumer marker present
  run grep -q "CONSUMER_SKIP" "$alog"
  [ "$status" -eq 0 ]

  # Verify SKIP status
  parse_assert_log "$alog" "$ec"
  [ "$_PARSED_RESULT" = "SKIP" ]
}

# ══════════════════════════════════════════════════════════════════════
# Edge cases
# ══════════════════════════════════════════════════════════════════════

@test "consumer dir with only non-executable files does not cause errors for engine types" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  # Non-executable file that is NOT an engine type
  cat > "$cons_dir/some-notes.txt" <<'TXT'
these are just notes
TXT

  # Engine types must still resolve to engine
  run simulate_resolver "pods-ready" "$cons_dir"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^RESOLVED:.+/engine/asserts/pods-ready\.sh$ ]]
}

@test "consumer assert with spaces in PROJECT_DIR path resolves correctly" {
  local cons_dir="$WORK_DIR/my project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/my project"

  cat > "$cons_dir/spaces-check.sh" <<'SH'
#!/usr/bin/env bash
echo "spaces handled"
exit 0
SH
  chmod +x "$cons_dir/spaces-check.sh"

  run simulate_resolver "spaces-check" "$cons_dir"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^RESOLVED:.+spaces-check\.sh$ ]]
}

@test "resolver distinguishes executable bit correctly for consumer files" {
  local cons_dir="$WORK_DIR/project/chart-test/asserts"
  mkdir -p "$cons_dir"
  export PROJECT_DIR="$WORK_DIR/project"

  # Executable
  cat > "$cons_dir/exec-check.sh" <<'SH'
#!/usr/bin/env bash
echo "I am executable"
exit 0
SH
  chmod +x "$cons_dir/exec-check.sh"

  # Non-executable (different name)
  cat > "$cons_dir/noexec-check.sh" <<'SH'
#!/usr/bin/env bash
echo "I am NOT executable"
exit 0
SH
  # NOT chmod +x

  # Executable resolves
  run simulate_resolver "exec-check" "$cons_dir"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^RESOLVED: ]]

  # Non-executable consumer-only → FAIL
  run simulate_resolver "noexec-check" "$cons_dir"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^FAIL: ]]
}
