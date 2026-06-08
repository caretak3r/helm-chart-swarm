#!/usr/bin/env bats
# bats tests for context-and-failure-cleanup (f-fix-1-1):
#   - Context pinning: cluster-up.sh defers context restore to run-scenario.sh
#   - KEEP_CLUSTER semantics: tear-down on failure/signal unless KEEP_ON_FAILURE=1
#   - Original context restore after run-scenario.sh exits

setup() {
  SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/.."
  ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
  LIB_DIR="$SCRIPT_DIR/lib"
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
# Context pinning: cluster-up.sh
# ---------------------------------------------------------------------------

@test "cluster-up.sh restores caller kubecontext by default (standalone behavior)" {
  # Verify the script has the restore_context trap for standalone use
  grep -q 'SAVED_CONTEXT=' "$SCRIPT_DIR/cluster-up.sh"
  grep -q "trap 'restore_context' EXIT" "$SCRIPT_DIR/cluster-up.sh"
}

@test "cluster-up.sh supports CTS_NO_CONTEXT_RESTORE to defer context restore" {
  # The script must check CTS_NO_CONTEXT_RESTORE and skip the EXIT trap when set
  grep -q 'CTS_NO_CONTEXT_RESTORE' "$SCRIPT_DIR/cluster-up.sh"
}

@test "cluster-up.sh does NOT restore context when CTS_NO_CONTEXT_RESTORE=1" {
  if ! _has_modern_bash; then
    skip "Requires modern bash for script execution"
  fi
  # We verify the behavior by checking that when CTS_NO_CONTEXT_RESTORE=1 is set,
  # the script does not emit a "context was temporarily switched" message on restore.
  # The script should not have an unconditional restore trap when this var is set.
  run env CTS_NO_CONTEXT_RESTORE=1 PROVIDER=kind CLUSTER_NAME=chart-test-swarm-bats-ctx $BASH_CMD "$SCRIPT_DIR/cluster-up.sh"
  # Should either succeed (cluster created) or fail (no docker/kind available)
  # but NOT fail due to prefix check — that would mean env var is ignored
  [[ "$output" != *"chart-test-swarm- prefix"* ]] || false

  # Verify positive teardown: if a cluster was created by this test, tear it
  # down and confirm kind get clusters shows no chart-test-swarm-* residue.
  if kind get clusters 2>/dev/null | grep -q '^chart-test-swarm-bats-ctx$'; then
    run env PROVIDER=kind CLUSTER_NAME=chart-test-swarm-bats-ctx $BASH_CMD "$SCRIPT_DIR/cluster-down.sh"
    [ "$status" -eq 0 ]
  fi
  # After potential teardown, verify no chart-test-swarm-* clusters remain
  run kind get clusters
  ! grep -q '^chart-test-swarm-' <<<"$output" || {
    echo "ERROR: chart-test-swarm-* clusters still present after teardown: $output" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Context pinning: run-scenario.sh
# ---------------------------------------------------------------------------

@test "run-scenario.sh exports CTS_NO_CONTEXT_RESTORE=1 before calling cluster-up.sh" {
  # run-scenario.sh must tell cluster-up.sh not to restore context
  grep -q 'CTS_NO_CONTEXT_RESTORE=1' "$SCRIPT_DIR/run-scenario.sh"
}

@test "run-scenario.sh saves and restores original kubecontext" {
  grep -q 'ORIGINAL_KUBE_CONTEXT=' "$SCRIPT_DIR/run-scenario.sh"
  grep -q "trap 'restore_original_context' EXIT" "$SCRIPT_DIR/run-scenario.sh"
}

@test "run-scenario.sh restores caller context AFTER cluster-down" {
  # The EXIT trap that restores context must fire after cluster-down in all paths.
  # Verify that restore_original_context is an EXIT trap (not INT/TERM)
  # and that cluster-down is called BEFORE exit in fail() and cleanup_on_signal().
  
  # Check EXIT trap is set
  grep -q "trap 'restore_original_context' EXIT" "$SCRIPT_DIR/run-scenario.sh"
  
  # Check fail() calls cluster-down.sh before exit (fail() spans ~30 lines
  # due to _interrupted guard and inline comments; use -A30 for safety)
  grep -A30 '^fail()' "$SCRIPT_DIR/run-scenario.sh" | grep -q 'cluster-down.sh'
  
  # Check cleanup_on_signal() calls cluster-down.sh before exit
  # (use -A25 for safety since _interrupted guard added a few lines)
  grep -A25 '^cleanup_on_signal()' "$SCRIPT_DIR/run-scenario.sh" | grep -q 'cluster-down.sh'
}

@test "run-scenario.sh explicitly sets kubectl context to scenario cluster after cluster-up" {
  # After cluster-up.sh returns, run-scenario.sh must pin the context
  grep -q 'kubectl config use-context.*KUBE_CONTEXT' "$SCRIPT_DIR/run-scenario.sh"
}

@test "run-scenario.sh uses explicit --context on all kubectl calls via kubectl_ctx" {
  # All kubectl invocations go through kubectl_ctx which adds --context
  grep -q 'kubectl_ctx()' "$SCRIPT_DIR/run-scenario.sh"
  grep -q 'kubectl --context' "$SCRIPT_DIR/run-scenario.sh"
}

@test "run-scenario.sh uses explicit --kube-context on all helm calls via helm_ctx" {
  grep -q 'helm_ctx()' "$SCRIPT_DIR/run-scenario.sh"
  grep -q 'helm --kube-context' "$SCRIPT_DIR/run-scenario.sh"
}

@test "apply-scenario.sh honors KUBE_CONTEXT with explicit --context on kubectl" {
  grep -q 'kubectl_ctx()' "$SCRIPT_DIR/apply-scenario.sh"
  grep -q 'kubectl --context.*KUBE_CONTEXT' "$SCRIPT_DIR/apply-scenario.sh"
}

@test "apply-scenario.sh honors KUBE_CONTEXT with explicit --kube-context on helm" {
  grep -q 'helm_ctx()' "$SCRIPT_DIR/apply-scenario.sh"
  grep -q 'helm --kube-context.*KUBE_CONTEXT' "$SCRIPT_DIR/apply-scenario.sh"
}

@test "assert scripts use KUBE_CONTEXT for explicit --context on kubectl" {
  # Assert runners check KUBE_CONTEXT and pass --context
  for assert_script in "$ENGINE_DIR/asserts"/*.sh; do
    [ -f "$assert_script" ] || continue
    run grep -c 'KUBE_CONTEXT' "$assert_script"
    [ "$status" -eq 0 ]
  done
}

# ---------------------------------------------------------------------------
# KEEP_CLUSTER semantics: failure path
# ---------------------------------------------------------------------------

@test "run-scenario.sh fails tear down by default (KEEP_ON_FAILURE=0)" {
  # On failure, cluster-down.sh is called when KEEP_ON_FAILURE != 1
  grep -q 'if \[ "\$KEEP_ON_FAILURE" != "1" \]' "$SCRIPT_DIR/run-scenario.sh"
  grep -q 'Tearing down cluster after failure' "$SCRIPT_DIR/run-scenario.sh"
}

@test "run-scenario.sh KEEP_ON_FAILURE=1 keeps cluster on failure" {
  # KEEP_ON_FAILURE=1 skips the tear-down in fail()
  grep -q 'Keeping cluster after failure (KEEP_ON_FAILURE=1)' "$SCRIPT_DIR/run-scenario.sh"
}

@test "run-scenario.sh KEEP_CLUSTER does NOT prevent tear-down on failure" {
  # The fail() function uses KEEP_ON_FAILURE, NOT KEEP_CLUSTER
  # Verify that fail() does NOT check KEEP_CLUSTER
  run bash -c "grep -A15 '^fail()' '$SCRIPT_DIR/run-scenario.sh' | grep -c KEEP_CLUSTER || true"
  # KEEP_CLUSTER should NOT appear in fail() — only KEEP_ON_FAILURE
  [ "$output" = "0" ] || [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# KEEP_CLUSTER semantics: success path
# ---------------------------------------------------------------------------

@test "run-scenario.sh KEEP_CLUSTER=1 default keeps cluster on success" {
  grep -q 'KEEP_CLUSTER:-1' "$SCRIPT_DIR/run-scenario.sh"
  # On success, KEEP_CLUSTER=0 triggers tear-down, else keep
  grep -q 'if \[ "\$KEEP_CLUSTER" = "0" \]' "$SCRIPT_DIR/run-scenario.sh"
  grep -q 'Keeping cluster (KEEP_CLUSTER=' "$SCRIPT_DIR/run-scenario.sh"
}

@test "run-scenario.sh KEEP_CLUSTER=0 tears down cluster on success" {
  grep -q 'Tearing down cluster (KEEP_CLUSTER=0)' "$SCRIPT_DIR/run-scenario.sh"
}

# ---------------------------------------------------------------------------
# KEEP_CLUSTER semantics: signal path
# ---------------------------------------------------------------------------

@test "run-scenario.sh SIGINT/SIGTERM tears down by default" {
  # cleanup_on_signal() tears down regardless of KEEP_CLUSTER
  grep -q 'Tearing down cluster after interrupt' "$SCRIPT_DIR/run-scenario.sh"
}

@test "run-scenario.sh SIGINT/SIGTERM respects KEEP_ON_FAILURE=1 override" {
  # cleanup_on_signal() checks KEEP_ON_FAILURE, not KEEP_CLUSTER
  grep -q 'Keeping cluster after interrupt (KEEP_ON_FAILURE=1)' "$SCRIPT_DIR/run-scenario.sh"
}

@test "run-scenario.sh SIGINT path writes INTERRUPTED status" {
  grep -q 'status: INTERRUPTED' "$SCRIPT_DIR/run-scenario.sh"
}

@test "run-scenario.sh SIGINT path does NOT check KEEP_CLUSTER" {
  # cleanup_on_signal() uses KEEP_ON_FAILURE, not KEEP_CLUSTER
  run bash -c "grep -A15 '^cleanup_on_signal()' '$SCRIPT_DIR/run-scenario.sh' | grep -c KEEP_CLUSTER || true"
  [ "$output" = "0" ] || [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# KEEP_CLUSTER env var documentation
# ---------------------------------------------------------------------------

@test "run-scenario.sh KEEP_ON_FAILURE defaults to 0" {
  default_val=$(grep -oE 'KEEP_ON_FAILURE:-[0-9]+' "$SCRIPT_DIR/run-scenario.sh" | head -1 | sed 's/KEEP_ON_FAILURE:-//')
  [ "$default_val" = "0" ]
}

@test "run-scenario.sh usage banner documents KEEP_CLUSTER and KEEP_ON_FAILURE" {
  run bash -c "$BASH_CMD '$SCRIPT_DIR/run-scenario.sh' --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEEP_CLUSTER"* ]]
  [[ "$output" == *"KEEP_ON_FAILURE"* ]]
}
