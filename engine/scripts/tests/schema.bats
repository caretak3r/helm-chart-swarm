#!/usr/bin/env bats
# bats tests for scenario.schema.json covering:
#   - minikube in provider enum
#   - rejection of unknown providers
#   - pre-existing scenarios still validate

setup() {
  SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/.."
  ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
  SCHEMA="$ENGINE_DIR/templates/scenario.schema.json"
  SCENARIOS_DIR="$ROOT_DIR/examples/sample-product-chart/chart-test/scenarios"
  TMPDIR="${BATS_TMPDIR:-/tmp}"
  # Track temp files created by this test run for cleanup
  _SCHEMA_TEMPFILES=()
  # Clean up stale tempfiles from interrupted prior runs before any test
  find "$TMPDIR" -maxdepth 1 -name 'scen-*.yaml' -mmin +5 -delete 2>/dev/null || true
}

teardown() {
  # Clean up any tempfiles created by this test file (prevents mktemp
  # collision from stale files left by a previous interrupted run).
  for f in "${_SCHEMA_TEMPFILES[@]+"${_SCHEMA_TEMPFILES[@]}"}"; do
    rm -f "$f" 2>/dev/null || true
  done
}

# Helper: validate a YAML string against the schema.
# Converts YAML→JSON via yq, then pipes to jsonschema.
validate_yaml() {
  local yaml_file="$1"
  yq -o=json "$yaml_file" | jsonschema -i /dev/stdin "$SCHEMA" 2>&1
}

@test "schema accepts cluster.provider=minikube" {
  tmpscen=$(mktemp "$TMPDIR/scen-minikube-XXXXX.yaml")
  _SCHEMA_TEMPFILES+=("$tmpscen")
  cat > "$tmpscen" <<'EOF'
---
id: test-minikube
cluster:
  provider: minikube
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -eq 0 ]
}

@test "schema rejects unknown cluster.provider" {
  tmpscen=$(mktemp "$TMPDIR/scen-badprov-XXXXX.yaml")
  _SCHEMA_TEMPFILES+=("$tmpscen")
  cat > "$tmpscen" <<'EOF'
---
id: test-bad-provider
cluster:
  provider: rancher-desktop
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"rancher-desktop"* ]] || [[ "${output}" == *"not one of"* ]]
}

@test "pre-existing scenarios still validate after schema changes" {
  for f in "$SCENARIOS_DIR"/*.yaml; do
    run validate_yaml "$f"
    [ "$status" -eq 0 ]
  done
}
