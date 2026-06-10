#!/usr/bin/env bats
# check-custom-assertions.bats — Tests for the consumer assert linter
# (feature e-custom-assertion-linter, Area E architecture §3.E.3).
#
# Covers:
#   VAL-PLUGGABLE-019: PASS a well-formed consumer assert
#   VAL-PLUGGABLE-020: FAIL missing executable bit
#   VAL-PLUGGABLE-021: FAIL missing # DEPTH: header
#   VAL-PLUGGABLE-022: FAIL invalid DEPTH value
#   VAL-PLUGGABLE-023: FAIL not declared in any registry
#   VAL-PLUGGABLE-024: Aggregate multiple violations, exit non-zero if ANY fails
#   VAL-PLUGGABLE-025: No-op (exit 0) when no consumer asserts
#   VAL-PLUGGABLE-026: Header depth inconsistent with registry depth
#   VAL-PLUGGABLE-027: Lint gate (verify.sh) invokes check-custom-assertions.sh
#   VAL-PLUGGABLE-028: Resolves checks against correct consumer project dir

setup() {
  TESTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
  export ENGINE_DIR

  LINTER="$SCRIPTS_DIR/check-custom-assertions.sh"
  # Ensure the linter exists (will be created later) — skip if not yet present
  if [ ! -f "$LINTER" ]; then
    skip "check-custom-assertions.sh not yet created"
  fi

  TMPDIR="${BATS_TMPDIR:-/tmp}"
  _CCA_TEMPFILES=()

  # ── Create helper functions ──
  # make_consumer_project: creates a temp project dir with chart-test/asserts/
  # Usage: make_consumer_project [registry_content] [assert_scripts...]
  #   registry_content: YAML content for registry.yaml (empty string = no registry)
  #   assert_scripts: N pairs of (filename, content)
  make_consumer_project() {
    local reg_content="$1"; shift
    local dir; dir=$(mktemp -d "$TMPDIR/cca-XXXXX")
    mkdir -p "$dir/chart-test/asserts"
    if [ -n "$reg_content" ]; then
      printf '%s\n' "$reg_content" > "$dir/chart-test/asserts/registry.yaml"
    fi
    # Remaining args are pairs: filename content
    while [ $# -ge 2 ]; do
      local fname="$1"
      local fcontent="$2"
      shift 2
      printf '%s\n' "$fcontent" > "$dir/chart-test/asserts/$fname"
    done
    echo "$dir"
  }

  # make_consumer_assert: creates a single assert file in the given project dir.
  # Usage: make_consumer_assert <dir> <filename> <content> [executable=true]
  make_consumer_assert() {
    local dir="$1" fname="$2" content="$3" exec="${4:-true}"
    printf '%s\n' "$content" > "$dir/chart-test/asserts/$fname"
    if [ "$exec" = "true" ]; then
      chmod +x "$dir/chart-test/asserts/$fname"
    fi
  }
}

teardown() {
  for f in "${_CCA_TEMPFILES[@]+"${_CCA_TEMPFILES[@]}"}"; do
    rm -rf "$f" 2>/dev/null || true
  done
}

# ── VAL-PLUGGABLE-025: No-op when no consumer asserts ──
@test "VAL-PLUGGABLE-025: exits 0 when no consumer asserts dir" {
  local dir; dir=$(mktemp -d "$TMPDIR/cca-no-dir-XXXXX")
  _CCA_TEMPFILES+=("$dir")
  # Project dir has no chart-test/asserts/ at all
  run bash "$LINTER" "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to lint"* ]] || [[ "$output" == *"no consumer"* ]]
}

@test "VAL-PLUGGABLE-025: exits 0 when consumer asserts dir is empty (no .sh files)" {
  local dir; dir=$(make_consumer_project ""  # empty registry, no assert scripts
  )
  _CCA_TEMPFILES+=("$dir")
  run bash "$LINTER" "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to lint"* ]] || [[ "$output" == *"no consumer"* ]]
}

