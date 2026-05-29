#!/usr/bin/env bats
# versions-sigint.bats — Tests for f-fix-engine-versions-sigint
#
# Covers:
#   VAL-ENGINE-015: versions.json kind field is a semver-shaped string
#   VAL-ENGINE-027: SIGINT path writes INTERRUPTED status

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
  RUN_SCENARIO="$SCRIPT_DIR/run-scenario.sh"
  [ -f "$RUN_SCENARIO" ]

  # Use modern bash (>= 4) — system /bin/bash on macOS is 3.2
  BASH_CMD="$(command -v bash)"
  if [ -x /opt/homebrew/bin/bash ]; then
    BASH_CMD=/opt/homebrew/bin/bash
  fi
}

_has_modern_bash() {
  [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]
}

# ---------------------------------------------------------------------------
# VAL-ENGINE-015: versions.json kind field is a semver-shaped string
# ---------------------------------------------------------------------------

@test "write_versions_json uses kind version -q (not --short which doesn't exist)" {
  # The script must use 'kind version -q' or a fallback that extracts semver
  # from 'kind version' output, NOT 'kind version --short' which fails on
  # modern kind (v0.31.0+).
  run grep -n 'kind version' "$RUN_SCENARIO"
  [ "$status" -eq 0 ]

  # Must NOT use --short flag (this is the broken code)
  ! grep -q 'kind version --short' "$RUN_SCENARIO" || {
    echo "ERROR: kind version --short is not a valid flag on kind >= 0.31.0" >&2
    echo "       Use 'kind version -q' or 'kind version' with grep extraction" >&2
    false
  }
}

@test "kind binary produces semver-shaped output from version -q" {
  # Verify the local kind binary actually works with 'version -q'
  if ! command -v kind >/dev/null 2>&1; then
    skip "kind not installed"
  fi
  run kind version -q
  [ "$status" -eq 0 ]
  # Output must be semver-shaped: e.g., "0.31.0"
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "ERROR: kind version -q output='$output' does not match semver pattern" >&2
    false
  }
}

@test "kind binary produces semver-shaped output from kind version" {
  # Verify 'kind version' (without -q) also contains a semver string
  if ! command -v kind >/dev/null 2>&1; then
    skip "kind not installed"
  fi
  run kind version
  [ "$status" -eq 0 ]
  # Output should contain something like "kind v0.31.0 go1.25.5 darwin/arm64"
  [[ "$output" =~ v?[0-9]+\.[0-9]+\.[0-9]+ ]] || {
    echo "ERROR: kind version output='$output' does not contain semver version" >&2
    false
  }
}

@test "write_versions_json captures kind version correctly" {
  # Verify the capture command used in write_versions_json produces semver output.
  if ! command -v kind >/dev/null 2>&1; then
    skip "kind not installed"
  fi

  # Run the same capture command used in the script:
  #   _kind=$(kind version -q 2>/dev/null || echo "unknown")
  captured=$(kind version -q 2>/dev/null || echo "unknown")
  echo "captured kind version: '$captured'" >&2

  # Verify it's not "unknown" and is semver-shaped
  [ "$captured" != "unknown" ] || { echo "ERROR: kind version capture returned 'unknown'" >&2; return 1; }
  [[ "$captured" =~ ^v?[0-9]+\.[0-9]+ ]] || {
    echo "ERROR: captured kind version='$captured' does not match semver-ish pattern" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# VAL-ENGINE-027: SIGINT path writes INTERRUPTED status
# ---------------------------------------------------------------------------

@test "run-scenario.sh writes status: INTERRUPTED in SIGINT handler" {
  # The cleanup_on_signal function must write 'status: INTERRUPTED'
  grep -q 'status: INTERRUPTED' "$RUN_SCENARIO" || {
    echo "ERROR: cleanup_on_signal() must write 'status: INTERRUPTED' to result.yaml" >&2
    false
  }
}

@test "run-scenario.sh SIGINT handler sets interrupt flag before calling fail" {
  # The cleanup_on_signal function must set an _interrupted flag
  # so that fail() does not overwrite INTERRUPTED with FAIL.
  grep -q '_interrupted' "$RUN_SCENARIO" || {
    echo "ERROR: must have _interrupted flag to prevent fail() from overwriting INTERRUPTED" >&2
    false
  }
}

@test "run-scenario.sh fail() checks _interrupted before writing FAIL status" {
  # fail() must check the _interrupted flag and skip writing 'status: FAIL'
  # when it's set, to avoid the race between SIGINT trap and set -e.
  grep -A20 '^fail()' "$RUN_SCENARIO" | grep -q '_interrupted' || {
    echo "ERROR: fail() must check _interrupted flag to avoid overwriting INTERRUPTED with FAIL" >&2
    false
  }
}

@test "run-scenario.sh has INT trap set before any || fail commands" {
  # Verify the INT/TERM trap is established early, before cluster operations.
  # The trap line must appear before the first '|| fail' usage.
  trap_line=$(grep -n "trap 'cleanup_on_signal' INT TERM" "$RUN_SCENARIO")
  [ -n "$trap_line" ] || { echo "ERROR: INT TERM trap not found" >&2; return 1; }

  trap_lineno=$(echo "$trap_line" | cut -d: -f1)

  first_fail_line=$(grep -n '|| fail ' "$RUN_SCENARIO" | head -1 | cut -d: -f1)
  [ -n "$first_fail_line" ] || { echo "ERROR: no || fail usage found" >&2; return 1; }

  [ "$trap_lineno" -lt "$first_fail_line" ] || {
    echo "ERROR: INT trap (line $trap_lineno) must be set before first || fail (line $first_fail_line)" >&2
    false
  }
}

@test "run-scenario.sh _interrupted flag initialized to 0 before trap" {
  # The _interrupted flag must be initialized before the trap is set
  interrupted_init=$(grep -n '_interrupted=0' "$RUN_SCENARIO" | head -1 | cut -d: -f1)
  [ -n "$interrupted_init" ] || { echo "ERROR: _interrupted=0 initialization not found" >&2; return 1; }

  trap_line=$(grep -n "trap 'cleanup_on_signal' INT TERM" "$RUN_SCENARIO" | head -1 | cut -d: -f1)
  [ -n "$trap_line" ] || { echo "ERROR: INT TERM trap not found" >&2; return 1; }

  [ "$interrupted_init" -lt "$trap_line" ] || {
    echo "ERROR: _interrupted=0 (line $interrupted_init) must be before trap (line $trap_line)" >&2
    false
  }
}
