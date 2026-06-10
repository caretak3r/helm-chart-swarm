#!/usr/bin/env bats
# config-asserts-b.bats — Tests for the 4 new config assertion types:
# init-containers, host-network, lifecycle-hooks, dns-config.
# Covers PASS and FAIL paths for each runner using rendered (helm template) source.
# Also covers expect_present=true/false variants and invalid expect_present.
#
# NOTE: The sample-product-chart renders a Deployment WITHOUT initContainers,
# hostNetwork, lifecycle hooks, or dnsConfig.
# Tests reflect these actual chart facts.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
ASSERTS_DIR="$REPO_ROOT/engine/asserts"
SCHEMA_FILE="$REPO_ROOT/engine/templates/scenario.schema.json"
PROJECT_DIR="$REPO_ROOT/examples/sample-product-chart"

# Per-test temp dir
setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/config-asserts-b-bats-XXXXXX)"
}
teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/config-asserts-b-dummy}" 2>/dev/null || true
}

# Helper: run a capability assert runner with PROJECT_DIR set.
run_assert() {
  local runner="$1"
  local scenario="$2"
  local idx="${3:-0}"
  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/$runner" "$scenario" "$idx"
}

# ═══════════════════════════════════════════════════════════════════════
# init-containers
# ═══════════════════════════════════════════════════════════════════════

@test "init-containers: FAIL when expect_present=true but chart has no initContainers" {
  local s="$TEST_TMPDIR/initcontainers-fail-missing.yaml"
  cat > "$s" <<'EOF'
id: initcontainers-fail-missing
name: init-containers FAIL no initContainers
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: init-containers
    namespace: sample
    source: rendered
    expect_present: true
EOF
  run_assert "init-containers.sh" "$s"
  # Chart has no initContainers -> expect FAIL
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]] || [[ "$output" == *"no initContainers"* ]]
}

@test "init-containers: PASS when expect_present=false and chart has no initContainers" {
  local s="$TEST_TMPDIR/initcontainers-off-pass.yaml"
  cat > "$s" <<'EOF'
id: initcontainers-off-pass
name: init-containers off case PASS
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: init-containers
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "init-containers.sh" "$s"
  # Chart has no initContainers -> PASS
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "init-containers: FAIL when expect_present=true with named init container that is absent (knob)" {
  local s="$TEST_TMPDIR/initcontainers-fail-named.yaml"
  cat > "$s" <<'EOF'
id: initcontainers-fail-named
name: init-containers FAIL named init container absent
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: init-containers
    namespace: sample
    source: rendered
    expect_present: true
    names:
      - init-db
      - init-migrate
EOF
  run_assert "init-containers.sh" "$s"
  # Chart has no initContainers at all -> expect FAIL
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]] || [[ "$output" == *"no initContainers"* ]]
}

@test "init-containers: FAIL on invalid expect_present value" {
  local s="$TEST_TMPDIR/initcontainers-invalid-ep.yaml"
  cat > "$s" <<'EOF'
id: initcontainers-invalid-ep
name: init-containers invalid expect_present
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: init-containers
    namespace: sample
    source: rendered
    expect_present: "yes"
EOF
  run_assert "init-containers.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"expect_present must be 'true' or 'false'"* ]]
}

@test "init-containers: schema validates valid scenario" {
  local s="$TEST_TMPDIR/initcontainers-schema-valid.yaml"
  cat > "$s" <<'EOF'
id: initcontainers-schema-valid
name: init-containers schema valid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: init-containers
    namespace: sample
    expect_present: true
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

@test "init-containers: schema rejects missing expect_present" {
  local s="$TEST_TMPDIR/initcontainers-schema-no-ep.yaml"
  cat > "$s" <<'EOF'
id: initcontainers-schema-no-ep
name: init-containers schema no expect_present
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: init-containers
    namespace: sample
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# host-network
# ═══════════════════════════════════════════════════════════════════════

@test "host-network: FAIL when expect_present=true but hostNetwork absent" {
  local s="$TEST_TMPDIR/hostnet-fail-missing.yaml"
  cat > "$s" <<'EOF'
id: hostnet-fail-missing
name: host-network FAIL hostNetwork absent
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: host-network
    namespace: sample
    source: rendered
    expect_present: true
EOF
  run_assert "host-network.sh" "$s"
  # Chart has no hostNetwork -> expect FAIL
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]] || [[ "$output" == *"hostNetwork"* ]]
}

@test "host-network: PASS when expect_present=false and hostNetwork absent" {
  local s="$TEST_TMPDIR/hostnet-off-pass.yaml"
  cat > "$s" <<'EOF'
id: hostnet-off-pass
name: host-network off case PASS
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: host-network
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "host-network.sh" "$s"
  # Chart has no hostNetwork -> PASS
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "host-network: FAIL when check_host_port=true and expect_present=true but absent" {
  local s="$TEST_TMPDIR/hostnet-fail-hostport.yaml"
  cat > "$s" <<'EOF'
id: hostnet-fail-hostport
name: host-network FAIL hostPort absent
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: host-network
    namespace: sample
    source: rendered
    expect_present: true
    check_host_port: true
EOF
  run_assert "host-network.sh" "$s"
  # Chart has neither hostNetwork nor hostPort -> expect FAIL
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]] || [[ "$output" == *"hostNetwork"* ]]
}