# ── VAL-PLUGGABLE-019: PASS a well-formed consumer assert ──
@test "VAL-PLUGGABLE-019: PASSes a well-formed consumer assert" {
  local dir; dir=$(make_consumer_project \
    'my-check: L2' \
    'my-check.sh' $'#!/usr/bin/env bash\n# DEPTH: L2\n# My check script\necho "ok"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir")
  chmod +x "$dir/chart-test/asserts/my-check.sh"
  run bash "$LINTER" "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ── VAL-PLUGGABLE-020: FAIL missing executable bit ──
@test "VAL-PLUGGABLE-020: FAILs consumer assert missing executable bit" {
  local dir; dir=$(make_consumer_project \
    'my-check: L2' \
    'my-check.sh' $'#!/usr/bin/env bash\n# DEPTH: L2\necho "ok"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir")
  # NOT chmod +x — file is NOT executable
  run bash "$LINTER" "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not executable"* ]]
  [[ "$output" == *"my-check.sh"* ]]
}

# ── VAL-PLUGGABLE-021: FAIL missing # DEPTH: header ──
@test "VAL-PLUGGABLE-021: FAILs consumer assert missing DEPTH header" {
  local dir; dir=$(make_consumer_project \
    'my-check: L2' \
    'my-check.sh' $'#!/usr/bin/env bash\necho "no header here"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir")
  chmod +x "$dir/chart-test/asserts/my-check.sh"
  run bash "$LINTER" "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing"*"DEPTH"*"header"* ]] || [[ "$output" == *"missing"*"DEPTH"* ]]
  [[ "$output" == *"my-check.sh"* ]]
}

# ── VAL-PLUGGABLE-022: FAIL invalid DEPTH value ──
@test "VAL-PLUGGABLE-022: FAILs consumer assert with invalid DEPTH value 'L9'" {
  local dir; dir=$(make_consumer_project \
    'my-check: L2' \
    'my-check.sh' $'#!/usr/bin/env bash\n# DEPTH: L9\necho "bad depth"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir")
  chmod +x "$dir/chart-test/asserts/my-check.sh"
  run bash "$LINTER" "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"*"DEPTH"* ]] || [[ "$output" == *"invalid"*"L9"* ]]
  [[ "$output" == *"L9"* ]]
}

@test "VAL-PLUGGABLE-022: FAILs consumer assert with invalid DEPTH value 'high'" {
  local dir; dir=$(make_consumer_project \
    'my-check: L2' \
    'my-check.sh' $'#!/usr/bin/env bash\n# DEPTH: high\necho "bad depth"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir")
  chmod +x "$dir/chart-test/asserts/my-check.sh"
  run bash "$LINTER" "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"*"DEPTH"* ]] || [[ "$output" == *"invalid"*"high"* ]]
  [[ "$output" == *"high"* ]]
}

# ── VAL-PLUGGABLE-023: FAIL not declared in any registry ──
@test "VAL-PLUGGABLE-023: FAILs consumer assert not declared in any registry" {
  local dir; dir=$(make_consumer_project \
    '' \
    'undeclared-check.sh' $'#!/usr/bin/env bash\n# DEPTH: L2\necho "ok"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir")
  chmod +x "$dir/chart-test/asserts/undeclared-check.sh"
  run bash "$LINTER" "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not declared"*"registry"* ]] || [[ "$output" == *"not declared"* ]]
  [[ "$output" == *"undeclared-check"* ]]
}

