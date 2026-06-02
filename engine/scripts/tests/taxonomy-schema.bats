#!/usr/bin/env bats
# bats tests for scenario.schema.json taxonomy fields (f12-1):
#   - category (string, optional)
#   - capability (string, optional)
#   - integration (string, optional)
#   - tier (enum: live|authored-only|capability, optional)
#   - out-of-enum tier rejected with stderr naming tier
#   - backward compatibility: existing scenarios validate without new fields
#   - full jsonschema sweep over all scenarios exits 0

setup() {
  SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/.."
  ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
  SCHEMA="$ENGINE_DIR/templates/scenario.schema.json"
  SCENARIOS_DIR="$ROOT_DIR/examples/sample-product-chart/chart-test/scenarios"
  TMPDIR="${BATS_TMPDIR:-/tmp}"
  _SCHEMA_TEMPFILES=()
  find "$TMPDIR" -maxdepth 1 -name 'tax-*.yaml' -mmin +5 -delete 2>/dev/null || true
}

teardown() {
  for f in "${_SCHEMA_TEMPFILES[@]+"${_SCHEMA_TEMPFILES[@]}"}"; do
    rm -f "$f" 2>/dev/null || true
  done
}

# Helper: validate a YAML file against the schema.
# Converts YAML→JSON via yq, then pipes to jsonschema.
validate_yaml() {
  local yaml_file="$1"
  yq -o=json "$yaml_file" | jsonschema -i /dev/stdin "$SCHEMA" 2>&1
}

# ── VAL-CAT-003: valid taxonomy fields accepted ──────────────────────

@test "schema accepts scenario with category, capability, and tier=live" {
  tmpscen=$(mktemp "$TMPDIR/tax-live-XXXXX.yaml")
  _SCHEMA_TEMPFILES+=("$tmpscen")
  cat > "$tmpscen" <<'EOF'
---
id: taxonomy-live
category: certificates
capability: tls-cert-management
tier: live
cluster:
  provider: kind
product:
  chart: ./chart
  release: sample
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -eq 0 ]
}

@test "schema accepts scenario with category, integration, and tier=authored-only" {
  tmpscen=$(mktemp "$TMPDIR/tax-authored-XXXXX.yaml")
  _SCHEMA_TEMPFILES+=("$tmpscen")
  cat > "$tmpscen" <<'EOF'
---
id: taxonomy-authored
category: cloud-native
integration: aws-load-balancer-controller
tier: authored-only
cluster:
  provider: eks
product:
  chart: ./chart
  release: sample
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -eq 0 ]
}

@test "schema accepts scenario with tier=capability" {
  tmpscen=$(mktemp "$TMPDIR/tax-cap-XXXXX.yaml")
  _SCHEMA_TEMPFILES+=("$tmpscen")
  cat > "$tmpscen" <<'EOF'
---
id: taxonomy-capability
category: capability
capability: label-all-objects
tier: capability
cluster:
  provider: kind
product:
  chart: ./chart
  release: sample
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -eq 0 ]
}

@test "schema accepts scenario with only category (no capability/integration/tier)" {
  tmpscen=$(mktemp "$TMPDIR/tax-catonly-XXXXX.yaml")
  _SCHEMA_TEMPFILES+=("$tmpscen")
  cat > "$tmpscen" <<'EOF'
---
id: taxonomy-cat-only
category: networking
cluster:
  provider: kind
product:
  chart: ./chart
  release: sample
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -eq 0 ]
}

@test "schema accepts scenario with only tier (no category/capability/integration)" {
  tmpscen=$(mktemp "$TMPDIR/tax-tieronly-XXXXX.yaml")
  _SCHEMA_TEMPFILES+=("$tmpscen")
  cat > "$tmpscen" <<'EOF'
---
id: taxonomy-tier-only
tier: live
cluster:
  provider: kind
product:
  chart: ./chart
  release: sample
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -eq 0 ]
}

# ── VAL-CAT-003: out-of-enum tier rejected with tier-naming error ───

@test "schema rejects tier outside {live, authored-only, capability}" {
  tmpscen=$(mktemp "$TMPDIR/tax-badtier-XXXXX.yaml")
  _SCHEMA_TEMPFILES+=("$tmpscen")
  cat > "$tmpscen" <<'EOF'
---
id: taxonomy-bad-tier
category: networking
tier: someday
cluster:
  provider: kind
product:
  chart: ./chart
  release: sample
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -ne 0 ]
  # stderr must reference the tier field or the enum values
  [[ "${output}" == *"tier"* ]] || [[ "${output}" == *"someday"* ]]
}

@test "schema rejects tier=production (not in enum)" {
  tmpscen=$(mktemp "$TMPDIR/tax-prod-XXXXX.yaml")
  _SCHEMA_TEMPFILES+=("$tmpscen")
  cat > "$tmpscen" <<'EOF'
---
id: taxonomy-prod-tier
category: capability
tier: production
cluster:
  provider: kind
product:
  chart: ./chart
  release: sample
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"tier"* ]] || [[ "${output}" == *"production"* ]]
}

# ── VAL-CAT-004: backward compatibility ──────────────────────────────

@test "pre-existing scenarios lacking taxonomy fields still validate" {
  # These are the original 5 pre-mission scenarios (per architecture §3.6)
  for f in minimal.yaml with-cert-manager.yaml customer-A-istio.yaml customer-B-gatekeeper.yaml subchart-postgres-internal.yaml; do
    scenario="$SCENARIOS_DIR/$f"
    [ -f "$scenario" ] || continue
    run validate_yaml "$scenario"
    [ "$status" -eq 0 ]
  done
}

@test "full jsonschema sweep over all scenarios exits 0" {
  run bash -c 'for f in '"$SCENARIOS_DIR"'/*.yaml '"$SCENARIOS_DIR"'/**/*.yaml; do [ -f "$f" ] || continue; yq -o=json "$f" | jsonschema -i /dev/stdin '"$SCHEMA"' || exit 1; done'
  [ "$status" -eq 0 ]
}
