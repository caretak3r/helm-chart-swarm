#!/usr/bin/env bats
# capability-assert-runners.bats — Tests for the addon-less capability assert
# family: labels-present, annotations-present, scheme-enforced, rbac-objects.
# Covers PASS and FAIL paths for each runner using rendered (helm template) source.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
ASSERTS_DIR="$REPO_ROOT/engine/asserts"
SCHEMA_FILE="$REPO_ROOT/engine/templates/scenario.schema.json"
PROJECT_DIR="$REPO_ROOT/examples/sample-product-chart"

# Per-test temp dir
setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/cap-assert-bats-XXXXXX)"
}
teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/cap-assert-dummy}" 2>/dev/null || true
}

# Helper: run a capability assert runner with PROJECT_DIR set.
run_assert() {
  local runner="$1"
  local scenario="$2"
  local idx="${3:-0}"
  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/$runner" "$scenario" "$idx"
}

# ═══════════════════════════════════════════════════════════════════════
# labels-present
# ═══════════════════════════════════════════════════════════════════════

@test "labels-present: PASS when expected labels exist on Deployment (with kinds filter)" {
  local s="$TEST_TMPDIR/lbl-pass.yaml"
  cat > "$s" <<'EOF'
id: lbl-pass
name: labels-present PASS test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: labels-present
    namespace: sample
    source: rendered
    labels:
      app.kubernetes.io/instance: test-release
      app.kubernetes.io/name: sample-product
    kinds:
      - Deployment
EOF
  run_assert "labels-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "labels-present: PASS when checking all objects for instance label" {
  local s="$TEST_TMPDIR/lbl-pass-all.yaml"
  cat > "$s" <<'EOF'
id: lbl-pass-all
name: labels-present PASS all objects
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: labels-present
    namespace: sample
    source: rendered
    labels:
      app.kubernetes.io/instance: test-release
    kinds:
      - Deployment
EOF
  run_assert "labels-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "labels-present: FAIL when expected label is missing from rendered objects" {
  local s="$TEST_TMPDIR/lbl-fail-missing.yaml"
  cat > "$s" <<'EOF'
id: lbl-fail-missing
name: labels-present FAIL test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: labels-present
    namespace: sample
    source: rendered
    labels:
      nonexistent-label: some-value
    kinds:
      - Deployment
EOF
  run_assert "labels-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]]
}

@test "labels-present: FAIL when no labels specified" {
  local s="$TEST_TMPDIR/lbl-fail-empty.yaml"
  cat > "$s" <<'EOF'
id: lbl-fail-empty
name: labels-present empty labels
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: labels-present
    namespace: sample
    source: rendered
    labels: {}
EOF
  run_assert "labels-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"no labels specified"* ]]
}