@test "VAL-PLUGGABLE-023: consumer assert declared in engine registry passes" {
  local dir; dir=$(make_consumer_project \
    '' \
    'pods-ready.sh' $'#!/usr/bin/env bash\n# DEPTH: L2\necho "ok"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir")
  chmod +x "$dir/chart-test/asserts/pods-ready.sh"
  run bash "$LINTER" "$dir"
  [ "$status" -eq 0 ]
}

# ── VAL-PLUGGABLE-024: Aggregate multiple violations ──
@test "VAL-PLUGGABLE-024: aggregates multiple violations and exits non-zero" {
  local dir; dir=$(make_consumer_project \
    'good-check: L1
bad-check: L1' \
    'good-check.sh' $'#!/usr/bin/env bash\n# DEPTH: L1\necho "ok"\nexit 0' \
    'noexec-check.sh' $'#!/usr/bin/env bash\n# DEPTH: L1\necho "ok"\nexit 0' \
    'noheader-check.sh' $'#!/usr/bin/env bash\necho "no header"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir")
  chmod +x "$dir/chart-test/asserts/good-check.sh"
  # noexec-check.sh — NOT executable
  chmod +x "$dir/chart-test/asserts/noheader-check.sh"
  run bash "$LINTER" "$dir"
  [ "$status" -ne 0 ]
  # Should report both violations (not just the first one)
  [[ "$output" == *"not executable"* ]]
  [[ "$output" == *"missing"*"DEPTH"* ]] || [[ "$output" == *"missing"* ]]
  # Should NOT stop at first failure — must aggregate
  local violation_count
  violation_count=$(echo "$output" | grep -c "^FAIL:" || true)
  [ "$violation_count" -ge 2 ]
}

# ── VAL-PLUGGABLE-026: Header depth consistency with registry ──
@test "VAL-PLUGGABLE-026: FAILs when header depth != registry depth" {
  local dir; dir=$(make_consumer_project \
    'my-check: L3' \
    'my-check.sh' $'#!/usr/bin/env bash\n# DEPTH: L1\necho "ok"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir")
  chmod +x "$dir/chart-test/asserts/my-check.sh"
  run bash "$LINTER" "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"L1"*"L3"* ]] || [[ "$output" == *"!= "* ]]
}

@test "VAL-PLUGGABLE-026: PASSes when header depth == registry depth" {
  local dir; dir=$(make_consumer_project \
    'my-check: L2' \
    'my-check.sh' $'#!/usr/bin/env bash\n# DEPTH: L2\necho "ok"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir")
  chmod +x "$dir/chart-test/asserts/my-check.sh"
  run bash "$LINTER" "$dir"
  [ "$status" -eq 0 ]
}

# ── VAL-PLUGGABLE-028: Resolve against the correct consumer project dir ──
@test "VAL-PLUGGABLE-028: resolves checks against the correct consumer project dir" {
  local dir1; dir1=$(make_consumer_project \
    'my-check: L2' \
    'my-check.sh' $'#!/usr/bin/env bash\n# DEPTH: L2\necho "ok"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir1")
  chmod +x "$dir1/chart-test/asserts/my-check.sh"

  local dir2; dir2=$(mktemp -d "$TMPDIR/cca-other-XXXXX")
  _CCA_TEMPFILES+=("$dir2")

  # Point linter at dir1 — should pass (well-formed)
  run bash "$LINTER" "$dir1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]

  # Point linter at dir2 — should be no-op (no asserts dir)
  run bash "$LINTER" "$dir2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to lint"* ]] || [[ "$output" == *"no consumer"* ]]
}

# ── VAL-PLUGGABLE-027: Lint gate invokes check-custom-assertions.sh ──
@test "VAL-PLUGGABLE-027: verify.sh invokes check-custom-assertions.sh" {
  local verify_script="$SCRIPTS_DIR/verify.sh"
  [ -f "$verify_script" ]
  # Read verify.sh and confirm it contains a reference to check-custom-assertions.sh
  run grep -q "check-custom-assertions.sh" "$verify_script"
  [ "$status" -eq 0 ]
}

# ── Consumer registry layering in linter ──
@test "consumer registry overrides engine registry for depth consistency check" {
  local dir; dir=$(make_consumer_project \
    'pods-ready: L0' \
    'pods-ready.sh' $'#!/usr/bin/env bash\n# DEPTH: L0\necho "ok"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir")
  chmod +x "$dir/chart-test/asserts/pods-ready.sh"
  # Consumer registry says L0, header says L0 — should pass
  run bash "$LINTER" "$dir"
  [ "$status" -eq 0 ]
}

@test "linter uses consumer registry override for depth consistency — mismatch fails" {
  local dir; dir=$(make_consumer_project \
    'pods-ready: L0' \
    'pods-ready.sh' $'#!/usr/bin/env bash\n# DEPTH: L2\necho "ok"\nexit 0'
  )
  _CCA_TEMPFILES+=("$dir")
  chmod +x "$dir/chart-test/asserts/pods-ready.sh"
  # Consumer registry says L0, header says L2 — should fail
  run bash "$LINTER" "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"L2"*"L0"* ]] || [[ "$output" == *"!= "* ]]
}
