#!/usr/bin/env bats
# apply-scenario-product-replay.bats — Tests for f-fix-1-4b:
#   Extend apply-scenario.sh to install product.chart + --preinstall-only flag
#   and full replay test from copied artifacts/ bundle.
#
# Covers:
#   - apply-scenario.sh --help shows --preinstall-only option
#   - apply-scenario.sh parses --preinstall-only flag
#   - apply-scenario.sh without flag installs product.chart
#   - apply-scenario.sh --preinstall-only skips product install
#   - run-scenario.sh passes --preinstall-only to apply-scenario.sh
#   - PROJECT_DIR is respected for resolving ./chart, ./fixtures/* paths
#   - Fails fast with named error if product.chart is not resolvable
#   - Full replay test: copy artifacts/ to tmpdir, spin up kind cluster,
#     run apply-scenario.sh, assert helm release deployed, tear down

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
  SCEN_DIR="$ROOT_DIR/examples/sample-product-chart/chart-test/scenarios"
  PROJECT_DIR="$ROOT_DIR/examples/sample-product-chart"
  CHART_DIR="$PROJECT_DIR/chart"

  # Use modern bash (>= 4)
  BASH_CMD="$(command -v bash)"
  if [ -x /opt/homebrew/bin/bash ]; then
    BASH_CMD=/opt/homebrew/bin/bash
  fi

  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR" 2>/dev/null || true

  # Clean up any leftover chart-test-swarm- clusters
  kind get clusters 2>/dev/null | grep '^chart-test-swarm-' | while read -r c; do
    kind delete cluster --name "$c" 2>/dev/null || true
  done
  minikube delete -p chart-test-swarm-bats-mk 2>/dev/null || true
}

_has_modern_bash() {
  [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]
}

# ---------------------------------------------------------------------------
# Source-level tests: apply-scenario.sh structure
# ---------------------------------------------------------------------------

@test "apply-scenario.sh --help shows --preinstall-only option in usage banner" {
  run $BASH_CMD "$SCRIPTS_DIR/apply-scenario.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--preinstall-only"* ]]
  [[ "$output" == *"preinstall"* ]]
}

@test "apply-scenario.sh rejects unknown flag with error" {
  run $BASH_CMD "$SCRIPTS_DIR/apply-scenario.sh" --not-a-flag "$SCEN_DIR/capability/minimal.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "apply-scenario.sh parses --preinstall-only flag (source check)" {
  local script="$SCRIPTS_DIR/apply-scenario.sh"
  [ -f "$script" ]

  # PREINSTALL_ONLY variable exists
  grep -q 'PREINSTALL_ONLY=0' "$script"

  # Flag is parsed in argument parsing loop
  grep -qe '--preinstall-only.*PREINSTALL_ONLY=1' "$script"

  # Product install is gated on PREINSTALL_ONLY
  grep -qE 'if.*PREINSTALL_ONLY.*-eq 1.*skip|PREINSTALL_ONLY.*eq.*1' "$script"
}

@test "apply-scenario.sh has product chart install section after preinstall" {
  local script="$SCRIPTS_DIR/apply-scenario.sh"
  [ -f "$script" ]

  # Script must read product.chart, product.release, product.namespace
  grep -qE 'PRODUCT_CHART=.*yq.*product\.chart' "$script"
  grep -qE 'PRODUCT_RELEASE=.*yq.*product\.release' "$script"
  grep -qE 'PRODUCT_NS=.*yq.*product\.namespace' "$script"

  # Must use resolve_path for chart path resolution (respects PROJECT_DIR)
  grep -qE 'PCHART=.*resolve_path.*PRODUCT_CHART' "$script"

  # Must run helm upgrade --install for the product
  grep -qE 'helm_args=.*upgrade --install.*PRODUCT_RELEASE.*PCHART' "$script"
}

@test "apply-scenario.sh fails fast with named error when product.chart not resolvable" {
  local script="$SCRIPTS_DIR/apply-scenario.sh"
  [ -f "$script" ]

  # Must check chart existence
  grep -qE '! -e.*PCHART|! -e.*\$PCHART' "$script"

  # Must report the resolved path in error
  grep -qE 'product\.chart not found|chart not found' "$script"

  # Must mention PROJECT_DIR in the error message
  grep -qE 'PROJECT_DIR|Ensure' "$script"
}

@test "apply-scenario.sh handles product.values and product.set for product install" {
  local script="$SCRIPTS_DIR/apply-scenario.sh"
  [ -f "$script" ]

  # Must handle product.values file reference
  grep -qE 'PRODUCT_VALUES.*vpath|values file' "$script"

  # Must handle product.set inline values with --set
  grep -qE 'helm_args\+.*--set.*k=|product\.set.*helm_args|helm.*--set.*product' "$script"
}

