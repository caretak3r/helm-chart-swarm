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
}

# Helper: validate a YAML string against the schema.
# Converts YAML→JSON via yq, then pipes to jsonschema.
validate_yaml() {
  local yaml_file="$1"
  yq -o=json "$yaml_file" | jsonschema -i /dev/stdin "$SCHEMA" 2>&1
}

@test "schema accepts cluster.provider=minikube" {
  tmpscen=$(mktemp "$TMPDIR/scen-minikube-XXXXX.yaml")
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
  rm -f "$tmpscen"
}

@test "schema rejects unknown cluster.provider" {
  tmpscen=$(mktemp "$TMPDIR/scen-badprov-XXXXX.yaml")
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
  [[ "${output}" == *"provider"* ]] || [[ "${output}" == *"enum"* ]]
  rm -f "$tmpscen"
}

@test "pre-existing scenarios still validate after schema changes" {
  for f in "$SCENARIOS_DIR"/*.yaml; do
    run validate_yaml "$f"
    [ "$status" -eq 0 ]
  done
}
