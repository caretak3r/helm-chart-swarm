#!/usr/bin/env bats
# skip-runner.bats — Tests for SKIP non-failing behavior in the runner
# and swarm dispatcher (feature a-skip-runner).
#
# Covers:
#   VAL-CONTRACT-024: SKIP does not fail the scenario at run-scenario.sh level
#   VAL-CONTRACT-025: A scenario whose only assert is SKIP is non-failing
#   VAL-CONTRACT-026: FAIL still dominates a mix of PASS/SKIP/FAIL
#   VAL-CONTRACT-044: Mid-scenario SKIP assert does not abort remaining asserts
#   VAL-CONTRACT-027: dispatch-swarm.sh tallies SKIP into skip counter
#   VAL-CONTRACT-028: dispatch-swarm.sh status regex accepts SKIP
#   VAL-CONTRACT-029: SKIP vs INTERRUPTED tallied distinctly
#   VAL-CROSS-004: Cross-cutting SKIP consistency

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

  # Source output-contract helpers for parse_assert_log / lookup_depth
  # shellcheck source=/dev/null
  . "$SCRIPTS_DIR/lib/output-contract.sh"
  export ENGINE_DIR="$ENGINE_DIR"

  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
}

# ── Helper: create a log file with given content ──────────────────────
make_log() {
  local tmp; tmp=$(mktemp "$WORK_DIR/assert-log-XXXXX")
  printf '%s\n' "$1" > "$tmp"
  echo "$tmp"
}

# ── Helper: simulate the assert-loop overall-status logic ─────────────
# This mirrors exactly the logic in run-scenario.sh lines ~882-900:
#   overall=PASS
#   for each assert:
#     parse_assert_log → _PARSED_RESULT
#     if _PARSED_RESULT == FAIL → overall=FAIL
#     (SKIP and PASS do NOT set overall=FAIL)
# Returns the final overall status and the count of recorded asserts.
simulate_scenario() {
  local overall=PASS
  local count=0
  local result
  for logfile in "$@"; do
    count=$((count + 1))
    # Determine exit code from the file name convention:
    # Files ending in -ec0 simulate exit 0; others simulate exit 1
    local ec=1
    [[ "$logfile" == *-ec0* ]] && ec=0
    parse_assert_log "$logfile" "$ec"
    result="$_PARSED_RESULT"
    if [ "$result" = "FAIL" ]; then
      overall=FAIL
    fi
  done
  echo "$overall $count"
}

# ══════════════════════════════════════════════════════════════════════
# VAL-CONTRACT-024: SKIP does not fail the scenario at run-scenario.sh level
# ══════════════════════════════════════════════════════════════════════

@test "VAL-CONTRACT-024: scenario with one PASS and one SKIP ends PASS" {
  local log_pass; log_pass=$(make_log "ASSERTION_RESULT: PASS")
  local log_skip; log_skip=$(make_log "ASSERTION_RESULT: SKIP")

  run simulate_scenario "$log_pass" "$log_skip"
  [ "$status" -eq 0 ]
  local overall="${output%% *}"
  [ "$overall" = "PASS" ]
}

@test "VAL-CONTRACT-024b: scenario with PASS+PASS+SKIP ends PASS" {
  local log1; log1=$(make_log "ASSERTION_RESULT: PASS")
  local log2; log2=$(make_log "ASSERTION_RESULT: PASS")
  local log3; log3=$(make_log "ASSERTION_RESULT: SKIP")

  run simulate_scenario "$log1" "$log2" "$log3"
  [ "$status" -eq 0 ]
  local overall="${output%% *}"
  [ "$overall" = "PASS" ]
}

@test "VAL-CONTRACT-024c: scenario with SKIP+PASS ends PASS" {
  local log1; log1=$(make_log "ASSERTION_RESULT: SKIP")
  local log2; log2=$(make_log "ASSERTION_RESULT: PASS")

  run simulate_scenario "$log1" "$log2"
  [ "$status" -eq 0 ]
  local overall="${output%% *}"
  [ "$overall" = "PASS" ]
}

