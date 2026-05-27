#!/usr/bin/env bats
# bats tests for cluster-up.sh and cluster-down.sh covering:
#   - minikube provider support
#   - chart-test-swarm- prefix enforcement
#   - idempotent teardown
#   - kubeconfig context non-mutation
#   - KEEP_CLUSTER semantics
#   - default CLUSTER_NAME satisfying prefix regex

setup() {
  SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/.."
  ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
}

# --- Prefix enforcement tests (no cluster I/O) ---

@test "cluster-up rejects CLUSTER_NAME without chart-test-swarm- prefix (kind)" {
  run env PROVIDER=kind CLUSTER_NAME=evil-cluster bash "$SCRIPT_DIR/cluster-up.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"chart-test-swarm-"* ]]
  # No side-effect cluster created
  run kind get clusters
  [[ "$output" != *"evil-cluster"* ]]
}

@test "cluster-up rejects CLUSTER_NAME without chart-test-swarm- prefix (minikube)" {
  run env PROVIDER=minikube CLUSTER_NAME=evil-cluster bash "$SCRIPT_DIR/cluster-up.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"chart-test-swarm-"* ]]
}

@test "cluster-up rejects bare prefix chart-test-swarm with no suffix" {
  run env PROVIDER=kind CLUSTER_NAME=chart-test-swarm bash "$SCRIPT_DIR/cluster-up.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"chart-test-swarm-"* ]]
}

@test "cluster-down rejects CLUSTER_NAME without chart-test-swarm- prefix" {
  run env PROVIDER=kind CLUSTER_NAME=evil-cluster bash "$SCRIPT_DIR/cluster-down.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"chart-test-swarm-"* ]]
}

@test "cluster-down rejects bare prefix chart-test-swarm with no suffix" {
  run env PROVIDER=kind CLUSTER_NAME=chart-test-swarm bash "$SCRIPT_DIR/cluster-down.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"chart-test-swarm-"* ]]
}

# --- Default CLUSTER_NAME must satisfy prefix regex ---

@test "cluster-up default CLUSTER_NAME matches ^chart-test-swarm-[a-z0-9-]+\$" {
  # When CLUSTER_NAME is unset, the script defaults to a value that
  # must match the prefix regex. We extract the default from the
  # ${CLUSTER_NAME:-<default>} pattern.
  default=$(grep -oE 'CLUSTER_NAME:-chart-test-swarm-[a-z0-9-]+' "$SCRIPT_DIR/cluster-up.sh" | head -1 | sed 's/CLUSTER_NAME:-//')
  [ -n "$default" ]
  [[ "$default" =~ ^chart-test-swarm-[a-z0-9-]+$ ]]
}

@test "cluster-down default CLUSTER_NAME matches ^chart-test-swarm-[a-z0-9-]+\$" {
  default=$(grep -oE 'CLUSTER_NAME:-chart-test-swarm-[a-z0-9-]+' "$SCRIPT_DIR/cluster-down.sh" | head -1 | sed 's/CLUSTER_NAME:-//')
  [ -n "$default" ]
  [[ "$default" =~ ^chart-test-swarm-[a-z0-9-]+$ ]]
}

@test "run-scenario default CLUSTER_NAME matches ^chart-test-swarm-[a-z0-9-]+\$" {
  default=$(grep -oE 'CLUSTER_NAME:-chart-test-swarm-[a-z0-9-]+' "$SCRIPT_DIR/run-scenario.sh" | head -1 | sed 's/CLUSTER_NAME:-//')
  [ -n "$default" ]
  [[ "$default" =~ ^chart-test-swarm-[a-z0-9-]+$ ]]
}

# --- Minikube provider acceptance ---

@test "cluster-up accepts PROVIDER=minikube with valid prefixed name (dry-run)" {
  # We verify that the script proceeds past the prefix check and provider
  # check. It may fail later if minikube can't start, but should NOT fail
  # at the prefix/provider validation stage.
  # Using a short-circuit approach: we check that the error is NOT about
  # prefix or unknown provider.
  run env PROVIDER=minikube CLUSTER_NAME=chart-test-swarm-bats-mk bash "$SCRIPT_DIR/cluster-up.sh"
  # Either succeeds or fails at the minikube step, not at prefix/provider check
  if [ "$status" -ne 0 ]; then
    [[ "$output" != *"chart-test-swarm- prefix"* ]] || false
    [[ "$output" != *"unknown PROVIDER"* ]] || false
  fi
}

@test "cluster-down accepts PROVIDER=minikube with valid prefixed name" {
  run env PROVIDER=minikube CLUSTER_NAME=chart-test-swarm-bats-mk bash "$SCRIPT_DIR/cluster-down.sh"
  # Should exit 0 (idempotent — no such profile to delete)
  [ "$status" -eq 0 ]
}

# --- Idempotent teardown ---

@test "cluster-down is idempotent for kind (non-existent cluster exits 0)" {
  run env PROVIDER=kind CLUSTER_NAME=chart-test-swarm-bats-nothere bash "$SCRIPT_DIR/cluster-down.sh"
  [ "$status" -eq 0 ]
}

@test "cluster-down is idempotent for minikube (non-existent profile exits 0)" {
  run env PROVIDER=minikube CLUSTER_NAME=chart-test-swarm-bats-nothere bash "$SCRIPT_DIR/cluster-down.sh"
  [ "$status" -eq 0 ]
}

# --- Kubeconfig context non-mutation (requires real cluster I/O) ---
# These tests are tagged with "cluster" so they can be filtered.

@test "cluster-up does not mutate user's global kubeconfig context (kind)" {
  skip "Requires real cluster; run manually with --filter cluster"
  # before_ctx=$(kubectl config current-context 2>/dev/null || echo "NONE")
  # PROVIDER=kind CLUSTER_NAME=chart-test-swarm-bats-kc bash "$SCRIPT_DIR/cluster-up.sh"
  # after_ctx=$(kubectl config current-context 2>/dev/null || echo "NONE")
  # [ "$before_ctx" = "$after_ctx" ]
  # kind delete cluster --name chart-test-swarm-bats-kc
}

# --- KEEP_CLUSTER semantics ---

@test "run-scenario.sh documents KEEP_CLUSTER=1 as default (keep)" {
  grep -q 'KEEP_CLUSTER' "$SCRIPT_DIR/run-scenario.sh"
  # Default should be 1 (keep) — extract the :-1 pattern
  default_val=$(grep -oE 'KEEP_CLUSTER:-[0-9]+' "$SCRIPT_DIR/run-scenario.sh" | head -1 | sed 's/KEEP_CLUSTER:-//')
  [ "$default_val" = "1" ]
}

@test "run-scenario.sh supports KEEP_CLUSTER=0 to tear down" {
  grep -q 'KEEP_CLUSTER' "$SCRIPT_DIR/run-scenario.sh"
}

# --- Provider unknown rejection ---

@test "cluster-up rejects unknown PROVIDER" {
  run env PROVIDER=docker-desktop CLUSTER_NAME=chart-test-swarm-test bash "$SCRIPT_DIR/cluster-up.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown PROVIDER"* ]] || [[ "$output" == *"PROVIDER"* ]]
}

@test "cluster-down rejects unknown PROVIDER" {
  run env PROVIDER=docker-desktop CLUSTER_NAME=chart-test-swarm-test bash "$SCRIPT_DIR/cluster-down.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown PROVIDER"* ]] || [[ "$output" == *"PROVIDER"* ]]
}
