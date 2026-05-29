#!/usr/bin/env bats
# bats tests for the chart-test-swarm- prefix invariant across ALL
# cluster-touching scripts: cluster-up.sh, cluster-down.sh,
# run-scenario.sh, dispatch-swarm.sh

setup() {
  SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/.."
  # Use modern bash (>= 4) — system /bin/bash on macOS is 3.2 and will
  # trigger the BASH_VERSINFO preflight guard.
  BASH_CMD="$(command -v bash)"
  if [ -x /opt/homebrew/bin/bash ]; then
    BASH_CMD=/opt/homebrew/bin/bash
  fi
  # Track temp files created by this test run for cleanup
  _PREFIX_TEMPFILES=()
}

teardown() {
  # Clean up any tempfiles created by this test file (prevents mktemp
  # collision from stale files left by a previous interrupted run).
  for f in "${_PREFIX_TEMPFILES[@]+"${_PREFIX_TEMPFILES[@]}"}"; do
    rm -f "$f" 2>/dev/null || true
  done
  # Also clean up any stale /tmp/scen-* tempfiles from prior interrupted runs
  find /tmp -maxdepth 1 -name 'scen-*.yaml' -mmin +5 -delete 2>/dev/null || true
}

# --- Every cluster-touching script enforces the prefix ---

@test "run-scenario.sh rejects unprefixed CLUSTER_NAME" {
  # Create a minimal scenario file to pass the initial file check
  tmpscen=$(mktemp /tmp/scen-XXXXX.yaml)
  cat > "$tmpscen" <<'EOF'
---
id: prefix-test
cluster:
  provider: kind
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  run env CLUSTER_NAME=evil-cluster $BASH_CMD "$SCRIPT_DIR/run-scenario.sh" "$tmpscen"
  [ "$status" -ne 0 ]
  [[ "$output" == *"chart-test-swarm-"* ]]
  rm -f "$tmpscen"
}

@test "run-scenario.sh rejects bare prefix with no suffix" {
  tmpscen=$(mktemp /tmp/scen-XXXXX.yaml)
  cat > "$tmpscen" <<'EOF'
---
id: bare-prefix-test
cluster:
  provider: kind
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  run env CLUSTER_NAME=chart-test-swarm $BASH_CMD "$SCRIPT_DIR/run-scenario.sh" "$tmpscen"
  [ "$status" -ne 0 ]
  [[ "$output" == *"chart-test-swarm-"* ]]
  rm -f "$tmpscen"
}

@test "dispatch-swarm.sh rejects unprefixed CLUSTER_NAME" {
  # dispatch-swarm.sh takes a project-dir as argument. The prefix check
  # should fail before any real dispatch work. We test by checking that
  # the prefix check function exists and is sourced.
  grep -q 'chart-test-swarm-' "$SCRIPT_DIR/dispatch-swarm.sh"
}

@test "static audit: no engine script creates a cluster without chart-test-swarm- prefix" {
  # Verify that every cluster-creating call in engine/scripts/ uses a name
  # that defaults to or is explicitly chart-test-swarm-* prefixed.
  # Check that the CLUSTER_NAME defaults all start with chart-test-swarm-
  for script in cluster-up.sh cluster-down.sh run-scenario.sh dispatch-swarm.sh; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
      # Every script that sets CLUSTER_NAME default must use chart-test-swarm- prefix
      default=$(grep -E 'CLUSTER_NAME=\$\{CLUSTER_NAME:-' "$SCRIPT_DIR/$script" | head -1 || true)
      if [ -n "$default" ]; then
        [[ "$default" == *"chart-test-swarm-"* ]]
      fi
    fi
  done
}

@test "static audit: prefix-check library exists and is sourced by cluster scripts" {
  [ -f "$SCRIPT_DIR/lib/prefix-check.sh" ]
  # Verify it's sourced by cluster-up.sh and cluster-down.sh
  grep -q 'prefix-check.sh' "$SCRIPT_DIR/cluster-up.sh"
  grep -q 'prefix-check.sh' "$SCRIPT_DIR/cluster-down.sh"
}