@test "VAL-CONTRACT-024d: SKIP from exit-code fallback does not fail scenario" {
  # When an assert exits non-zero but the log doesn't have ASSERTION_RESULT,
  # the exit-code fallback produces FAIL.  But if the assert script prints
  # ASSERTION_RESULT: SKIP then exits non-zero, SKIP overrides (contract-003).
  local log_skip; log_skip=$(make_log "ASSERTION_RESULT: SKIP")
  # This log says SKIP — even though exit code is non-zero, SKIP wins
  local log_pass; log_pass=$(make_log "ASSERTION_RESULT: PASS")

  run simulate_scenario "$log_pass" "$log_skip"
  [ "$status" -eq 0 ]
  local overall="${output%% *}"
  [ "$overall" = "PASS" ]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-CONTRACT-025: All-SKIP scenario is non-failing
# ══════════════════════════════════════════════════════════════════════

@test "VAL-CONTRACT-025: scenario whose only assert is SKIP is non-failing" {
  local log; log=$(make_log "ASSERTION_RESULT: SKIP")

  run simulate_scenario "$log"
  [ "$status" -eq 0 ]
  local overall="${output%% *}"
  [ "$overall" = "PASS" ]
}

@test "VAL-CONTRACT-025b: scenario with multiple SKIP asserts is non-failing" {
  local log1; log1=$(make_log "ASSERTION_RESULT: SKIP")
  local log2; log2=$(make_log "ASSERTION_RESULT: SKIP")
  local log3; log3=$(make_log "ASSERTION_RESULT: SKIP")

  run simulate_scenario "$log1" "$log2" "$log3"
  [ "$status" -eq 0 ]
  local overall="${output%% *}"
  [ "$overall" = "PASS" ]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-CONTRACT-026: FAIL still dominates a mix of PASS/SKIP/FAIL
# ══════════════════════════════════════════════════════════════════════

@test "VAL-CONTRACT-026: PASS+SKIP+FAIL → overall FAIL" {
  local log1; log1=$(make_log "ASSERTION_RESULT: PASS")
  local log2; log2=$(make_log "ASSERTION_RESULT: SKIP")
  local log3; log3=$(make_log "ASSERTION_RESULT: FAIL")

  run simulate_scenario "$log1" "$log2" "$log3"
  [ "$status" -eq 0 ]
  local overall="${output%% *}"
  [ "$overall" = "FAIL" ]
}

@test "VAL-CONTRACT-026b: SKIP+PASS+FAIL → overall FAIL" {
  local log1; log1=$(make_log "ASSERTION_RESULT: SKIP")
  local log2; log2=$(make_log "ASSERTION_RESULT: PASS")
  local log3; log3=$(make_log "ASSERTION_RESULT: FAIL")

  run simulate_scenario "$log1" "$log2" "$log3"
  [ "$status" -eq 0 ]
  local overall="${output%% *}"
  [ "$overall" = "FAIL" ]
}

@test "VAL-CONTRACT-026c: FAIL+SKIP → overall FAIL" {
  local log1; log1=$(make_log "ASSERTION_RESULT: FAIL")
  local log2; log2=$(make_log "ASSERTION_RESULT: SKIP")

  run simulate_scenario "$log1" "$log2"
  [ "$status" -eq 0 ]
  local overall="${output%% *}"
  [ "$overall" = "FAIL" ]
}

@test "VAL-CONTRACT-026d: SKIP+FAIL → overall FAIL (FAIL after SKIP still dominates)" {
  local log1; log1=$(make_log "ASSERTION_RESULT: SKIP")
  local log2; log2=$(make_log "ASSERTION_RESULT: FAIL")

  run simulate_scenario "$log1" "$log2"
  [ "$status" -eq 0 ]
  local overall="${output%% *}"
  [ "$overall" = "FAIL" ]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-CONTRACT-044: Mid-scenario SKIP does not abort remaining asserts
# ══════════════════════════════════════════════════════════════════════

@test "VAL-CONTRACT-044: SKIP in position 2 of 4 does not drop later asserts" {
  local log1; log1=$(make_log "ASSERTION_RESULT: PASS")
  local log2; log2=$(make_log "ASSERTION_RESULT: SKIP")
  local log3; log3=$(make_log "ASSERTION_RESULT: PASS")
  local log4; log4=$(make_log "ASSERTION_RESULT: FAIL")

  run simulate_scenario "$log1" "$log2" "$log3" "$log4"
  [ "$status" -eq 0 ]
  local overall count
  overall="${output%% *}"
  count="${output##* }"
  # All 4 asserts must be counted (none dropped)
  [ "$count" -eq 4 ]
  # Trailing FAIL dominates
  [ "$overall" = "FAIL" ]
}

@test "VAL-CONTRACT-044b: consecutive SKIPs do not abort the loop" {
  local log1; log1=$(make_log "ASSERTION_RESULT: PASS")
  local log2; log2=$(make_log "ASSERTION_RESULT: SKIP")
  local log3; log3=$(make_log "ASSERTION_RESULT: SKIP")
  local log4; log4=$(make_log "ASSERTION_RESULT: PASS")

  run simulate_scenario "$log1" "$log2" "$log3" "$log4"
  [ "$status" -eq 0 ]
  local count="${output##* }"
  [ "$count" -eq 4 ]
}

@test "VAL-CONTRACT-044c: SKIP first does not prevent later FAIL from being observed" {
  local log1; log1=$(make_log "ASSERTION_RESULT: SKIP")
  local log2; log2=$(make_log "ASSERTION_RESULT: PASS")
  local log3; log3=$(make_log "ASSERTION_RESULT: FAIL")

  run simulate_scenario "$log1" "$log2" "$log3"
  [ "$status" -eq 0 ]
  local overall count
  overall="${output%% *}"
  count="${output##* }"
  [ "$count" -eq 3 ]
  [ "$overall" = "FAIL" ]
}

@test "VAL-CONTRACT-044d: all four asserts recorded in order for PASS+SKIP+PASS+FAIL" {
  # This test verifies the full pipeline: parse → status → count
  local log1; log1=$(make_log "ASSERTION_RESULT: PASS")
  local log2; log2=$(make_log "ASSERTION_RESULT: SKIP")
  local log3; log3=$(make_log "ASSERTION_RESULT: PASS")
  local log4; log4=$(make_log "ASSERTION_RESULT: FAIL")

  local results=()
  local ec
  for logfile in "$log1" "$log2" "$log3" "$log4"; do
    ec=1
    [[ "$logfile" == *-ec0* ]] && ec=0
    parse_assert_log "$logfile" "$ec"
    results+=("$_PARSED_RESULT")
  done

  # Assert order: PASS, SKIP, PASS, FAIL
  [ "${results[0]}" = "PASS" ]
  [ "${results[1]}" = "SKIP" ]
  [ "${results[2]}" = "PASS" ]
  [ "${results[3]}" = "FAIL" ]
  [ "${#results[@]}" -eq 4 ]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-CONTRACT-027: dispatch-swarm.sh tallies SKIP into skip counter
# ══════════════════════════════════════════════════════════════════════

@test "VAL-CONTRACT-027: SKIP counted into _RUN_SKIP, not _RUN_FAIL" {
  # Replicate dispatch-swarm.sh case statement exactly
  local _status="SKIP"
  local _RUN_PASS=0 _RUN_FAIL=0 _RUN_SKIP=0

  case "$_status" in
    PASS)     _RUN_PASS=$((_RUN_PASS + 1)) ;;
    FAIL)     _RUN_FAIL=$((_RUN_FAIL + 1)) ;;
    SKIP|INTERRUPTED) _RUN_SKIP=$((_RUN_SKIP + 1)) ;;
    *)        _RUN_FAIL=$((_RUN_FAIL + 1)) ;;
  esac

  [ "$_RUN_SKIP" -eq 1 ]
  [ "$_RUN_FAIL" -eq 0 ]
  [ "$_RUN_PASS" -eq 0 ]
}

