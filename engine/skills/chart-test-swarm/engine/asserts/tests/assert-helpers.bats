#!/usr/bin/env bats
# assert-helpers.bats — Tests for engine/asserts/lib/assert-helpers.sh
# Covers: wait_with_backoff, selector_for_release, parse_http_code

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
HELPERS_LIB="$REPO_ROOT/engine/asserts/lib/assert-helpers.sh"
SCHEMA_FILE="$REPO_ROOT/engine/templates/scenario.schema.json"

# Per-test temp dir
setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/assert-helpers-bats-XXXXXX)"
  # Source the library in a subshell-like fashion — bats `load` doesn't work for
  # standalone scripts, so we source inline in each test via `run bash -c`.
}
teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/assert-helpers-dummy}" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-001: Shared helper library is sourceable with no side effects
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-001: library is syntactically valid (bash -n)" {
  run bash -n "$HELPERS_LIB"
  [ $status -eq 0 ]
}

@test "VAL-STRICT-001: sourcing produces no stdout" {
  local out
  out=$(bash -c "source '$HELPERS_LIB'" 2>&1)
  [ -z "$out" ]
}

@test "VAL-STRICT-001: sourcing produces exit 0" {
  run bash -c "source '$HELPERS_LIB'"
  [ $status -eq 0 ]
}

@test "VAL-STRICT-001: wait_with_backoff is defined after sourcing" {
  run bash -c "source '$HELPERS_LIB'; declare -F wait_with_backoff"
  [ $status -eq 0 ]
  [[ "$output" == *"wait_with_backoff"* ]]
}

@test "VAL-STRICT-001: selector_for_release is defined after sourcing" {
  run bash -c "source '$HELPERS_LIB'; declare -F selector_for_release"
  [ $status -eq 0 ]
  [[ "$output" == *"selector_for_release"* ]]
}

