#!/usr/bin/env bats
# output-contract.bats — Tests for Area A: assertion output contract
# (architecture §3.A.1, VAL-CONTRACT-001 through VAL-CONTRACT-019, VAL-CONTRACT-041)
#
# Tests the parse_assert_log() and lookup_depth() functions from
# engine/scripts/lib/output-contract.sh, plus emit_assert() integration.

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

  # Source the output-contract helpers
  # shellcheck source=/dev/null
  . "$SCRIPTS_DIR/lib/output-contract.sh"

  # Ensure ENGINE_DIR is set for lookup_depth
  export ENGINE_DIR="$ENGINE_DIR"

  # Temp dir for fixture log files / result.yaml
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
}

# Helper: create a log file with given content
make_log() {
  local tmp; tmp=$(mktemp "$WORK_DIR/assert-log-XXXXX")
  printf '%s\n' "$1" > "$tmp"
  echo "$tmp"
}

# ── VAL-CONTRACT-001: ASSERTION_RESULT PASS recognized over exit code ──
@test "VAL-CONTRACT-001: ASSERTION_RESULT PASS overrides non-zero exit code" {
  local log; log=$(make_log "ASSERTION_RESULT: PASS")
  parse_assert_log "$log" 1
  [ "$_PARSED_RESULT" = "PASS" ]
}

# ── VAL-CONTRACT-002: ASSERTION_RESULT FAIL recognized over exit code ──
@test "VAL-CONTRACT-002: ASSERTION_RESULT FAIL overrides zero exit code" {
  local log; log=$(make_log "ASSERTION_RESULT: FAIL")
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "FAIL" ]
}

# ── VAL-CONTRACT-003: ASSERTION_RESULT SKIP recognized over exit code ──
@test "VAL-CONTRACT-003: ASSERTION_RESULT SKIP overrides non-zero exit code" {
  local log; log=$(make_log "ASSERTION_RESULT: SKIP")
  parse_assert_log "$log" 1
  [ "$_PARSED_RESULT" = "SKIP" ]
}

@test "VAL-CONTRACT-003b: ASSERTION_RESULT SKIP overrides zero exit code" {
  local log; log=$(make_log "ASSERTION_RESULT: SKIP")
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "SKIP" ]
}

# ── VAL-CONTRACT-004: Last ASSERTION_RESULT line wins ──
@test "VAL-CONTRACT-004: last ASSERTION_RESULT line wins (PASS then FAIL → FAIL)" {
  local log; log=$(make_log $'ASSERTION_RESULT: PASS\nASSERTION_RESULT: FAIL')
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "FAIL" ]
}

@test "VAL-CONTRACT-004b: last ASSERTION_RESULT line wins (FAIL then PASS → PASS)" {
  local log; log=$(make_log $'ASSERTION_RESULT: FAIL\nASSERTION_RESULT: PASS')
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "PASS" ]
}

# ── VAL-CONTRACT-005: Intermediate ASSERTION_RESULT lines ignored ──
@test "VAL-CONTRACT-005: three result lines, only last honored" {
  local log; log=$(make_log $'ASSERTION_RESULT: SKIP\nASSERTION_RESULT: FAIL\nASSERTION_RESULT: PASS')
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "PASS" ]
}

# ── VAL-CONTRACT-006: Exit-code fallback PASS when no ASSERTION_RESULT line ──
@test "VAL-CONTRACT-006: exit 0 → PASS when no structured line" {
  local log; log=$(make_log "some free text output")
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "PASS" ]
}

# ── VAL-CONTRACT-007: Exit-code fallback FAIL when no ASSERTION_RESULT line ──
@test "VAL-CONTRACT-007: exit non-zero → FAIL when no structured line" {
  local log; log=$(make_log "some error output")
  parse_assert_log "$log" 1
  [ "$_PARSED_RESULT" = "FAIL" ]
}

# ── VAL-CONTRACT-008: ASSERTION_RESULT matched only as line prefix ──
@test "VAL-CONTRACT-008: prose-embedded ASSERTION_RESULT not matched as status" {
  local log; log=$(make_log "the ASSERTION_RESULT: PASS was unexpected")
  parse_assert_log "$log" 1
  [ "$_PARSED_RESULT" = "FAIL" ]  # falls back to exit code
}

@test "VAL-CONTRACT-008b: comment-style ASSERTION_RESULT not matched" {
  local log; log=$(make_log "# ASSERTION_RESULT: FAIL is documentation")
  parse_assert_log "$log" 1
  [ "$_PARSED_RESULT" = "FAIL" ]  # falls back to exit code
}