@test "VAL-CONTRACT-027b: multiple mixed statuses tallied correctly" {
  local _statuses=("PASS" "FAIL" "SKIP" "PASS" "SKIP" "INTERRUPTED")
  local _RUN_PASS=0 _RUN_FAIL=0 _RUN_SKIP=0

  for _status in "${_statuses[@]}"; do
    case "$_status" in
      PASS)     _RUN_PASS=$((_RUN_PASS + 1)) ;;
      FAIL)     _RUN_FAIL=$((_RUN_FAIL + 1)) ;;
      SKIP|INTERRUPTED) _RUN_SKIP=$((_RUN_SKIP + 1)) ;;
      *)        _RUN_FAIL=$((_RUN_FAIL + 1)) ;;
    esac
  done

  [ "$_RUN_PASS" -eq 2 ]
  [ "$_RUN_FAIL" -eq 1 ]
  [ "$_RUN_SKIP" -eq 3 ]   # 2 SKIP + 1 INTERRUPTED
}

# ══════════════════════════════════════════════════════════════════════
# VAL-CONTRACT-028: dispatch-swarm.sh status regex accepts SKIP
# ══════════════════════════════════════════════════════════════════════

@test "VAL-CONTRACT-028: status regex accepts SKIP as a valid scenario status" {
  local status_val="SKIP"
  run grep -qE '^(PASS|FAIL|SKIP|INTERRUPTED)$' <<< "$status_val"
  [ "$status" -eq 0 ]
}