@test "host-network: FAIL on invalid expect_present value" {
  local s="$TEST_TMPDIR/hostnet-invalid-ep.yaml"
  cat > "$s" <<'EOF'
id: hostnet-invalid-ep
name: host-network invalid expect_present
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: host-network
    namespace: sample
    source: rendered
    expect_present: "yes"
EOF
  run_assert "host-network.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"expect_present must be 'true' or 'false'"* ]]
}

@test "host-network: schema validates valid scenario" {
  local s="$TEST_TMPDIR/hostnet-schema-valid.yaml"
  cat > "$s" <<'EOF'
id: hostnet-schema-valid
name: host-network schema valid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: host-network
    namespace: sample
    expect_present: true
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

@test "host-network: schema rejects missing expect_present" {
  local s="$TEST_TMPDIR/hostnet-schema-no-ep.yaml"
  cat > "$s" <<'EOF'
id: hostnet-schema-no-ep
name: host-network schema no expect_present
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: host-network
    namespace: sample
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# lifecycle-hooks
# ═══════════════════════════════════════════════════════════════════════

@test "lifecycle-hooks: FAIL when expect_present=true but no lifecycle hooks present" {
  local s="$TEST_TMPDIR/lifecycle-fail-missing.yaml"
  cat > "$s" <<'EOF'
id: lifecycle-fail-missing
name: lifecycle-hooks FAIL no lifecycle hooks
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: lifecycle-hooks
    namespace: sample
    source: rendered
    expect_present: true
EOF
  run_assert "lifecycle-hooks.sh" "$s"
  # Chart has no lifecycle hooks -> expect FAIL
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]] || [[ "$output" == *"lifecycle"* ]]
}

@test "lifecycle-hooks: PASS when expect_present=false and no lifecycle hooks" {
  local s="$TEST_TMPDIR/lifecycle-off-pass.yaml"
  cat > "$s" <<'EOF'
id: lifecycle-off-pass
name: lifecycle-hooks off case PASS
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: lifecycle-hooks
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "lifecycle-hooks.sh" "$s"
  # Chart has no lifecycle hooks -> PASS
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "lifecycle-hooks: FAIL when expect_present=true and check_preStop=true but absent (knob)" {
  local s="$TEST_TMPDIR/lifecycle-fail-prestop.yaml"
  cat > "$s" <<'EOF'
id: lifecycle-fail-prestop
name: lifecycle-hooks FAIL preStop absent
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: lifecycle-hooks
    namespace: sample
    source: rendered
    expect_present: true
    check_postStart: false
    check_preStop: true
EOF
  run_assert "lifecycle-hooks.sh" "$s"
  # Chart has no lifecycle hooks -> expect FAIL with preStop specific
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]]
}

@test "lifecycle-hooks: FAIL on invalid expect_present value" {
  local s="$TEST_TMPDIR/lifecycle-invalid-ep.yaml"
  cat > "$s" <<'EOF'
id: lifecycle-invalid-ep
name: lifecycle-hooks invalid expect_present
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: lifecycle-hooks
    namespace: sample
    source: rendered
    expect_present: "yes"
EOF
  run_assert "lifecycle-hooks.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"expect_present must be 'true' or 'false'"* ]]
}

@test "lifecycle-hooks: schema validates valid scenario" {
  local s="$TEST_TMPDIR/lifecycle-schema-valid.yaml"
  cat > "$s" <<'EOF'
id: lifecycle-schema-valid
name: lifecycle-hooks schema valid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: lifecycle-hooks
    namespace: sample
    expect_present: true
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

@test "lifecycle-hooks: schema rejects missing expect_present" {
  local s="$TEST_TMPDIR/lifecycle-schema-no-ep.yaml"
  cat > "$s" <<'EOF'
id: lifecycle-schema-no-ep
name: lifecycle-hooks schema no expect_present
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: lifecycle-hooks
    namespace: sample
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# dns-config
# ═══════════════════════════════════════════════════════════════════════

@test "dns-config: FAIL when expect_present=true but no dnsConfig/dnsPolicy rendered" {
  local s="$TEST_TMPDIR/dns-fail-missing.yaml"
  cat > "$s" <<'EOF'
id: dns-fail-missing
name: dns-config FAIL no DNS config
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: dns-config
    namespace: sample
    source: rendered
    expect_present: true
EOF
  run_assert "dns-config.sh" "$s"
  # Chart has no dnsConfig -> expect FAIL
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]] || [[ "$output" == *"dns"* ]]
}

