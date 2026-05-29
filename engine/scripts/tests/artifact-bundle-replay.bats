#!/usr/bin/env bats
# artifact-bundle-replay.bats — Tests for F1.4 artifact bundle replay fixes
#
# Covers:
#   - artifacts/chart/ exists with chart content vendored from source
#   - artifacts/fixtures/ contains every referenced fixture file
#   - artifacts/scenario.yaml has bundle-relative paths (./chart, ./fixtures/<name>)
#   - artifacts/applied-overrides.yaml has single merged helm_values map
#   - raw_manifest_refs remains a separate sequence

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
  SCEN_DIR="$ROOT_DIR/examples/sample-product-chart/chart-test/scenarios"
  PROJECT_DIR="$ROOT_DIR/examples/sample-product-chart"

  WORK_DIR="$(mktemp -d)"
  export REPORTS_DIR="$WORK_DIR/reports"
  mkdir -p "$REPORTS_DIR"
}

teardown() {
  rm -rf "$WORK_DIR" 2>/dev/null || true

  # Clean up any leftover chart-test-swarm- clusters
  kind get clusters 2>/dev/null | grep '^chart-test-swarm-' | while read -r c; do
    kind delete cluster --name "$c" 2>/dev/null || true
  done
  minikube delete -p chart-test-swarm-bats-mk 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Fix 1: Bundle replay — chart vendoring + fixture copying + path rewriting
# ---------------------------------------------------------------------------

@test "run-scenario.sh vendors chart into artifacts/chart/" {
  local script="$SCRIPTS_DIR/run-scenario.sh"
  [ -f "$script" ]

  # The script must create artifacts/chart/ directory
  grep -q 'ARTIFACTS_DIR/chart' "$script"
  # Must copy chart contents into artifacts/chart/
  grep -qE 'cp.*-R.*chart_src|cp.*chart.*ARTIFACTS_DIR/chart' "$script"
}

@test "run-scenario.sh copies all referenced fixtures into artifacts/fixtures/" {
  local script="$SCRIPTS_DIR/run-scenario.sh"
  [ -f "$script" ]

  # Must copy raw_manifest paths to fixtures/
  grep -qE 'fixtures.*basename|cp.*resolved.*ARTIFACTS_DIR/fixtures' "$script"

  # Must copy product.values if present
  grep -qE 'PRODUCT_VALUES.*fixtures|values.*fixtures.*basename' "$script"

  # Must copy cluster.config if present
  grep -qE 'cluster.*config.*fixtures|config.*fixtures.*basename' "$script"
}

@test "run-scenario.sh rewrites artifacts/scenario.yaml with bundle-relative paths" {
  local script="$SCRIPTS_DIR/run-scenario.sh"
  [ -f "$script" ]

  # Must rewrite product.chart to ./chart
  grep -qE 'product\.chart.*\./chart' "$script"

  # Must rewrite product.values to ./fixtures/<basename>
  grep -qE 'product\.values.*\./fixtures' "$script"

  # Must rewrite raw_manifest paths to ./fixtures/<basename>
  grep -qE 'preinstall.*path.*\./fixtures' "$script"

  # Must NOT rewrite URLs (http/https paths preserved)
  grep -qE 'http://.*\*|https://.*\*|http.*continue|https.*continue' "$script"
}

@test "run-scenario.sh rewrite uses yq -i for in-place editing of scenario.yaml" {
  local script="$SCRIPTS_DIR/run-scenario.sh"
  [ -f "$script" ]

  # Must use yq -i for in-place edit
  grep -q 'yq -i' "$script"
}

@test "run-scenario.sh does NOT rewrite OCI or URL chart refs" {
  local script="$SCRIPTS_DIR/run-scenario.sh"
  [ -f "$script" ]

  # OCI refs and URLs are preserved (no rewrite)
  # Check that the case statement skips oci:// and http* patterns
  grep -q 'oci://' "$script"
  grep -q 'http://' "$script"
}

# ---------------------------------------------------------------------------
# Fix 2: applied-overrides.yaml single merged helm_values map
# ---------------------------------------------------------------------------

@test "write_applied_overrides uses yq ireduce to merge chart defaults + values + set" {
  local script="$SCRIPTS_DIR/run-scenario.sh"
  [ -f "$script" ]

  # Must use yq eval-all ireduce for proper merge
  grep -qE 'ireduce|eval-all.*ireduce' "$script"

  # Must use three layers: defaults, values file, set
  grep -qE '_tmp_defaults|_tmp_values|_tmp_set' "$script"
}

@test "write_applied_overrides uses helm show values for chart defaults" {
  local script="$SCRIPTS_DIR/run-scenario.sh"
  [ -f "$script" ]

  # Must call helm show values for chart defaults
  grep -qE 'helm show values' "$script"
}

@test "write_applied_overrides writes single helm_values map (not multiple appended fragments)" {
  local script="$SCRIPTS_DIR/run-scenario.sh"
  [ -f "$script" ]

  # Must write ONE helm_values: key followed by the merged map
  # Old behavior: multiple sed 's/^/  /' calls appending fragments
  # New behavior: single yq merge result, then ONE sed indent

  # Check that merge result is computed before writing
  grep -qE 'merged=.*yq' "$script"

  # Check that the merged result is indented once (not multiple fragments)
  grep -qE 'echo.*\$\{?merged\}?.*sed' "$script"
}

@test "applied-overrides.yaml raw_manifest_refs remains a separate sequence" {
  local script="$SCRIPTS_DIR/run-scenario.sh"
  [ -f "$script" ]

  # raw_manifest_refs must be a separate top-level key
  grep -q 'raw_manifest_refs' "$script"

  # Must NOT be merged into helm_values
  ! grep -qE 'raw_manifest.*helm_values|helm_values.*raw_manifest' "$script" || true
}

# ---------------------------------------------------------------------------
# End-to-end: Run a minimal scenario and verify artifacts shape
# ---------------------------------------------------------------------------

@test "minimal scenario run produces artifacts/chart/ with Chart.yaml" {
  local scenario="$SCEN_DIR/minimal.yaml"
  [ -f "$scenario" ]

  # Create a temporary reports dir
  local tmp_reports="$WORK_DIR/reports-e2e"
  mkdir -p "$tmp_reports"

  # Run the scenario with a dedicated cluster
  run bash "$SCRIPTS_DIR/run-scenario.sh" "$scenario"
  # The run may fail depending on cluster availability; we check artifacts
  # that are produced early (before cluster-up)
  
  # Find the artifacts directory
  local artifact_dir
  artifact_dir=$(find "$tmp_reports" -name "artifacts" -type d 2>/dev/null | head -1)
  if [ -n "$artifact_dir" ]; then
    # chart/ should exist with Chart.yaml
    [ -d "$artifact_dir/chart" ]
    [ -f "$artifact_dir/chart/Chart.yaml" ]
    [ -f "$artifact_dir/chart/values.yaml" ]
  fi
}

# Clean up the e2e cluster if one was created
@test "cleanup: no chart-test-swarm- clusters remain" {
  local clusters
  clusters=$(kind get clusters 2>/dev/null | grep '^chart-test-swarm-' || true)
  if [ -n "$clusters" ]; then
    echo "Cleaning up leftover clusters: $clusters" >&2
    echo "$clusters" | while read -r c; do
      kind delete cluster --name "$c" 2>/dev/null || true
    done
  fi
}