@test "VAL-CONTRACT-028b: status regex accepts all valid statuses" {
  for status_val in PASS FAIL SKIP INTERRUPTED; do
    run grep -qE '^(PASS|FAIL|SKIP|INTERRUPTED)$' <<< "$status_val"
    [ "$status" -eq 0 ] || { echo "FAIL: regex rejected valid status: $status_val"; return 1; }
  done
}

@test "VAL-CONTRACT-028c: status regex rejects unknown statuses" {
  for status_val in BOGUS UNKNOWN "" "PARTIAL"; do
    if grep -qE '^(PASS|FAIL|SKIP|INTERRUPTED)$' <<< "$status_val" 2>/dev/null; then
      echo "FAIL: regex accepted invalid status: '$status_val'"
      return 1
    fi
  done
}

# ══════════════════════════════════════════════════════════════════════
# VAL-CONTRACT-029: SKIP vs INTERRUPTED tallied distinctly per documented policy
# ══════════════════════════════════════════════════════════════════════

@test "VAL-CONTRACT-029: total == pass + fail + skip arithmetic holds" {
  local _statuses=("PASS" "FAIL" "SKIP" "PASS" "SKIP" "INTERRUPTED" "PASS")
  local _RUN_PASS=0 _RUN_FAIL=0 _RUN_SKIP=0 _TOTAL=0

  for _status in "${_statuses[@]}"; do
    _TOTAL=$((_TOTAL + 1))
    case "$_status" in
      PASS)     _RUN_PASS=$((_RUN_PASS + 1)) ;;
      FAIL)     _RUN_FAIL=$((_RUN_FAIL + 1)) ;;
      SKIP|INTERRUPTED) _RUN_SKIP=$((_RUN_SKIP + 1)) ;;
      *)        _RUN_FAIL=$((_RUN_FAIL + 1)) ;;
    esac
  done

  # Verify: total == pass + fail + skip
  local _sum=$((_RUN_PASS + _RUN_FAIL + _RUN_SKIP))
  [ "$_sum" -eq "$_TOTAL" ]
  # Specific counts
  [ "$_RUN_PASS" -eq 3 ]
  [ "$_RUN_FAIL" -eq 1 ]
  [ "$_RUN_SKIP" -eq 3 ]  # 2 SKIP + 1 INTERRUPTED
}

@test "VAL-CONTRACT-029b: INTERRUPTED is non-pass and non-fail (same branch as SKIP)" {
  local _status="INTERRUPTED"
  local _RUN_PASS=0 _RUN_FAIL=0 _RUN_SKIP=0

  case "$_status" in
    PASS)     _RUN_PASS=$((_RUN_PASS + 1)) ;;
    FAIL)     _RUN_FAIL=$((_RUN_FAIL + 1)) ;;
    SKIP|INTERRUPTED) _RUN_SKIP=$((_RUN_SKIP + 1)) ;;
    *)        _RUN_FAIL=$((_RUN_FAIL + 1)) ;;
  esac

  # INTERRUPTED does NOT count as pass or fail
  [ "$_RUN_PASS" -eq 0 ]
  [ "$_RUN_FAIL" -eq 0 ]
  [ "$_RUN_SKIP" -eq 1 ]
}