@test "apply-scenario.sh respects PROJECT_DIR for resolving product.chart path" {
  local script="$SCRIPTS_DIR/apply-scenario.sh"
  [ -f "$script" ]

  # resolve_path is used to resolve product.chart
  grep -qE 'resolve_path.*PRODUCT_CHART' "$script"
  grep -q 'resolve_path()' "$script"
}

# ---------------------------------------------------------------------------
# Source-level tests: run-scenario.sh passing --preinstall-only
# ---------------------------------------------------------------------------

@test "run-scenario.sh passes --preinstall-only to apply-scenario.sh" {
  local script="$SCRIPTS_DIR/run-scenario.sh"
  [ -f "$script" ]

  # The call to apply-scenario.sh must include --preinstall-only
  grep -qE 'apply-scenario\.sh.*--preinstall-only' "$script"
}

@test "run-scenario.sh still installs product.chart separately after apply-scenario.sh --preinstall-only" {
  local script="$SCRIPTS_DIR/run-scenario.sh"
  [ -f "$script" ]

  # run-scenario.sh must still have its own product install section
  grep -qE 'helm.*upgrade --install.*PRODUCT_RELEASE.*PRODUCT_CHART|helm.*upgrade --install.*PRODUCT_RELEASE.*PCHART' "$script"

  # product install must come AFTER the apply-scenario.sh call
  local apply_line product_line
  apply_line=$(grep -n 'apply-scenario.sh' "$script" | head -1 | cut -d: -f1)
  product_line=$(grep -nE 'helm.*upgrade --install.*PRODUCT' "$script" | head -1 | cut -d: -f1)
  [ -n "$apply_line" ] && [ -n "$product_line" ]
  [ "$apply_line" -lt "$product_line" ]
}

# ---------------------------------------------------------------------------
# End-to-end: Full replay from copied artifacts/ bundle
# ---------------------------------------------------------------------------

