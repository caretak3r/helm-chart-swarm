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
      cost-center: astro
    kinds:
      - Service
EOF
  # extraLabels is empty by default, so the Service lacks cost-center and this should FAIL
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

@test "schema allows unknown assertion type (consumer-custom passthrough)" {
  local s="$TEST_TMPDIR/schema-custom-type.yaml"
  cat > "$s" <<'EOF'
id: schema-custom-type
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
  # Unknown types validate via the consumer-custom catch-all branch;
  # undeclared types are rejected later by registry/depth enforcement in sweep.
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
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

# ═══════════════════════════════════════════════════════════════════════
# rbac-objects: default ServiceAccount exclusion
# ═══════════════════════════════════════════════════════════════════════

@test "rbac-objects: rendered PASS excludes auto-created default SA correctly" {
  # The rendered check never sees the k8s-auto-created 'default' SA,
  # so expect_present=false should PASS on rendered source alone.
  local s="$TEST_TMPDIR/rbac-default-sa.yaml"
  cat > "$s" <<'EOF'
id: rbac-default-sa
name: rbac default SA exclusion
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

# ═══════════════════════════════════════════════════════════════════════
# scheme-enforced: FAIL with invalid scheme value
# ═══════════════════════════════════════════════════════════════════════

@test "scheme-enforced: FAIL with invalid scheme value" {
  local s="$TEST_TMPDIR/scheme-invalid.yaml"
  cat > "$s" <<'EOF'
id: scheme-invalid
name: scheme-enforced invalid value
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
    scheme: maybe-ftp
EOF
  run_assert "scheme-enforced.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# labels-present: PASS on pod template labels for workload kinds
# ═══════════════════════════════════════════════════════════════════════

@test "labels-present: PASS for compliance label on pod template" {
  local s="$TEST_TMPDIR/lbl-pod-tpl.yaml"
  cat > "$s" <<'EOF'
id: lbl-pod-tpl
name: labels-present pod template test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
  set:
    policy.complianceLabels.pci-compliance: "true"
asserts:
  - type: labels-present
    namespace: sample
    source: rendered
    labels:
      pci-compliance: "true"
    kinds:
      - Deployment
EOF
  run_assert "labels-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# annotations-present: FAIL when annotation present on wrong kind
# ═══════════════════════════════════════════════════════════════════════

@test "annotations-present: FAIL when checking annotation on Service (no annotations)" {
  local s="$TEST_TMPDIR/ann-fail-svc.yaml"
  cat > "$s" <<'EOF'
id: ann-fail-svc
name: annotations-present FAIL on Service
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
      sidecar.istio.io/inject: "true"
    kinds:
      - Service
EOF
  # Service template has no annotations
  run_assert "annotations-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# security-context
# ═══════════════════════════════════════════════════════════════════════

@test "security-context: PASS (expect_present=false) when no securityContext in rendered output" {
  local s="$TEST_TMPDIR/secctx-off-pass.yaml"
  cat > "$s" <<'EOF'
id: secctx-off-pass
name: security-context OFF PASS
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: security-context
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "security-context.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "security-context: FAIL (expect_present=true) when rendered output lacks securityContext" {
  local s="$TEST_TMPDIR/secctx-on-fail.yaml"
  cat > "$s" <<'EOF'
id: secctx-on-fail
name: security-context ON FAIL
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: security-context
    namespace: sample
    source: rendered
    expect_present: true
    podSecurityContext:
      runAsNonRoot: true
    containerSecurityContext:
      readOnlyRootFilesystem: true
EOF
  # securityContext values are unset by default, so rendered output lacks them
  run_assert "security-context.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]]
}

@test "security-context: FAIL with invalid expect_present value" {
  local s="$TEST_TMPDIR/secctx-invalid.yaml"
  cat > "$s" <<'EOF'
id: secctx-invalid
name: security-context invalid expect
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: security-context
    namespace: sample
    source: rendered
    expect_present: maybe
EOF
  run_assert "security-context.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"expect_present"* ]]
}

@test "security-context: schema validates security-context assertion" {
  local s="$TEST_TMPDIR/secctx-schema.yaml"
  cat > "$s" <<'EOF'
id: secctx-schema
name: security-context schema valid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: security-context
    namespace: sample
    source: rendered
    expect_present: true
    podSecurityContext:
      runAsNonRoot: true
    containerSecurityContext:
      readOnlyRootFilesystem: true
EOF
  yq -o=json "$s" | jsonschema -i /dev/stdin "$SCHEMA_FILE"
}

@test "security-context: schema rejects security-context without expect_present" {
  local s="$TEST_TMPDIR/secctx-schema-noexpect.yaml"
  cat > "$s" <<'EOF'
id: secctx-schema-noexpect
name: security-context schema missing expect
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: security-context
    namespace: sample
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

@test "security-context.sh is executable" {
  [ -x "$ASSERTS_DIR/security-context.sh" ]
}

@test "security-context: PASS with dotted-key podSecurityContext (seccompProfile.type)" {
  # Regression: yq path expressions for dotted keys (e.g. seccompProfile.type) require
  # a leading dot after a pipe — without it, yq v4 emits a lexer error and the value
  # silently appears as __ABSENT__.  This test proves the fix.
  local s="$TEST_TMPDIR/secctx-dotted-pod.yaml"
  cat > "$s" <<'EOF'
id: secctx-dotted-pod
name: security-context dotted pod key PASS
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
  values: chart-test/fixtures/capability/security-context-on-values.yaml
asserts:
  - type: security-context
    namespace: sample
    source: rendered
    expect_present: true
    podSecurityContext:
      seccompProfile.type: RuntimeDefault
EOF
  run_assert "security-context.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "security-context: PASS with dotted-key containerSecurityContext (capabilities.drop)" {
  # Regression: same yq leading-dot fix for container-level dotted keys.
  local s="$TEST_TMPDIR/secctx-dotted-ctr.yaml"
  cat > "$s" <<'EOF'
id: secctx-dotted-ctr
name: security-context dotted container key PASS
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
  values: chart-test/fixtures/capability/security-context-on-values.yaml
asserts:
  - type: security-context
    namespace: sample
    source: rendered
    expect_present: true
    containerSecurityContext:
      capabilities.drop: ALL
EOF
  run_assert "security-context.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# network-policy
# ═══════════════════════════════════════════════════════════════════════

@test "network-policy: PASS (expect_present=false) when no NetworkPolicy in rendered output" {
  local s="$TEST_TMPDIR/netpol-off-pass.yaml"
  cat > "$s" <<'EOF'
id: netpol-off-pass
name: network-policy OFF PASS
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
  set:
    networkPolicy.enabled: false
asserts:
  - type: network-policy
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "network-policy.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "network-policy: FAIL (expect_present=true) when rendered output lacks NetworkPolicy" {
  local s="$TEST_TMPDIR/netpol-on-fail.yaml"
  cat > "$s" <<'EOF'
id: netpol-on-fail
name: network-policy ON FAIL
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: network-policy
    namespace: sample
    source: rendered
    expect_present: true
EOF
  # networkPolicy.enabled defaults to false, so no NetworkPolicy is rendered
  run_assert "network-policy.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"expected NetworkPolicy"* ]]
}

@test "network-policy: FAIL with invalid expect_present value" {
  local s="$TEST_TMPDIR/netpol-invalid.yaml"
  cat > "$s" <<'EOF'
id: netpol-invalid
name: network-policy invalid expect
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: network-policy
    namespace: sample
    source: rendered
    expect_present: maybe
EOF
  run_assert "network-policy.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"expect_present"* ]]
}

@test "network-policy: schema validates network-policy assertion" {
  local s="$TEST_TMPDIR/netpol-schema.yaml"
  cat > "$s" <<'EOF'
id: netpol-schema
name: network-policy schema valid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: network-policy
    namespace: sample
    source: rendered
    expect_present: true
EOF
  yq -o=json "$s" | jsonschema -i /dev/stdin "$SCHEMA_FILE"
}

@test "network-policy: schema rejects network-policy without expect_present" {
  local s="$TEST_TMPDIR/netpol-schema-noexpect.yaml"
  cat > "$s" <<'EOF'
id: netpol-schema-noexpect
name: network-policy schema missing expect
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: network-policy
    namespace: sample
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

@test "network-policy.sh is executable" {
  [ -x "$ASSERTS_DIR/network-policy.sh" ]
}

# ═══════════════════════════════════════════════════════════════════════
# resources-present
# ═══════════════════════════════════════════════════════════════════════

@test "resources-present: FAIL (expect_present=true) when rendered output lacks resources on skywatcher" {
  local s="$TEST_TMPDIR/res-fail.yaml"
  cat > "$s" <<'EOF'
id: res-fail
name: resources-present FAIL test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: resources-present
    namespace: sample
    source: rendered
    expect_present: true
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
EOF
  run_assert "resources-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"missing resources"* ]]
}

@test "resources-present: PASS (expect_present=false) when no resources block in rendered output" {
  local s="$TEST_TMPDIR/res-pass-off.yaml"
  cat > "$s" <<'EOF'
id: res-pass-off
name: resources-present PASS off-case
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: resources-present
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "resources-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "resources-present: FAIL with invalid expect_present value" {
  local s="$TEST_TMPDIR/res-invalid.yaml"
  cat > "$s" <<'EOF'
id: res-invalid
name: resources-present invalid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: resources-present
    namespace: sample
    source: rendered
    expect_present: maybe
EOF
  run_assert "resources-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"expect_present must be"* ]]
}

@test "resources-present: schema validates resources-present assertion" {
  local s="$TEST_TMPDIR/res-schema-valid.yaml"
  cat > "$s" <<'EOF'
id: res-schema-valid
name: resources-present schema valid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: resources-present
    namespace: sample
    source: rendered
    expect_present: true
    requests:
      cpu: 100m
    limits:
      cpu: 500m
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

@test "resources-present: schema rejects resources-present without expect_present" {
  local s="$TEST_TMPDIR/res-schema-noexpect.yaml"
  cat > "$s" <<'EOF'
id: res-schema-noexpect
name: resources-present schema missing expect
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: resources-present
    namespace: sample
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

@test "resources-present.sh is executable" {
  [ -x "$ASSERTS_DIR/resources-present.sh" ]
}

# ═══════════════════════════════════════════════════════════════════════
# imagepullsecrets-present
# ═══════════════════════════════════════════════════════════════════════

@test "imagepullsecrets-present: FAIL (expect_present=true) when rendered output lacks imagePullSecrets" {
  local s="$TEST_TMPDIR/ips-fail.yaml"
  cat > "$s" <<'EOF'
id: ips-fail
name: imagepullsecrets-present FAIL test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: imagepullsecrets-present
    namespace: sample
    source: rendered
    expect_present: true
    secret_names:
      - regcred
    check_service_account: true
EOF
  run_assert "imagepullsecrets-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "imagepullsecrets-present: PASS (expect_present=false) when no imagePullSecrets in rendered output" {
  local s="$TEST_TMPDIR/ips-pass-off.yaml"
  cat > "$s" <<'EOF'
id: ips-pass-off
name: imagepullsecrets-present PASS off-case
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: imagepullsecrets-present
    namespace: sample
    source: rendered
    expect_present: false
    check_service_account: true
EOF
  run_assert "imagepullsecrets-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "imagepullsecrets-present: FAIL with invalid expect_present value" {
  local s="$TEST_TMPDIR/ips-invalid.yaml"
  cat > "$s" <<'EOF'
id: ips-invalid
name: imagepullsecrets-present invalid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: imagepullsecrets-present
    namespace: sample
    source: rendered
    expect_present: maybe
EOF
  run_assert "imagepullsecrets-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"expect_present must be"* ]]
}

@test "imagepullsecrets-present: schema validates imagepullsecrets-present assertion" {
  local s="$TEST_TMPDIR/ips-schema-valid.yaml"
  cat > "$s" <<'EOF'
id: ips-schema-valid
name: imagepullsecrets-present schema valid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: imagepullsecrets-present
    namespace: sample
    source: rendered
    expect_present: true
    secret_names:
      - regcred
    check_service_account: true
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

@test "imagepullsecrets-present: schema rejects imagepullsecrets-present without expect_present" {
  local s="$TEST_TMPDIR/ips-schema-noexpect.yaml"
  cat > "$s" <<'EOF'
id: ips-schema-noexpect
name: imagepullsecrets-present schema missing expect
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: imagepullsecrets-present
    namespace: sample
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

@test "imagepullsecrets-present.sh is executable" {
  [ -x "$ASSERTS_DIR/imagepullsecrets-present.sh" ]
}

# ═══════════════════════════════════════════════════════════════════════
# serviceaccount-annotations
# ═══════════════════════════════════════════════════════════════════════

@test "serviceaccount-annotations: FAIL (expect_present=true) when chart lacks ServiceAccount" {
  local s="$TEST_TMPDIR/saann-fail.yaml"
  cat > "$s" <<'EOF'
id: saann-fail
name: serviceaccount-annotations FAIL test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
  set:
    serviceAccount.create: true
    serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn: arn:aws:iam::123456789012:role/demo
asserts:
  - type: serviceaccount-annotations
    namespace: sample
    source: rendered
    expect_present: true
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/demo
EOF
  run_assert "serviceaccount-annotations.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"ServiceAccount"* ]]
}

@test "serviceaccount-annotations: PASS (expect_present=false) when no ServiceAccount rendered" {
  local s="$TEST_TMPDIR/saann-pass-off.yaml"
  cat > "$s" <<'EOF'
id: saann-pass-off
name: serviceaccount-annotations PASS off-case
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: serviceaccount-annotations
    namespace: sample
    source: rendered
    expect_present: false
    identity_keys:
      - eks.amazonaws.com/role-arn
      - azure.workload.identity/client-id
      - iam.gke.io/gcp-service-account
EOF
  run_assert "serviceaccount-annotations.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "serviceaccount-annotations: FAIL with invalid expect_present value" {
  local s="$TEST_TMPDIR/saann-invalid.yaml"
  cat > "$s" <<'EOF'
id: saann-invalid
name: serviceaccount-annotations invalid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: serviceaccount-annotations
    namespace: sample
    source: rendered
    expect_present: maybe
EOF
  run_assert "serviceaccount-annotations.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"expect_present must be"* ]]
}

@test "serviceaccount-annotations: schema validates serviceaccount-annotations assertion" {
  local s="$TEST_TMPDIR/saann-schema-valid.yaml"
  cat > "$s" <<'EOF'
id: saann-schema-valid
name: serviceaccount-annotations schema valid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: serviceaccount-annotations
    namespace: sample
    source: rendered
    expect_present: true
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/demo
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

@test "serviceaccount-annotations: schema rejects serviceaccount-annotations without expect_present" {
  local s="$TEST_TMPDIR/saann-schema-noexpect.yaml"
  cat > "$s" <<'EOF'
id: saann-schema-noexpect
name: serviceaccount-annotations schema missing expect
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: serviceaccount-annotations
    namespace: sample
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

@test "serviceaccount-annotations.sh is executable" {
  [ -x "$ASSERTS_DIR/serviceaccount-annotations.sh" ]
}

# ═══════════════════════════════════════════════════════════════════════
# scheduling-present
# ═══════════════════════════════════════════════════════════════════════

@test "scheduling-present: FAIL (expect_present=true) when rendered output lacks nodeSelector" {
  local s="$TEST_TMPDIR/sched-ns-on.yaml"
  cat > "$s" <<'EOF'
id: sched-ns-on
name: scheduling-present nodeSelector ON
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheduling-present
    namespace: sample
    source: rendered
    expect_present: true
    check_nodeSelector: true
    check_tolerations: false
    check_affinity: false
    check_topologySpreadConstraints: false
    nodeSelector:
      disktype: ssd
EOF
  run_assert "scheduling-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"missing nodeSelector"* ]]
}

@test "scheduling-present: PASS (expect_present=false) when no scheduling fields in rendered output" {
  local s="$TEST_TMPDIR/sched-off.yaml"
  cat > "$s" <<'EOF'
id: sched-off
name: scheduling-present OFF
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheduling-present
    namespace: sample
    source: rendered
    expect_present: false
    check_nodeSelector: true
    check_tolerations: true
    check_affinity: true
    check_topologySpreadConstraints: true
EOF
  run_assert "scheduling-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "scheduling-present: FAIL (expect_present=true) when rendered output lacks tolerations" {
  local s="$TEST_TMPDIR/sched-tol-on.yaml"
  cat > "$s" <<'EOF'
id: sched-tol-on
name: scheduling-present tolerations ON
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheduling-present
    namespace: sample
    source: rendered
    expect_present: true
    check_nodeSelector: false
    check_tolerations: true
    check_affinity: false
    check_topologySpreadConstraints: false
    tolerations:
      - key: dedicated
        operator: Equal
        value: gpu
        effect: NoSchedule
EOF
  run_assert "scheduling-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"missing tolerations"* ]]
}

@test "scheduling-present: FAIL (expect_present=true) when rendered output lacks affinity" {
  local s="$TEST_TMPDIR/sched-aff-on.yaml"
  cat > "$s" <<'EOF'
id: sched-aff-on
name: scheduling-present affinity ON
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheduling-present
    namespace: sample
    source: rendered
    expect_present: true
    check_nodeSelector: false
    check_tolerations: false
    check_affinity: true
    check_topologySpreadConstraints: false
    affinity:
      nodeAffinity: true
EOF
  run_assert "scheduling-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"missing affinity"* ]]
}

@test "scheduling-present: FAIL (expect_present=true) when rendered output lacks topologySpreadConstraints" {
  local s="$TEST_TMPDIR/sched-tsc-on.yaml"
  cat > "$s" <<'EOF'
id: sched-tsc-on
name: scheduling-present topologySpreadConstraints ON
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheduling-present
    namespace: sample
    source: rendered
    expect_present: true
    check_nodeSelector: false
    check_tolerations: false
    check_affinity: false
    check_topologySpreadConstraints: true
    topologySpreadConstraints:
      - topologyKey: topology.kubernetes.io/zone
        maxSkew: 1
        whenUnsatisfiable: DoNotSchedule
EOF
  run_assert "scheduling-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"missing topologySpreadConstraints"* ]]
}

@test "scheduling-present: FAIL with invalid expect_present value" {
  local s="$TEST_TMPDIR/sched-invalid.yaml"
  cat > "$s" <<'EOF'
id: sched-invalid
name: scheduling-present invalid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheduling-present
    namespace: sample
    source: rendered
    expect_present: maybe
EOF
  run_assert "scheduling-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"expect_present must be"* ]]
}

@test "scheduling-present: schema validates scheduling-present assertion" {
  local s="$TEST_TMPDIR/sched-schema-valid.yaml"
  cat > "$s" <<'EOF'
id: sched-schema-valid
name: scheduling-present schema valid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheduling-present
    namespace: sample
    source: rendered
    expect_present: true
    nodeSelector:
      disktype: ssd
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

@test "scheduling-present: schema rejects scheduling-present without expect_present" {
  local s="$TEST_TMPDIR/sched-schema-noexpect.yaml"
  cat > "$s" <<'EOF'
id: sched-schema-noexpect
name: scheduling-present schema missing expect
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheduling-present
    namespace: sample
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

@test "scheduling-present.sh is executable" {
  [ -x "$ASSERTS_DIR/scheduling-present.sh" ]
}

# ═══════════════════════════════════════════════════════════════════════
# priority-class-present
# ═══════════════════════════════════════════════════════════════════════

@test "priority-class-present: FAIL (expect_present=true) when rendered output lacks priorityClassName" {
  local s="$TEST_TMPDIR/pc-on.yaml"
  cat > "$s" <<'EOF'
id: pc-on
name: priority-class-present ON
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: priority-class-present
    namespace: sample
    source: rendered
    expect_present: true
    priority_class_name: high-priority
EOF
  run_assert "priority-class-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"missing priorityClassName"* ]]
}

@test "priority-class-present: PASS (expect_present=false) when no priorityClassName in rendered output" {
  local s="$TEST_TMPDIR/pc-off.yaml"
  cat > "$s" <<'EOF'
id: pc-off
name: priority-class-present OFF
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: priority-class-present
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "priority-class-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "priority-class-present: FAIL with invalid expect_present value" {
  local s="$TEST_TMPDIR/pc-invalid.yaml"
  cat > "$s" <<'EOF'
id: pc-invalid
name: priority-class-present invalid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: priority-class-present
    namespace: sample
    source: rendered
    expect_present: maybe
EOF
  run_assert "priority-class-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"expect_present must be"* ]]
}

@test "priority-class-present: schema validates priority-class-present assertion" {
  local s="$TEST_TMPDIR/pc-schema-valid.yaml"
  cat > "$s" <<'EOF'
id: pc-schema-valid
name: priority-class-present schema valid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: priority-class-present
    namespace: sample
    source: rendered
    expect_present: true
    priority_class_name: high-priority
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

@test "priority-class-present: schema rejects priority-class-present without expect_present" {
  local s="$TEST_TMPDIR/pc-schema-noexpect.yaml"
  cat > "$s" <<'EOF'
id: pc-schema-noexpect
name: priority-class-present schema missing expect
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: priority-class-present
    namespace: sample
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

@test "priority-class-present.sh is executable" {
  [ -x "$ASSERTS_DIR/priority-class-present.sh" ]
}
