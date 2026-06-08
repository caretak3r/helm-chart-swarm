#!/usr/bin/env bats
# test_help_banner.bats — VAL-ENGINE-028: Every engine script accepts --help
# and exits 0 with a Usage banner; no cluster ops performed.

SCRIPTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../scripts"

# Use modern bash (>= 4) — system /bin/bash on macOS is 3.2 and will
# trigger the BASH_VERSINFO preflight guard.
BASH_CMD="$(command -v bash)"
if [ -x /opt/homebrew/bin/bash ]; then
  BASH_CMD=/opt/homebrew/bin/bash
fi

# All engine entry-point scripts that must support --help
ENTRY_SCRIPTS=(
  cluster-up.sh
  cluster-down.sh
  apply-scenario.sh
  run-scenario.sh
  dispatch-swarm.sh
  build-dashboard.sh
  aggregate.sh
)

@test "verify.sh --help exits 0 with Usage banner" {
  run $BASH_CMD "$SCRIPTS_DIR/verify.sh" --help
  [ $status -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"verify.sh"* ]]
}

@test "cluster-up.sh --help exits 0 with Usage banner" {
  run $BASH_CMD "$SCRIPTS_DIR/cluster-up.sh" --help
  [ $status -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"cluster-up.sh"* ]]
}

@test "cluster-down.sh --help exits 0 with Usage banner" {
  run $BASH_CMD "$SCRIPTS_DIR/cluster-down.sh" --help
  [ $status -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"cluster-down.sh"* ]]
}

@test "apply-scenario.sh --help exits 0 with Usage banner" {
  run $BASH_CMD "$SCRIPTS_DIR/apply-scenario.sh" --help
  [ $status -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"apply-scenario.sh"* ]]
}

@test "run-scenario.sh --help exits 0 with Usage banner" {
  run $BASH_CMD "$SCRIPTS_DIR/run-scenario.sh" --help
  [ $status -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"run-scenario.sh"* ]]
}

@test "dispatch-swarm.sh --help exits 0 with Usage banner" {
  run $BASH_CMD "$SCRIPTS_DIR/dispatch-swarm.sh" --help
  [ $status -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"dispatch-swarm.sh"* ]]
}

@test "build-dashboard.sh --help exits 0 with Usage banner" {
  run $BASH_CMD "$SCRIPTS_DIR/build-dashboard.sh" --help
  [ $status -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"build-dashboard.sh"* ]]
}

@test "aggregate.sh --help exits 0 with Usage banner" {
  run $BASH_CMD "$SCRIPTS_DIR/aggregate.sh" --help
  [ $status -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"aggregate.sh"* ]]
}

@test "sweep-scenarios.sh --help exits 0 with Usage banner" {
  run $BASH_CMD "$SCRIPTS_DIR/sweep-scenarios.sh" --help
  [ $status -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"sweep-scenarios.sh"* ]]
}

@test "orphan-audit.sh --help exits 0 with Usage banner" {
  run $BASH_CMD "$SCRIPTS_DIR/orphan-audit.sh" --help
  [ $status -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"orphan-audit.sh"* ]]
}

@test "no cluster operations performed during --help" {
  # After running all --help invocations, verify no new clusters appeared.
  # This is a belt-and-suspenders check — --help must not create clusters.
  run kind get clusters 2>/dev/null
  # No chart-test-swarm-* clusters should exist
  ! echo "$output" | grep -q '^chart-test-swarm-'
}
