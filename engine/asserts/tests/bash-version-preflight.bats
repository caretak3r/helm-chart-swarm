#!/usr/bin/env bats
# bash-version-preflight.bats — VAL-ENGINE-039: Engine scripts either
# run cleanly under bash 3.2 or fail preflight with a clear bash-version
# error (never the cryptic mapfile: command not found).

SCRIPTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../scripts"

# Scripts that have BASH_VERSINFO preflight (use bash-4+ features)
PREFLIGHT_SCRIPTS=(
  dispatch-swarm.sh
  cluster-up.sh
  cluster-down.sh
  apply-scenario.sh
  run-scenario.sh
  verify.sh
)

# Scripts that DON'T need bash 4+ (no preflight guard)
NO_PREFLIGHT_SCRIPTS=(
  aggregate.sh
  build-dashboard.sh
  orphan-audit.sh
  sweep-scenarios.sh
)

@test "preflight scripts --help works under /bin/bash (3.2) — preflight is after --help" {
  # --help is checked BEFORE the BASH_VERSINFO preflight, so it must
  # exit 0 even under bash 3.2.
  for script in "${PREFLIGHT_SCRIPTS[@]}"; do
    if [ -f "$SCRIPTS_DIR/$script" ]; then
      run /bin/bash "$SCRIPTS_DIR/$script" --help
      [ $status -eq 0 ]
      [[ "$output" == *"Usage"* ]]
    fi
  done
}

@test "no-preflight scripts --help works under /bin/bash (3.2)" {
  # These scripts don't require bash 4+ so --help should work fine.
  for script in "${NO_PREFLIGHT_SCRIPTS[@]}"; do
    if [ -f "$SCRIPTS_DIR/$script" ]; then
      run /bin/bash "$SCRIPTS_DIR/$script" --help
      [ $status -eq 0 ]
      [[ "$output" == *"Usage"* ]]
    fi
  done
}

@test "preflight scripts contain BASH_VERSINFO guard" {
  for script in "${PREFLIGHT_SCRIPTS[@]}"; do
    if [ -f "$SCRIPTS_DIR/$script" ]; then
      grep -q 'BASH_VERSINFO' "$SCRIPTS_DIR/$script"
    fi
  done
}

@test "no-preflight scripts do NOT contain BASH_VERSINFO guard" {
  for script in "${NO_PREFLIGHT_SCRIPTS[@]}"; do
    if [ -f "$SCRIPTS_DIR/$script" ]; then
      ! grep -q 'BASH_VERSINFO' "$SCRIPTS_DIR/$script"
    fi
  done
}

@test "scripts fail with bash version error on /bin/bash (3.2) when --help is NOT passed" {
  # Only test on systems where /bin/bash is < 4
  if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
    skip "System bash is >= 4, version preflight won't trigger"
  fi
  # When scripts are actually run (not --help), the BASH_VERSINFO preflight
  # should block execution under bash 3.2 with a clear error.
  for script in cluster-up.sh cluster-down.sh verify.sh; do
    if [ -f "$SCRIPTS_DIR/$script" ]; then
      # Run the script without --help - preflight fires before arg parsing
      run /bin/bash "$SCRIPTS_DIR/$script" 2>&1 </dev/null
      [ $status -ne 0 ]
      [[ "$output" == *"bash"* ]]
      [[ "$output" == *"4"* ]]
      # Must NOT produce "mapfile: command not found"
      [[ "$output" != *"mapfile: command not found"* ]]
    fi
  done
}

@test "scripts run correctly under modern bash (>= 4)" {
  # Running under the bats bash (which is >= 4), --help should exit 0
  for script in "${PREFLIGHT_SCRIPTS[@]}" "${NO_PREFLIGHT_SCRIPTS[@]}"; do
    if [ -f "$SCRIPTS_DIR/$script" ]; then
      run bash "$SCRIPTS_DIR/$script" --help
      [ $status -eq 0 ]
      [[ "$output" == *"Usage"* ]]
    fi
  done
}