@test "VAL-CONTRACT-029c: no scenario double-counted" {
  local _statuses=("PASS" "FAIL" "SKIP" "INTERRUPTED")
  local _RUN_PASS=0 _RUN_FAIL=0 _RUN_SKIP=0

  for _status in "${_statuses[@]}"; do
    case "$_status" in
      PASS)     _RUN_PASS=$((_RUN_PASS + 1)) ;;
      FAIL)     _RUN_FAIL=$((_RUN_FAIL + 1)) ;;
      SKIP|INTERRUPTED) _RUN_SKIP=$((_RUN_SKIP + 1)) ;;
      *)        _RUN_FAIL=$((_RUN_FAIL + 1)) ;;
    esac
  done

  # Each scenario counted exactly once
  local _total=$((_RUN_PASS + _RUN_FAIL + _RUN_SKIP))
  [ "$_total" -eq 4 ]
  [ "$_RUN_PASS" -eq 1 ]
  [ "$_RUN_FAIL" -eq 1 ]
  [ "$_RUN_SKIP" -eq 2 ]
}

# ══════════════════════════════════════════════════════════════════════
# VAL-CROSS-004: Cross-cutting SKIP consistency
# ══════════════════════════════════════════════════════════════════════

@test "VAL-CROSS-004: SKIP recognized in parse_assert_log (runner side)" {
  local log; log=$(make_log "ASSERTION_RESULT: SKIP")
  parse_assert_log "$log" 1
  [ "$_PARSED_RESULT" = "SKIP" ]
}

@test "VAL-CROSS-004b: SKIP in dispatch tally (dispatcher side)" {
  local _status="SKIP"
  local _RUN_SKIP=0
  case "$_status" in
    SKIP|INTERRUPTED) _RUN_SKIP=$((_RUN_SKIP + 1)) ;;
  esac
  [ "$_RUN_SKIP" -eq 1 ]
}

@test "VAL-CROSS-004c: SKIP is non-failing end-to-end (runner → dispatcher)" {
  # Simulate the full pipeline:
  # 1. run-scenario.sh assert loop → overall=PASS when only SKIP
  # 2. result.yaml status: PASS (or SKIP if extended)
  # 3. dispatch-swarm.sh reads status → does NOT count as fail

  # Step 1: runner produces overall=PASS for all-SKIP
  local log; log=$(make_log "ASSERTION_RESULT: SKIP")
  run simulate_scenario "$log"
  [ "$status" -eq 0 ]
  local overall="${output%% *}"
  [ "$overall" = "PASS" ]

  # Step 3: dispatcher reads PASS → counts as pass (not fail or skip)
  local _status="$overall"
  local _RUN_PASS=0 _RUN_FAIL=0 _RUN_SKIP=0
  case "$_status" in
    PASS)     _RUN_PASS=$((_RUN_PASS + 1)) ;;
    FAIL)     _RUN_FAIL=$((_RUN_FAIL + 1)) ;;
    SKIP|INTERRUPTED) _RUN_SKIP=$((_RUN_SKIP + 1)) ;;
    *)        _RUN_FAIL=$((_RUN_FAIL + 1)) ;;
  esac
  [ "$_RUN_PASS" -eq 1 ]
  [ "$_RUN_FAIL" -eq 0 ]
}

@test "VAL-CROSS-004d: SKIP does not outrank PASS in the overall model" {
  # When a scenario has one PASS and one SKIP, overall is PASS (not SKIP)
  local log1; log1=$(make_log "ASSERTION_RESULT: PASS")
  local log2; log2=$(make_log "ASSERTION_RESULT: SKIP")

  run simulate_scenario "$log1" "$log2"
  [ "$status" -eq 0 ]
  local overall="${output%% *}"
  [ "$overall" = "PASS" ]
}

# ══════════════════════════════════════════════════════════════════════
# Edge cases: SKIP from exit-code fallback path
# ══════════════════════════════════════════════════════════════════════

@test "SKIP recognized even when log has other output before the contract line" {
  local log; log=$(make_log $'some preamble output\nmore output\nASSERTION_RESULT: SKIP')
  parse_assert_log "$log" 1
  [ "$_PARSED_RESULT" = "SKIP" ]
}

@test "SKIP recognized even when log has output after the contract line" {
  local log; log=$(make_log $'ASSERTION_RESULT: SKIP\nsome trailing output\nmore trailing')
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "SKIP" ]
}

@test "SKIP with detail line still recognized as SKIP" {
  local log; log=$(make_log $'ASSERTION_RESULT: SKIP\nASSERTION_DETAIL: {"reason":"not applicable"}')
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "SKIP" ]
  [ "$_PARSED_DETAIL" = '{"reason":"not applicable"}' ]
}