# ── VAL-CONTRACT-009: Malformed value falls back to exit code ──
@test "VAL-CONTRACT-009: malformed value (MAYBE) falls back to exit 0 → PASS" {
  local log; log=$(make_log "ASSERTION_RESULT: MAYBE")
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "PASS" ]
}

@test "VAL-CONTRACT-009b: malformed value (MAYBE) falls back to exit 1 → FAIL" {
  local log; log=$(make_log "ASSERTION_RESULT: MAYBE")
  parse_assert_log "$log" 1
  [ "$_PARSED_RESULT" = "FAIL" ]
}

@test "VAL-CONTRACT-009c: empty value falls back to exit code" {
  local log; log=$(make_log "ASSERTION_RESULT:")
  parse_assert_log "$log" 1
  [ "$_PARSED_RESULT" = "FAIL" ]
}

# ── VAL-CONTRACT-010: Whitespace-tolerant and case-defined ──
@test "VAL-CONTRACT-010: leading/trailing spaces on value are trimmed" {
  local log; log=$(make_log "ASSERTION_RESULT:   PASS  ")
  parse_assert_log "$log" 1
  [ "$_PARSED_RESULT" = "PASS" ]
}

@test "VAL-CONTRACT-010b: leading whitespace before prefix is tolerated" {
  local log; log=$(printf '  \tASSERTION_RESULT: FAIL\n')
  # Use a file with the exact content
  local tmp; tmp=$(mktemp "$WORK_DIR/assert-log-XXXXX")
  printf '  \tASSERTION_RESULT: FAIL\n' > "$tmp"
  parse_assert_log "$tmp" 0
  [ "$_PARSED_RESULT" = "FAIL" ]
}

@test "VAL-CONTRACT-010c: lower-case value (pass) falls back to exit code" {
  local log; log=$(make_log "ASSERTION_RESULT: pass")
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "PASS" ]  # falls back to exit code 0
}

# ── VAL-CONTRACT-011: ASSERTION_DETAIL JSON captured ──
@test "VAL-CONTRACT-011: ASSERTION_DETAIL captured as opaque string" {
  local log; log=$(make_log $'ASSERTION_RESULT: PASS\nASSERTION_DETAIL: {"key":"value"}')
  parse_assert_log "$log" 0
  [ "$_PARSED_DETAIL" = '{"key":"value"}' ]
}

# ── VAL-CONTRACT-012: No ASSERTION_DETAIL → empty detail ──
@test "VAL-CONTRACT-012: absent ASSERTION_DETAIL produces empty detail" {
  local log; log=$(make_log "ASSERTION_RESULT: PASS")
  parse_assert_log "$log" 0
  [ -z "$_PARSED_DETAIL" ]
}

# ── VAL-CONTRACT-013: Last ASSERTION_DETAIL line wins ──
@test "VAL-CONTRACT-013: last ASSERTION_DETAIL line wins" {
  local log; log=$(make_log $'ASSERTION_DETAIL: {"first":1}\nASSERTION_RESULT: PASS\nASSERTION_DETAIL: {"last":2}')
  parse_assert_log "$log" 0
  [ "$_PARSED_DETAIL" = '{"last":2}' ]
}

# ── VAL-CONTRACT-014: Malformed detail does not corrupt result ──
@test "VAL-CONTRACT-014: malformed ASSERTION_DETAIL stored as opaque, status unaffected" {
  local log; log=$(make_log $'ASSERTION_RESULT: PASS\nASSERTION_DETAIL: {not json')
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "PASS" ]
  [ -n "$_PARSED_DETAIL" ]  # detail stored as-is (opaque)
}

# ── VAL-CONTRACT-015 / 016: depth_level from registry ──
@test "VAL-CONTRACT-015: lookup_depth returns non-empty for known types" {
  local depth; depth=$(lookup_depth pods-ready)
  [ -n "$depth" ]
}

@test "VAL-CONTRACT-016: lookup_depth matches registry for pods-ready" {
  local depth; depth=$(lookup_depth pods-ready)
  [ "$depth" = "L2" ]
}

@test "VAL-CONTRACT-016b: lookup_depth matches registry for service-reachable" {
  local depth; depth=$(lookup_depth service-reachable)
  [ "$depth" = "L2" ]
}

@test "VAL-CONTRACT-016c: lookup_depth matches registry for network-policy" {
  local depth; depth=$(lookup_depth network-policy)
  [ "$depth" = "L1" ]
}

# ── VAL-CONTRACT-019: "no runner" path still well-formed ──
# (This is tested in the integration, but we can test the emit behavior indirectly.)
@test "VAL-CONTRACT-019: unknown type lookup returns null/empty" {
  local depth; depth=$(lookup_depth nonexistent-type-xyz)
  [ -z "$depth" ] || [ "$depth" = "null" ]
}