@test "dns-config: PASS when expect_present=false and no dnsConfig" {
  local s="$TEST_TMPDIR/dns-off-pass.yaml"
  cat > "$s" <<'EOF'
id: dns-off-pass
name: dns-config off case PASS
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: dns-config
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "dns-config.sh" "$s"
  # Chart has no dnsConfig -> PASS
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "dns-config: FAIL when expect_present=true with dns_policy knob but absent" {
  local s="$TEST_TMPDIR/dns-fail-policy.yaml"
  cat > "$s" <<'EOF'
id: dns-fail-policy
name: dns-config FAIL dnsPolicy absent
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: dns-config
    namespace: sample
    source: rendered
    expect_present: true
    dns_policy: "None"
EOF
  run_assert "dns-config.sh" "$s"
  # Chart has no dnsPolicy set -> expect FAIL
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]] || [[ "$output" == *"dnsPolicy"* ]]
}

@test "dns-config: FAIL when expect_present=true with nameservers knob but absent" {
  local s="$TEST_TMPDIR/dns-fail-nameservers.yaml"
  cat > "$s" <<'EOF'
id: dns-fail-nameservers
name: dns-config FAIL nameservers absent
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: dns-config
    namespace: sample
    source: rendered
    expect_present: true
    nameservers:
      - 8.8.8.8
EOF
  run_assert "dns-config.sh" "$s"
  # Chart has no dnsConfig -> expect FAIL
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"missing"* ]] || [[ "$output" == *"dnsConfig"* ]]
}

@test "dns-config: FAIL on invalid expect_present value" {
  local s="$TEST_TMPDIR/dns-invalid-ep.yaml"
  cat > "$s" <<'EOF'
id: dns-invalid-ep
name: dns-config invalid expect_present
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: dns-config
    namespace: sample
    source: rendered
    expect_present: "yes"
EOF
  run_assert "dns-config.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"expect_present must be 'true' or 'false'"* ]]
}

@test "dns-config: schema validates valid scenario" {
  local s="$TEST_TMPDIR/dns-schema-valid.yaml"
  cat > "$s" <<'EOF'
id: dns-schema-valid
name: dns-config schema valid
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: dns-config
    namespace: sample
    expect_present: true
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -eq 0 ]
}

@test "dns-config: schema rejects missing expect_present" {
  local s="$TEST_TMPDIR/dns-schema-no-ep.yaml"
  cat > "$s" <<'EOF'
id: dns-schema-no-ep
name: dns-config schema no expect_present
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: dns-config
    namespace: sample
    source: rendered
EOF
  run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
  [ $status -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# Cross-cutting: invalid expect_present for all 4 types
# ═══════════════════════════════════════════════════════════════════════

@test "config-asserts-b: all 4 types reject invalid expect_present" {
  for assert_type in init-containers host-network lifecycle-hooks dns-config; do
    local s="$TEST_TMPDIR/${assert_type}-invalid.yaml"
    cat > "$s" <<EOF
id: ${assert_type}-invalid
name: ${assert_type} invalid expect_present
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: ${assert_type}
    namespace: sample
    source: rendered
    expect_present: "yes"
EOF
    run_assert "${assert_type}.sh" "$s"
    [ $status -ne 0 ] || { echo "FAIL: $assert_type did not reject invalid expect_present"; false; }
    [[ "$output" == *"expect_present must be 'true' or 'false'"* ]] || { echo "FAIL: $assert_type missing config error message"; false; }
  done
}

# ═══════════════════════════════════════════════════════════════════════
# Cross-cutting: no workload objects -> FAIL for all 4 types
# ═══════════════════════════════════════════════════════════════════════

@test "config-asserts-b: all 4 types FAIL when no workload objects found" {
  for assert_type in init-containers host-network lifecycle-hooks dns-config; do
    # Use a chart path that produces no workloads to trigger "no workload objects"
    local empty_dir="$TEST_TMPDIR/empty-chart"
    mkdir -p "$empty_dir/templates"
    echo "" > "$empty_dir/templates/empty.yaml"
    local s="$TEST_TMPDIR/${assert_type}-empty.yaml"
    cat > "$s" <<EOF
id: ${assert_type}-empty
name: ${assert_type} no workloads
cluster:
  provider: kind
product:
  chart: $empty_dir
  release: test-release
  namespace: sample
asserts:
  - type: ${assert_type}
    namespace: sample
    source: rendered
    expect_present: true
EOF
    run_assert "${assert_type}.sh" "$s"
    [ $status -ne 0 ] || { echo "FAIL: $assert_type did not fail when no workloads found"; false; }
    [[ "$output" == *"no workload objects"* ]] || { echo "FAIL: $assert_type missing 'no workload objects' message"; false; }
  done
}

# ═══════════════════════════════════════════════════════════════════════
# Schema validation: all 4 types have enum+oneOf
# ═══════════════════════════════════════════════════════════════════════

@test "config-asserts-b: all 4 types validate via check-jsonschema" {
  for assert_type in init-containers host-network lifecycle-hooks dns-config; do
    local s="$TEST_TMPDIR/${assert_type}-valid.yaml"
    cat > "$s" <<EOF
id: ${assert_type}-valid
name: ${assert_type} valid scenario
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: ${assert_type}
    namespace: sample
    expect_present: true
    source: rendered
EOF
    run check-jsonschema --schemafile "$SCHEMA_FILE" "$s"
    [ $status -eq 0 ] || { echo "FAIL: $assert_type scenario did not validate"; false; }
  done
}