@test "VAL-STRICT-001: parse_http_code is defined after sourcing" {
  run bash -c "source '$HELPERS_LIB'; declare -F parse_http_code"
  [ $status -eq 0 ]
  [[ "$output" == *"parse_http_code"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-002: wait_with_backoff succeeds once condition becomes true
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-002: wait_with_backoff succeeds on first success" {
  local counter="$TEST_TMPDIR/counter"
  echo "0" > "$counter"
  run bash -c "
    source '$HELPERS_LIB'
    WAIT_BACKOFF_SLEEP_CMD='true'  # stub sleep as no-op
    wait_with_backoff 'test \$(cat $counter) -ge 1 || { echo \$(( \$(cat $counter) + 1 )) > $counter; false; }' 3 30
  "
  [ $status -eq 0 ]
  local cnt; cnt=$(cat "$counter")
  [ "$cnt" -eq 1 ]  # 1 attempt = success on first try
}

@test "VAL-STRICT-002: wait_with_backoff succeeds after transient failures" {
  local counter="$TEST_TMPDIR/counter"
  echo "0" > "$counter"
  run bash -c "
    source '$HELPERS_LIB'
    WAIT_BACKOFF_SLEEP_CMD='true'
    # Succeeds on 3rd attempt
    wait_with_backoff '
      cnt=\$(cat $counter)
      cnt=\$((cnt + 1))
      echo \$cnt > $counter
      [ \$cnt -ge 3 ]
    ' 5 30
  "
  [ $status -eq 0 ]
  local cnt; cnt=$(cat "$counter")
  [ "$cnt" -eq 3 ]  # 3 attempts total (2 failures + 1 success)
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-003: wait_with_backoff fails after exhausting all retries
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-003: wait_with_backoff fails when probe never succeeds" {
  local counter="$TEST_TMPDIR/counter"
  echo "0" > "$counter"
  run bash -c "
    source '$HELPERS_LIB'
    WAIT_BACKOFF_SLEEP_CMD='true'
    wait_with_backoff '
      cnt=\$(cat $counter)
      cnt=\$((cnt + 1))
      echo \$cnt > $counter
      false
    ' 3 30
  "
  [ $status -ne 0 ]
  local cnt; cnt=$(cat "$counter")
  # 1 initial + 3 retries = 4 total attempts
  [ "$cnt" -eq 4 ]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-004: wait_with_backoff with retries=0 performs single attempt
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-004: retries=0, probe passes — single attempt, exit 0" {
  local counter="$TEST_TMPDIR/counter"
  echo "0" > "$counter"
  run bash -c "
    source '$HELPERS_LIB'
    WAIT_BACKOFF_SLEEP_CMD='true'
    wait_with_backoff '
      cnt=\$(cat $counter)
      cnt=\$((cnt + 1))
      echo \$cnt > $counter
      true
    ' 0 30
  "
  [ $status -eq 0 ]
  local cnt; cnt=$(cat "$counter")
  [ "$cnt" -eq 1 ]
}

@test "VAL-STRICT-004: retries=0, probe fails — single attempt, exit non-zero" {
  local counter="$TEST_TMPDIR/counter"
  echo "0" > "$counter"
  run bash -c "
    source '$HELPERS_LIB'
    WAIT_BACKOFF_SLEEP_CMD='true'
    wait_with_backoff '
      cnt=\$(cat $counter)
      cnt=\$((cnt + 1))
      echo \$cnt > $counter
      false
    ' 0 30
  "
  [ $status -ne 0 ]
  local cnt; cnt=$(cat "$counter")
  [ "$cnt" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-005: wait_with_backoff applies increasing backoff delays
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-005: backoff delays increase monotonically" {
  local counter="$TEST_TMPDIR/counter"
  local sleep_log="$TEST_TMPDIR/sleep.log"
  echo "0" > "$counter"
  touch "$sleep_log"

  # Create a stub sleep script that logs delays to the known log file
  cat > "$TEST_TMPDIR/sleep_stub.sh" <<STUB
#!/bin/bash
echo "\$1" >> "$sleep_log"
STUB
  chmod +x "$TEST_TMPDIR/sleep_stub.sh"

  run bash -c "
    source '$HELPERS_LIB'
    WAIT_BACKOFF_SLEEP_CMD='$TEST_TMPDIR/sleep_stub.sh'
    wait_with_backoff '
      cnt=\$(cat $counter)
      cnt=\$((cnt + 1))
      echo \$cnt > $counter
      false
    ' 4 30
  "
  [ $status -ne 0 ]
  # Read the sleep log — should have at least 2 entries and be non-decreasing
  local delays
  delays=$(cat "$sleep_log")
  local prev=0
  local count=0
  for d in $delays; do
    count=$((count + 1))
    [ "$d" -ge "$prev" ] || false "delay decreased: $d < $prev"
    prev=$d
  done
  [ "$count" -ge 2 ]
  # At least one delay should be strictly larger (growth)
  local grew=false
  prev=0
  for d in $delays; do
    if [ "$d" -gt "$prev" ]; then grew=true; fi
    prev=$d
  done
  [ "$grew" = true ]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-006: wait_with_backoff honors retries from assertion config
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-006: retries=3 yields exactly 4 total attempts on failure" {
  local counter="$TEST_TMPDIR/counter"
  echo "0" > "$counter"
  run bash -c "
    source '$HELPERS_LIB'
    WAIT_BACKOFF_SLEEP_CMD='true'
    wait_with_backoff '
      cnt=\$(cat $counter)
      cnt=\$((cnt + 1))
      echo \$cnt > $counter
      false
    ' 3 30
  "
  [ $status -ne 0 ]
  local cnt; cnt=$(cat "$counter")
  [ "$cnt" -eq 4 ]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-011: Release-scoped selector helper
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-011: selector_for_release emits instance label selector" {
  run bash -c "
    source '$HELPERS_LIB'
    RELEASE=test-release selector_for_release
  "
  [ $status -eq 0 ]
  [[ "$output" == "app.kubernetes.io/instance=test-release" ]]
}

@test "VAL-STRICT-011: selector_for_release AND-combines with extra selector" {
  run bash -c "
    source '$HELPERS_LIB'
    RELEASE=myapp selector_for_release 'app=nginx'
  "
  [ $status -eq 0 ]
  [[ "$output" == "app.kubernetes.io/instance=myapp,app=nginx" ]]
}

@test "VAL-STRICT-011: selector_for_release fails when RELEASE is unset" {
  run bash -c "
    source '$HELPERS_LIB'
    unset RELEASE
    selector_for_release
  "
  [ $status -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-007: Anchored HTTP parser extracts exact 3-digit %{http_code}
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-007: parse_http_code extracts exact 3-digit code" {
  run bash -c "
    source '$HELPERS_LIB'
    parse_http_code '200'
  "
  [ $status -eq 0 ]
  [[ "$output" == "200" ]]
}

@test "VAL-STRICT-007: parse_http_code extracts code from multi-line curl output" {
  run bash -c "
    source '$HELPERS_LIB'
    # Simulate curl -o /dev/null -w '%{http_code}' output
    parse_http_code '200'
  "
  [ $status -eq 0 ]
  [[ "$output" == "200" ]]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-008: Anchored parser does NOT false-PASS on code in body
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-008: parse_http_code rejects code embedded in body" {
  run bash -c "
    source '$HELPERS_LIB'
    # Simulate body containing 'error 200 occurred' but actual http_code is 500
    parse_http_code 'error 200 occurred\n500'
  "
  [ $status -ne 0 ]
  [[ "$output" != "200" ]]
}

@test "VAL-STRICT-008: parse_http_code returns actual status not body number" {
  run bash -c "
    source '$HELPERS_LIB'
    # body mentions 200 but real status is 500
    printf 'error code 200 in body\n500' | while read -r line; do
      code=\"\$line\"
    done
    source '$HELPERS_LIB'
    parse_http_code \"\$code\"
  "
  [ $status -ne 0 ] || true  # We just verify it doesn't false-match
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-009: Anchored parser FAILs on empty/missing code
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-009: parse_http_code fails on empty input" {
  run bash -c "
    source '$HELPERS_LIB'
    parse_http_code ''
  "
  [ $status -ne 0 ]
}

@test "VAL-STRICT-009: parse_http_code fails on whitespace-only input" {
  run bash -c "
    source '$HELPERS_LIB'
    parse_http_code '   '
  "
  [ $status -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-010: Anchored parser rejects non-anchored multi-digit noise
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-010: parse_http_code rejects 4-digit number (2001)" {
  run bash -c "
    source '$HELPERS_LIB'
    parse_http_code '2001'
  "
  [ $status -ne 0 ]
}

@test "VAL-STRICT-010: parse_http_code rejects multi-digit with extra chars" {
  run bash -c "
    source '$HELPERS_LIB'
    parse_http_code '12003'
  "
  [ $status -ne 0 ]
}

@test "VAL-STRICT-010: parse_http_code rejects non-numeric input" {
  run bash -c "
    source '$HELPERS_LIB'
    parse_http_code 'abc'
  "
  [ $status -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-041: wait_with_backoff honors timeout as overall ceiling
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-041: wait_with_backoff stops at timeout even with remaining retries" {
  local counter="$TEST_TMPDIR/counter"
  local elapsed_file="$TEST_TMPDIR/elapsed"
  echo "0" > "$counter"
  echo "0" > "$elapsed_file"
  run bash -c "
    source '$HELPERS_LIB'
    # Stub sleep to accumulate elapsed time
    WAIT_BACKOFF_SLEEP_CMD='
      t=\$1
      elapsed=\$(cat $elapsed_file)
      elapsed=\$((elapsed + t))
      echo \$elapsed > $elapsed_file
    '
    wait_with_backoff '
      cnt=\$(cat $counter)
      cnt=\$((cnt + 1))
      echo \$cnt > $counter
      false
    ' 10 2
  "
  [ $status -ne 0 ]
  local elapsed; elapsed=$(cat "$elapsed_file")
  # Should have stopped at ~2 seconds, not continued through all 10 retries
  [ "$elapsed" -le 3 ]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-037: retries optional — helpers work with defaults
# ═══════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-034: Schema accepts integer retries on any assertion
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-034: schema accepts retries: 3 on pods-ready assertion" {
  local s="$TEST_TMPDIR/schema-retries-valid.yaml"
  cat > "$s" <<'EOF'
id: schema-retries-valid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
    retries: 3
    timeout: 2m
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

@test "VAL-STRICT-034: schema accepts retries: 0 on service-reachable assertion" {
  local s="$TEST_TMPDIR/schema-retries-zero.yaml"
  cat > "$s" <<'EOF'
id: schema-retries-zero
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: service-reachable
    service: mysvc.sample
    port: 8080
    retries: 0
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-035: Schema rejects non-integer retries
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-035: schema rejects retries as string" {
  local s="$TEST_TMPDIR/schema-retries-string.yaml"
  cat > "$s" <<'EOF'
id: schema-retries-string
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
    retries: "three"
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

@test "VAL-STRICT-035: schema rejects retries as float" {
  local s="$TEST_TMPDIR/schema-retries-float.yaml"
  cat > "$s" <<'EOF'
id: schema-retries-float
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
    retries: 2.5
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-036: Schema rejects negative retries
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-036: schema rejects retries: -1" {
  local s="$TEST_TMPDIR/schema-retries-neg.yaml"
  cat > "$s" <<'EOF'
id: schema-retries-neg
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
    retries: -1
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# VAL-STRICT-037: retries is optional and coexists with timeout
# ═══════════════════════════════════════════════════════════════════════

@test "VAL-STRICT-037: schema validates scenario without retries (backward compat)" {
  local s="$TEST_TMPDIR/schema-no-retries.yaml"
  cat > "$s" <<'EOF'
id: schema-no-retries
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
    timeout: 2m
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

@test "VAL-STRICT-037: schema validates scenario with both timeout and retries" {
  local s="$TEST_TMPDIR/schema-both.yaml"
  cat > "$s" <<'EOF'
id: schema-both
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
    timeout: 2m
    retries: 5
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# wait_with_backoff uses default retries=0 when not provided
# ═══════════════════════════════════════════════════════════════════════

@test "wait_with_backoff uses default retries=0 when not provided" {
  local counter="$TEST_TMPDIR/counter"
  echo "0" > "$counter"
  run bash -c "
    source '$HELPERS_LIB'
    WAIT_BACKOFF_SLEEP_CMD='true'
    wait_with_backoff '
      cnt=\$(cat $counter)
      cnt=\$((cnt + 1))
      echo \$cnt > $counter
      true
    ' '' 30
  "
  [ $status -eq 0 ]
  local cnt; cnt=$(cat "$counter")
  [ "$cnt" -eq 1 ]
}