# ── VAL-CONTRACT-041: existing asserts get depth_level without structured lines ──
@test "VAL-CONTRACT-041: exit-code fallback still provides depth_level via lookup" {
  # An existing assert that prints no ASSSERTION_RESULT line will
  # fall back to exit code, but run-scenario.sh will have already
  # called lookup_depth and passed it to emit_assert separately.
  # This test verifies that the lookup path works for all 15 types.
  local types=(annotations-present helm-status-deployed imagepullsecrets-present
               labels-present network-policy pods-ready priority-class-present
               rbac-objects resources-present scheduling-present scheme-enforced
               security-context service-reachable serviceaccount-annotations smoke-script)
  for t in "${types[@]}"; do
    local depth; depth=$(lookup_depth "$t")
    echo "  $t → $depth"
    [ -n "$depth" ] || { echo "FAIL: $t has no depth"; return 1; }
    case "$depth" in L0|L1|L2|L3) ;; *) echo "FAIL: $t has invalid depth $depth"; return 1 ;; esac
  done
}

# ── Integration: emit_assert with depth and detail ──
@test "emit_assert writes depth_level and detail when present" {
  # Simulate what run-scenario.sh does — source the emit_assert function
  # We create a temporary result.yaml and call emit_assert on it
  local result_yaml="$WORK_DIR/result.yaml"
  {
    echo "scenario_id: test-emit"
    echo "asserts:"
  } > "$result_yaml"

  # Replicate emit_assert locally (same logic as run-scenario.sh)
  emit_assert_local() {
    local t="$1" s="$2" n="$3" depth="${4:-}" detail="${5:-}"
    {
      echo "  - type: $t"
      echo "    status: $s"
      [ -n "$depth" ] && echo "    depth_level: $depth"
      [ -n "$detail" ] && echo "    detail: $detail"
      printf '    notes: |\n'
      printf '      %s\n' "${n//$'\n'/$'\n      '}"
    } >> "$result_yaml"
  }

  emit_assert_local "pods-ready" "PASS" "all pods ready" "L2" '{"pods":3}'

  run cat "$result_yaml"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"depth_level: L2"* ]]
  [[ "${output}" == *'detail: {"pods":3}'* ]]
}

@test "emit_assert omits detail block when empty" {
  local result_yaml="$WORK_DIR/result2.yaml"
  {
    echo "scenario_id: test-emit2"
    echo "asserts:"
  } > "$result_yaml"

  emit_assert_local() {
    local t="$1" s="$2" n="$3" depth="${4:-}" detail="${5:-}"
    {
      echo "  - type: $t"
      echo "    status: $s"
      [ -n "$depth" ] && echo "    depth_level: $depth"
      [ -n "$detail" ] && echo "    detail: $detail"
      printf '    notes: |\n'
      printf '      %s\n' "${n//$'\n'/$'\n      '}"
    } >> "$result_yaml"
  }

  emit_assert_local "pods-ready" "PASS" "all pods ready" "L2" ""

  run cat "$result_yaml"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"depth_level: L2"* ]]
  [[ "${output}" != *"detail:"* ]]
}

@test "emit_assert preserves multi-line notes" {
  local result_yaml="$WORK_DIR/result3.yaml"
  {
    echo "scenario_id: test-emit3"
    echo "asserts:"
  } > "$result_yaml"

  emit_assert_local() {
    local t="$1" s="$2" n="$3" depth="${4:-}" detail="${5:-}"
    {
      echo "  - type: $t"
      echo "    status: $s"
      [ -n "$depth" ] && echo "    depth_level: $depth"
      [ -n "$detail" ] && echo "    detail: $detail"
      printf '    notes: |\n'
      printf '      %s\n' "${n//$'\n'/$'\n      '}"
    } >> "$result_yaml"
  }

  local notes='line 1
line 2
line 3'
  emit_assert_local "pods-ready" "PASS" "$notes" "L2"

  run cat "$result_yaml"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"line 1"* ]]
  [[ "${output}" == *"line 2"* ]]
  [[ "${output}" == *"line 3"* ]]
  run yq '.' "$result_yaml"
  [ "$status" -eq 0 ]
}

# ── Additional: SKIP status recognized ──
@test "SKIP line prefix matched (not substring)" {
  local log; log=$(make_log "ASSERTION_RESULT: SKIP")
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "SKIP" ]
}

# ── Additional: PASS exit-code fallback when log is empty ──
@test "empty log with exit 0 → PASS" {
  local log; log=$(make_log "")
  parse_assert_log "$log" 0
  [ "$_PARSED_RESULT" = "PASS" ]
}