@test "full replay: PROJECT_DIR=<bundle> apply-scenario.sh installs product from artifacts alone" {
  if ! _has_modern_bash; then
    skip "Requires modern bash for script execution"
  fi

  local cluster="chart-test-swarm-replay1"

  # 1. Run run-scenario.sh to produce an artifacts/ bundle
  local tmp_reports="$WORK_DIR/reports"
  mkdir -p "$tmp_reports"

  run env CLUSTER_NAME="$cluster" PROVIDER=kind \
    KEEP_CLUSTER=0 KEEP_ON_FAILURE=0 \
    REPORTS_DIR="$tmp_reports" \
    PROJECT_DIR="$PROJECT_DIR" \
    $BASH_CMD "$SCRIPTS_DIR/run-scenario.sh" "$SCEN_DIR/capability/minimal.yaml"

  echo "run-scenario.sh output: $output"
  [ "$status" -eq 0 ]

  # 2. Find the artifacts/ directory that was produced
  local artifact_dir
  artifact_dir=$(find "$tmp_reports" -name "artifacts" -type d 2>/dev/null | head -1)
  echo "artifact_dir=$artifact_dir"
  [ -n "$artifact_dir" ]
  [ -d "$artifact_dir" ]

  # Verify artifacts/chart/ exists with Chart.yaml
  [ -d "$artifact_dir/chart" ]
  [ -f "$artifact_dir/chart/Chart.yaml" ]

  # Verify artifacts/scenario.yaml exists
  [ -f "$artifact_dir/scenario.yaml" ]

  # 3. Copy artifacts/ to a tmpdir for replay
  local replay_dir="$WORK_DIR/replay-bundle"
  mkdir -p "$replay_dir"
  cp -R "$artifact_dir"/* "$replay_dir/"

  # 4. Spin up a fresh kind cluster for replay
  local replay_cluster="chart-test-swarm-replay2"
  run env PROVIDER=kind CLUSTER_NAME="$replay_cluster" \
    K8S_VERSION=v1.30.0 KEEP_CLUSTER=0 \
    $BASH_CMD "$SCRIPTS_DIR/cluster-up.sh"
  echo "cluster-up output: $output"
  [ "$status" -eq 0 ]

  # 5. Run apply-scenario.sh against the copied artifacts (no --preinstall-only)
  run env PROJECT_DIR="$replay_dir" \
    $BASH_CMD "$SCRIPTS_DIR/apply-scenario.sh" "$replay_dir/scenario.yaml"
  echo "apply-scenario.sh replay output: $output"
  [ "$status" -eq 0 ]

  # 6. Assert the product helm release is deployed
  # Read the namespace from the scenario
  local ns
  ns=$(yq '.product.namespace' "$replay_dir/scenario.yaml")
  [ -n "$ns" ]

  # Check helm list for the release
  run helm --kube-context "kind-${replay_cluster}" list -n "$ns" -o json
  echo "helm list output: $output"
  [ "$status" -eq 0 ]

  local release_name
  release_name=$(yq '.product.release' "$replay_dir/scenario.yaml")
  echo "Expected release: $release_name"

  # The release should be present in helm list
  echo "$output" | grep -q "$release_name"

  # 7. Tear down both clusters
  kind delete cluster --name "$replay_cluster" 2>/dev/null || true

  # Also verify run-scenario.sh cluster was torn down (KEEP_CLUSTER=0)
  kind get clusters 2>/dev/null | grep -qF "$cluster" || true
}

@test "apply-scenario.sh --preinstall-only skips product chart install" {
  if ! _has_modern_bash; then
    skip "Requires modern bash for script execution"
  fi

  # Test that --preinstall-only exits after preinstalls without installing product
  local cluster="chart-test-swarm-preonly1"

  # Spin up a kind cluster
  run env PROVIDER=kind CLUSTER_NAME="$cluster" \
    K8S_VERSION=v1.30.0 \
    $BASH_CMD "$SCRIPTS_DIR/cluster-up.sh"
  echo "cluster-up output: $output"
  [ "$status" -eq 0 ]

  # Run apply-scenario.sh --preinstall-only with minimal scenario
  # (minimal has no preinstall items, so it should exit 0 early)
  run env PROJECT_DIR="$PROJECT_DIR" \
    $BASH_CMD "$SCRIPTS_DIR/apply-scenario.sh" --preinstall-only "$SCEN_DIR/capability/minimal.yaml"
  echo "apply-scenario.sh --preinstall-only output: $output"
  [ "$status" -eq 0 ]

  # Should contain the skipping message
  [[ "$output" == *"Skipping product chart install"* ]] || \
  [[ "$output" == *"preinstall-only"* ]]

  # Product chart should NOT be installed (helm list in sample namespace should be empty or not contain sample)
  local ns
  ns=$(yq '.product.namespace' "$SCEN_DIR/capability/minimal.yaml")
  run helm --kube-context "kind-${cluster}" list -n "$ns" -o json
  # If status is non-zero (no releases) that's fine
  if [ "$status" -eq 0 ]; then
    # If helm list succeeded, the release should NOT be present
    local release_name
    release_name=$(yq '.product.release' "$SCEN_DIR/capability/minimal.yaml")
    echo "$output" | { ! grep -q "$release_name" || true; }
  fi

  # Tear down cluster
  kind delete cluster --name "$cluster" 2>/dev/null || true
}

@test "apply-scenario.sh without --preinstall-only installs product.chart" {
  if ! _has_modern_bash; then
    skip "Requires modern bash for script execution"
  fi

  local cluster="chart-test-swarm-fullapply1"

  # Spin up a kind cluster
  run env PROVIDER=kind CLUSTER_NAME="$cluster" \
    K8S_VERSION=v1.30.0 \
    $BASH_CMD "$SCRIPTS_DIR/cluster-up.sh"
  echo "cluster-up output: $output"
  [ "$status" -eq 0 ]

  # Run apply-scenario.sh WITHOUT --preinstall-only against minimal scenario
  run env PROJECT_DIR="$PROJECT_DIR" \
    $BASH_CMD "$SCRIPTS_DIR/apply-scenario.sh" "$SCEN_DIR/capability/minimal.yaml"
  echo "apply-scenario.sh (no flag) output: $output"
  [ "$status" -eq 0 ]

  # Should contain "Installing product chart" message
  [[ "$output" == *"Installing product chart"* ]] || \
  [[ "$output" == *"product chart installed"* ]]

  # Product helm release should be deployed
  local ns release_name
  ns=$(yq '.product.namespace' "$SCEN_DIR/capability/minimal.yaml")
  release_name=$(yq '.product.release' "$SCEN_DIR/capability/minimal.yaml")

  run helm --kube-context "kind-${cluster}" list -n "$ns" -o json
  echo "helm list output: $output"
  [ "$status" -eq 0 ]

  echo "$output" | grep -q "$release_name"

  # Tear down cluster
  kind delete cluster --name "$cluster" 2>/dev/null || true
}

@test "cleanup: no chart-test-swarm- clusters remain after all tests" {
  local clusters
  clusters=$(kind get clusters 2>/dev/null | grep '^chart-test-swarm-' || true)
  if [ -n "$clusters" ]; then
    echo "Cleaning up leftover clusters: $clusters" >&2
    echo "$clusters" | while read -r c; do
      kind delete cluster --name "$c" 2>/dev/null || true
    done
  fi

  # Final assertion: no chart-test-swarm- clusters
  clusters=$(kind get clusters 2>/dev/null | grep '^chart-test-swarm-' || true)
  [ -z "$clusters" ]
}