@test "labels-present: FAIL when Service lacks expected labels" {
  local s="$TEST_TMPDIR/lbl-fail-svc.yaml"
  cat > "$s" <<'EOF'
id: lbl-fail-svc
name: labels-present FAIL Service
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: labels-present
    namespace: sample
    source: rendered
    labels:
      app.kubernetes.io/instance: test-release
    kinds:
      - Service
EOF
  # Service in sample chart has no labels, so this should FAIL
  run_assert "labels-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# annotations-present
# ═══════════════════════════════════════════════════════════════════════

@test "annotations-present: PASS when mesh inject annotation exists on Deployment" {
  local s="$TEST_TMPDIR/ann-pass.yaml"
  cat > "$s" <<'EOF'
id: ann-pass
name: annotations-present PASS mesh inject
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
  set:
    mesh.inject: true
asserts:
  - type: annotations-present
    namespace: sample
    source: rendered
    annotations:
      sidecar.istio.io/inject: "true"
    kinds:
      - Deployment
EOF
  run_assert "annotations-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "annotations-present: FAIL when expected annotation is missing" {
  local s="$TEST_TMPDIR/ann-fail-missing.yaml"
  cat > "$s" <<'EOF'
id: ann-fail-missing
name: annotations-present FAIL missing
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: annotations-present
    namespace: sample
    source: rendered
    annotations:
      nonexistent-annotation: some-value
    kinds:
      - Deployment
EOF
  run_assert "annotations-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]]
}

@test "annotations-present: FAIL when no annotations specified" {
  local s="$TEST_TMPDIR/ann-fail-empty.yaml"
  cat > "$s" <<'EOF'
id: ann-fail-empty
name: annotations-present empty
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: annotations-present
    namespace: sample
    source: rendered
    annotations: {}
EOF
  run_assert "annotations-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"no annotations specified"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# scheme-enforced
# ═══════════════════════════════════════════════════════════════════════

@test "scheme-enforced: PASS (allow-http) when http port is present" {
  local s="$TEST_TMPDIR/scheme-allow-pass.yaml"
  cat > "$s" <<'EOF'
id: scheme-allow-pass
name: scheme-enforced allow-http PASS
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheme-enforced
    namespace: sample
    source: rendered
    scheme: allow-http
EOF
  run_assert "scheme-enforced.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "scheme-enforced: FAIL (https-only) when chart has http port 80" {
  local s="$TEST_TMPDIR/scheme-https-fail.yaml"
  cat > "$s" <<'EOF'
id: scheme-https-fail
name: scheme-enforced https-only FAIL
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheme-enforced
    namespace: sample
    source: rendered
    scheme: https-only
EOF
  # Default chart has Service port 80 + containerPort 80 → should FAIL
  run_assert "scheme-enforced.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"HTTP"* ]]
}

@test "scheme-enforced: FAIL (https-only) even with TLS — chart still has http port" {
  local s="$TEST_TMPDIR/scheme-https-tls.yaml"
  cat > "$s" <<'EOF'
id: scheme-https-tls
name: scheme https-only test with TLS
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
  set:
    tls.enabled: true
    tls.secretName: test-tls
asserts:
  - type: scheme-enforced
    namespace: sample
    source: rendered
    scheme: https-only
EOF
  # Even with TLS, the chart still exposes port 80 → should FAIL
  run_assert "scheme-enforced.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"HTTP"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# rbac-objects
# ═══════════════════════════════════════════════════════════════════════

@test "rbac-objects: PASS (expect_present=false) when no RBAC objects in rendered output" {
  local s="$TEST_TMPDIR/rbac-absent-pass.yaml"
  cat > "$s" <<'EOF'
id: rbac-absent-pass
name: rbac-objects expect absent PASS
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: rbac-objects
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "rbac-objects.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "rbac-objects: FAIL (expect_present=true) when no RBAC objects in rendered output" {
  local s="$TEST_TMPDIR/rbac-present-fail.yaml"
  cat > "$s" <<'EOF'
id: rbac-present-fail
name: rbac-objects expect present FAIL
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: rbac-objects
    namespace: sample
    source: rendered
    expect_present: true
EOF
  # Sample chart doesn't produce RBAC objects
  run_assert "rbac-objects.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "rbac-objects: FAIL with invalid expect_present value" {
  local s="$TEST_TMPDIR/rbac-invalid.yaml"
  cat > "$s" <<'EOF'
id: rbac-invalid
name: rbac-objects invalid value
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: rbac-objects
    namespace: sample
    source: rendered
    expect_present: maybe
EOF
  run_assert "rbac-objects.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# Schema validation
# ═══════════════════════════════════════════════════════════════════════

@test "schema validates labels-present assertion" {
  local s="$TEST_TMPDIR/schema-lbl.yaml"
  cat > "$s" <<'EOF'
id: schema-lbl
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: labels-present
    namespace: sample
    labels:
      foo: bar
EOF
  check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
}

@test "schema validates annotations-present assertion" {
  local s="$TEST_TMPDIR/schema-ann.yaml"
  cat > "$s" <<'EOF'
id: schema-ann
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: annotations-present
    namespace: sample
    annotations:
      foo: bar
EOF
  check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
}

@test "schema validates scheme-enforced assertion" {
  local s="$TEST_TMPDIR/schema-scheme.yaml"
  cat > "$s" <<'EOF'
id: schema-scheme
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheme-enforced
    namespace: sample
    scheme: https-only
EOF
  check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
}

@test "schema validates rbac-objects assertion" {
  local s="$TEST_TMPDIR/schema-rbac.yaml"
  cat > "$s" <<'EOF'
id: schema-rbac
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: rbac-objects
    namespace: sample
    expect_present: true
EOF
  check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
}

@test "schema rejects unknown assertion type" {
  local s="$TEST_TMPDIR/schema-bad-type.yaml"
  cat > "$s" <<'EOF'
id: schema-bad-type
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: unknown-type
    namespace: sample
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

@test "schema rejects labels-present without required namespace" {
  local s="$TEST_TMPDIR/schema-no-lbl-ns.yaml"
  cat > "$s" <<'EOF'
id: schema-no-lbl-ns
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: labels-present
    labels:
      foo: bar
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

@test "schema rejects scheme-enforced without required scheme" {
  local s="$TEST_TMPDIR/schema-no-scheme.yaml"
  cat > "$s" <<'EOF'
id: schema-no-scheme
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheme-enforced
    namespace: sample
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

@test "schema rejects rbac-objects without expect_present" {
  local s="$TEST_TMPDIR/schema-no-expect.yaml"
  cat > "$s" <<'EOF'
id: schema-no-expect
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: rbac-objects
    namespace: sample
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# Runner executability
# ═══════════════════════════════════════════════════════════════════════

@test "labels-present.sh is executable" {
  [ -x "$ASSERTS_DIR/labels-present.sh" ]
}

@test "annotations-present.sh is executable" {
  [ -x "$ASSERTS_DIR/annotations-present.sh" ]
}

@test "scheme-enforced.sh is executable" {
  [ -x "$ASSERTS_DIR/scheme-enforced.sh" ]
}

@test "rbac-objects.sh is executable" {
  [ -x "$ASSERTS_DIR/rbac-objects.sh" ]
}

# ═══════════════════════════════════════════════════════════════════════
# Return format {status, detail}
# ═══════════════════════════════════════════════════════════════════════

@test "labels-present.sh returns PASS with detail" {
  local s="$TEST_TMPDIR/fmt-lbl-pass.yaml"
  cat > "$s" <<'EOF'
id: fmt-lbl-pass
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: labels-present
    namespace: sample
    source: rendered
    labels:
      app.kubernetes.io/instance: test-release
    kinds:
      - Deployment
EOF
  run_assert "labels-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  [[ "$output" == *"labels"* ]]
}

@test "labels-present.sh returns FAIL with detail" {
  local s="$TEST_TMPDIR/fmt-lbl-fail.yaml"
  cat > "$s" <<'EOF'
id: fmt-lbl-fail
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: labels-present
    namespace: sample
    source: rendered
    labels:
      missing-label: missing-value
    kinds:
      - Deployment
EOF
  run_assert "labels-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]]
}

@test "rbac-objects.sh returns PASS with detail (expect_present=false)" {
  local s="$TEST_TMPDIR/fmt-rbac-pass.yaml"
  cat > "$s" <<'EOF'
id: fmt-rbac-pass
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: rbac-objects
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "rbac-objects.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "rbac-objects.sh returns FAIL with detail (expect_present=true, no RBAC)" {
  local s="$TEST_TMPDIR/fmt-rbac-fail.yaml"
  cat > "$s" <<'EOF'
id: fmt-rbac-fail
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: rbac-objects
    namespace: sample
    source: rendered
    expect_present: true
EOF
  run_assert "rbac-objects.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"0"* ]] || [[ "$output" == *"expected"* ]]
}

@test "annotations-present.sh returns PASS with detail" {
  local s="$TEST_TMPDIR/fmt-ann-pass.yaml"
  cat > "$s" <<'EOF'
id: fmt-ann-pass
name: mesh annotation test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
  set:
    mesh.inject: true
asserts:
  - type: annotations-present
    namespace: sample
    source: rendered
    annotations:
      sidecar.istio.io/inject: "true"
    kinds:
      - Deployment
EOF
  run_assert "annotations-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  [[ "$output" == *"annotations"* ]]
}

@test "scheme-enforced.sh returns PASS with detail (allow-http)" {
  local s="$TEST_TMPDIR/fmt-scheme-pass.yaml"
  cat > "$s" <<'EOF'
id: fmt-scheme-pass
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheme-enforced
    namespace: sample
    source: rendered
    scheme: allow-http
EOF
  run_assert "scheme-enforced.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}
