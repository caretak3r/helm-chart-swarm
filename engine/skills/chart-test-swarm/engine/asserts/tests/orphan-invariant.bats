#!/usr/bin/env bats
# test_orphan_invariant.bats — VAL-ENGINE-023, VAL-ENGINE-024, VAL-CROSS-016,
# VAL-CROSS-017: post-run, no chart-test-swarm-* clusters or containers remain.

SCRIPTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../scripts"

# Use modern bash (>= 4) — system /bin/bash on macOS is 3.2 and will
# trigger the BASH_VERSINFO preflight guard.
BASH_CMD="$(command -v bash)"
if [ -x /opt/homebrew/bin/bash ]; then
  BASH_CMD=/opt/homebrew/bin/bash
fi

@test "orphan-audit.sh exits 0 when no orphans exist" {
  # In a clean environment (no active runs), the audit should find nothing.
  run $BASH_CMD "$SCRIPTS_DIR/orphan-audit.sh"
  [ $status -eq 0 ]
  [[ "$output" == *"zero chart-test-swarm-* kind clusters"* ]]
  [[ "$output" == *"zero chart-test-swarm-* minikube profiles"* ]]
  [[ "$output" == *"zero chart-test-swarm-* docker containers"* ]]
}

@test "orphan-audit.sh --help exits 0" {
  run $BASH_CMD "$SCRIPTS_DIR/orphan-audit.sh" --help
  [ $status -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"orphan-audit.sh"* ]]
}
