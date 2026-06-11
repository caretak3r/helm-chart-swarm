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

# ═══════════════════════════════════════════════════════════════════════
# Helper: create a minimal chart from inline template YAML
# ═══════════════════════════════════════════════════════════════════════

# Creates a chart directory with Chart.yaml + templates/deploy.yaml from
# the provided YAML content.  Returns the chart path.
make_chart_with_template() {
  local chart_dir="$1" deploy_yaml="$2"
  mkdir -p "$chart_dir/templates"
  cat > "$chart_dir/Chart.yaml" <<'EOFCHART'
apiVersion: v2
name: test-chart
version: 0.1.0
EOFCHART
  printf '%s\n' "$deploy_yaml" > "$chart_dir/templates/deploy.yaml"
}

# ═══════════════════════════════════════════════════════════════════════
# POSITIVE: init-containers PASS cases (VAL-CONFIG-033, 034)
# ═══════════════════════════════════════════════════════════════════════

@test "init-containers: PASS when initContainers are present on rendered workload (positive)" {
  local chart_dir="$TEST_TMPDIR/chart-initcontainers"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      initContainers:
        - name: init-setup
          image: busybox
          command: ["echo", "init"]
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/initcontainers-pass-present.yaml"
  cat > "$s" <<EOF
id: initcontainers-pass-present
name: init-containers PASS present
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: init-containers
    namespace: sample
    source: rendered
    expect_present: true
EOF
  run_assert "init-containers.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "init-containers: PASS for named init container when present on rendered workload (positive, knob)" {
  local chart_dir="$TEST_TMPDIR/chart-initcontainers-named"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      initContainers:
        - name: init-db
          image: busybox
          command: ["echo", "init"]
        - name: init-migrate
          image: busybox
          command: ["echo", "migrate"]
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/initcontainers-pass-named.yaml"
  cat > "$s" <<EOF
id: initcontainers-pass-named
name: init-containers PASS named present
cluster:
  provider: kind
product:
  chart: $chart_dir
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
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "init-containers: FAIL when named init container is missing from rendered workload (knob, negative)" {
  local chart_dir="$TEST_TMPDIR/chart-initcontainers-missing-named"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      initContainers:
        - name: init-db
          image: busybox
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/initcontainers-fail-missing-named.yaml"
  cat > "$s" <<EOF
id: initcontainers-fail-missing-named
name: init-containers FAIL missing named
cluster:
  provider: kind
product:
  chart: $chart_dir
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
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"not found"* ]]
}

@test "init-containers: FAIL when expect_present=false but initContainers present (unexpected)" {
  local chart_dir="$TEST_TMPDIR/chart-initcontainers-unexpected"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      initContainers:
        - name: init-setup
          image: busybox
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/initcontainers-fail-unexpected.yaml"
  cat > "$s" <<EOF
id: initcontainers-fail-unexpected
name: init-containers FAIL unexpected present
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: init-containers
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "init-containers.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"unexpected"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# POSITIVE: host-network PASS cases (VAL-CONFIG-040, 041)
# ═══════════════════════════════════════════════════════════════════════

@test "host-network: PASS when hostNetwork=true on rendered workload (positive)" {
  local chart_dir="$TEST_TMPDIR/chart-hostnet"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      hostNetwork: true
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/hostnet-pass-present.yaml"
  cat > "$s" <<EOF
id: hostnet-pass-present
name: host-network PASS present
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: host-network
    namespace: sample
    source: rendered
    expect_present: true
EOF
  run_assert "host-network.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "host-network: PASS when hostPort is present on container port (positive, check_host_port) (VAL-CONFIG-041)" {
  local chart_dir="$TEST_TMPDIR/chart-hostport"
  # hostNetwork is NOT set (false), but hostPort is present — must still PASS per VAL-CONFIG-041
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      containers:
        - name: app
          image: nginx
          ports:
            - containerPort: 8080
              hostPort: 18080
'
  local s="$TEST_TMPDIR/hostnet-pass-hostport.yaml"
  cat > "$s" <<EOF
id: hostnet-pass-hostport
name: host-network PASS hostPort present
cluster:
  provider: kind
product:
  chart: $chart_dir
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
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "host-network: PASS when both hostNetwork=true AND hostPort present (positive, check_host_port)" {
  local chart_dir="$TEST_TMPDIR/chart-both-hostnet-port"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      hostNetwork: true
      containers:
        - name: app
          image: nginx
          ports:
            - containerPort: 8080
              hostPort: 18080
'
  local s="$TEST_TMPDIR/hostnet-pass-both.yaml"
  cat > "$s" <<EOF
id: hostnet-pass-both
name: host-network PASS both hostNetwork and hostPort
cluster:
  provider: kind
product:
  chart: $chart_dir
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
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "host-network: FAIL when check_host_port=true but hostPort absent (hostNetwork also absent)" {
  local chart_dir="$TEST_TMPDIR/chart-no-hostnet-noport"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      containers:
        - name: app
          image: nginx
          ports:
            - containerPort: 8080
'
  local s="$TEST_TMPDIR/hostnet-fail-no-hostport.yaml"
  cat > "$s" <<EOF
id: hostnet-fail-no-hostport
name: host-network FAIL hostPort absent
cluster:
  provider: kind
product:
  chart: $chart_dir
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
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"hostPort not found"* ]]
}

@test "host-network: FAIL when expect_present=false but hostNetwork=true (unexpected)" {
  local chart_dir="$TEST_TMPDIR/chart-hostnet-unexpected"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      hostNetwork: true
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/hostnet-fail-unexpected.yaml"
  cat > "$s" <<EOF
id: hostnet-fail-unexpected
name: host-network FAIL unexpected hostNetwork
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: host-network
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "host-network.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"unexpected"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# POSITIVE: lifecycle-hooks PASS cases (VAL-CONFIG-047, 048, 049)
# ═══════════════════════════════════════════════════════════════════════

@test "lifecycle-hooks: PASS when postStart is present on rendered workload (positive)" {
  local chart_dir="$TEST_TMPDIR/chart-lifecycle-poststart"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      containers:
        - name: app
          image: nginx
          lifecycle:
            postStart:
              exec:
                command: ["/bin/sh", "-c", "echo started"]
'
  local s="$TEST_TMPDIR/lifecycle-pass-poststart.yaml"
  cat > "$s" <<EOF
id: lifecycle-pass-poststart
name: lifecycle-hooks PASS postStart present
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: lifecycle-hooks
    namespace: sample
    source: rendered
    expect_present: true
    check_postStart: true
    check_preStop: false
EOF
  run_assert "lifecycle-hooks.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "lifecycle-hooks: PASS when preStop is present on rendered workload (positive)" {
  local chart_dir="$TEST_TMPDIR/chart-lifecycle-prestop"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      containers:
        - name: app
          image: nginx
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "echo stopping"]
'
  local s="$TEST_TMPDIR/lifecycle-pass-prestop.yaml"
  cat > "$s" <<EOF
id: lifecycle-pass-prestop
name: lifecycle-hooks PASS preStop present
cluster:
  provider: kind
product:
  chart: $chart_dir
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
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "lifecycle-hooks: PASS when both postStart and preStop are present (positive)" {
  local chart_dir="$TEST_TMPDIR/chart-lifecycle-both"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      containers:
        - name: app
          image: nginx
          lifecycle:
            postStart:
              exec:
                command: ["/bin/sh", "-c", "echo started"]
            preStop:
              exec:
                command: ["/bin/sh", "-c", "echo stopping"]
'
  local s="$TEST_TMPDIR/lifecycle-pass-both.yaml"
  cat > "$s" <<EOF
id: lifecycle-pass-both
name: lifecycle-hooks PASS both hooks present
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: lifecycle-hooks
    namespace: sample
    source: rendered
    expect_present: true
EOF
  run_assert "lifecycle-hooks.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "lifecycle-hooks: FAIL when expect_present=true and both hooks disabled (empty loop guard)" {
  local chart_dir="$TEST_TMPDIR/chart-lifecycle-both-disabled"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/lifecycle-fail-disabled.yaml"
  cat > "$s" <<EOF
id: lifecycle-fail-disabled
name: lifecycle-hooks FAIL both hooks disabled
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: lifecycle-hooks
    namespace: sample
    source: rendered
    expect_present: true
    check_postStart: false
    check_preStop: false
EOF
  run_assert "lifecycle-hooks.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"both"*"disabled"* ]] || [[ "$output" == *"nothing to verify"* ]]
}

@test "lifecycle-hooks: FAIL when expect_present=false but lifecycle hooks present (unexpected)" {
  local chart_dir="$TEST_TMPDIR/chart-lifecycle-unexpected"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      containers:
        - name: app
          image: nginx
          lifecycle:
            postStart:
              exec:
                command: ["/bin/sh", "-c", "echo started"]
'
  local s="$TEST_TMPDIR/lifecycle-fail-unexpected.yaml"
  cat > "$s" <<EOF
id: lifecycle-fail-unexpected
name: lifecycle-hooks FAIL unexpected hook present
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: lifecycle-hooks
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "lifecycle-hooks.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"unexpected"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# POSITIVE: dns-config PASS cases (VAL-CONFIG-054, 055)
# ═══════════════════════════════════════════════════════════════════════

@test "dns-config: PASS when dnsPolicy is set on rendered workload (positive)" {
  local chart_dir="$TEST_TMPDIR/chart-dns-policy"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      dnsPolicy: "None"
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/dns-pass-policy.yaml"
  cat > "$s" <<EOF
id: dns-pass-policy
name: dns-config PASS dnsPolicy set
cluster:
  provider: kind
product:
  chart: $chart_dir
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
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "dns-config: PASS when dnsConfig nameservers are set on rendered workload (positive)" {
  local chart_dir="$TEST_TMPDIR/chart-dns-nameservers"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      dnsConfig:
        nameservers:
          - 8.8.8.8
          - 8.8.4.4
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/dns-pass-nameservers.yaml"
  cat > "$s" <<EOF
id: dns-pass-nameservers
name: dns-config PASS nameservers set
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: dns-config
    namespace: sample
    source: rendered
    expect_present: true
    nameservers:
      - 8.8.8.8
      - 8.8.4.4
EOF
  run_assert "dns-config.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "dns-config: PASS when both dnsPolicy and dnsConfig nameservers set (positive)" {
  local chart_dir="$TEST_TMPDIR/chart-dns-both"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      dnsPolicy: "None"
      dnsConfig:
        nameservers:
          - 8.8.8.8
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/dns-pass-both.yaml"
  cat > "$s" <<EOF
id: dns-pass-both
name: dns-config PASS both dnsPolicy and nameservers
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: dns-config
    namespace: sample
    source: rendered
    expect_present: true
    dns_policy: "None"
    nameservers:
      - 8.8.8.8
EOF
  run_assert "dns-config.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "dns-config: FAIL when dnsPolicy does not match expected (negative)" {
  local chart_dir="$TEST_TMPDIR/chart-dns-wrong-policy"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      dnsPolicy: "ClusterFirst"
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/dns-fail-wrong-policy.yaml"
  cat > "$s" <<EOF
id: dns-fail-wrong-policy
name: dns-config FAIL wrong dnsPolicy
cluster:
  provider: kind
product:
  chart: $chart_dir
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
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"expected"* ]]
}

@test "dns-config: FAIL when expect_present=false but dnsConfig present (unexpected)" {
  local chart_dir="$TEST_TMPDIR/chart-dns-unexpected"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      dnsConfig:
        nameservers:
          - 8.8.8.8
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/dns-fail-unexpected.yaml"
  cat > "$s" <<EOF
id: dns-fail-unexpected
name: dns-config FAIL unexpected DNS config
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: dns-config
    namespace: sample
    source: rendered
    expect_present: false
EOF
  run_assert "dns-config.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"unexpected"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# END-TO-END: run-scenario → result.yaml → collect.py with depth_level
# VAL-CROSS-010: New Area-D config assert flows must preserve status and
# depth_level through the full pipeline.
# ═══════════════════════════════════════════════════════════════════════

# Helper: build a minimal result.yaml that mimics what run-scenario.sh's
# emit_assert() writes, then run collect.py over it and verify depth_level.
run_collect_and_verify_depth() {
  local result_file="$1" assert_type="$2" expected_status="$3" expected_depth="$4"
  local collect_py="$REPO_ROOT/engine/testgrid/src/testgrid/collect.py"

  # Run the collector in "collect from result.yaml" mode.
  # We use a small Python snippet because collect.py expects a reports dir structure.
  local verify_script="$TEST_TMPDIR/verify_collect.py"
  cat > "$verify_script" <<PYEOF
import sys, yaml
sys.path.insert(0, "$(dirname "$collect_py")")
from collect import _scenario_from_result

with open("$result_file") as f:
    doc = yaml.safe_load(f)

sc = _scenario_from_result(doc, agent=None)

# Verify scenario status
assert sc.status == "$expected_status", f"scenario status: expected $expected_status, got {sc.status}"

# Verify at least one assert has the expected type and depth
found = [a for a in sc.asserts if a.type == "$assert_type"]
assert len(found) > 0, f"no assertion of type $assert_type found"
for a in found:
    assert a.status == "$expected_status", f"assert status: expected $expected_status, got {a.status}"
    assert a.depth_level == "$expected_depth", f"depth_level: expected $expected_depth, got {a.depth_level}"
    assert a.depth_level != "", "depth_level is empty"

print(f"OK: {len(found)} assert(s) of type $assert_type with status=$expected_status depth_level=$expected_depth")
PYEOF
  run uv run --directory "$REPO_ROOT/engine/testgrid" python "$verify_script"
  [ $status -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "end-to-end: init-containers assert result flows through result.yaml → collect.py with depth_level L1 (VAL-CROSS-010)" {
  local chart_dir="$TEST_TMPDIR/chart-e2e-initcontainers"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      initContainers:
        - name: init-setup
          image: busybox
          command: ["echo", "init"]
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/e2e-initcontainers.yaml"
  cat > "$s" <<EOF
id: e2e-initcontainers
name: e2e init-containers flow
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: init-containers
    namespace: sample
    source: rendered
    expect_present: true
EOF

  # Run the assert directly and capture its exit code + output
  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/init-containers.sh" "$s" "0"
  local assert_exit=$status
  local assert_output="$output"

  # Build a minimal result.yaml mimicking emit_assert() in run-scenario.sh
  local result_file="$TEST_TMPDIR/result.yaml"
  local assert_status="FAIL"
  [ "$assert_exit" -eq 0 ] && assert_status="PASS"

  cat > "$result_file" <<EOF
scenario_id: e2e-initcontainers
status: $assert_status
duration_s: 1.0
asserts:
  - type: init-containers
    status: $assert_status
    depth_level: L1
    notes: |
      ${assert_output//$'\n'/$'\n      '}
EOF

  # Verify the result.yaml → collect.py chain preserves depth_level
  run_collect_and_verify_depth "$result_file" "init-containers" "$assert_status" "L1"
}

@test "end-to-end: host-network assert result flows through result.yaml → collect.py with depth_level L1 (VAL-CROSS-010)" {
  local chart_dir="$TEST_TMPDIR/chart-e2e-hostnet"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      hostNetwork: true
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/e2e-hostnet.yaml"
  cat > "$s" <<EOF
id: e2e-hostnet
name: e2e host-network flow
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: host-network
    namespace: sample
    source: rendered
    expect_present: true
EOF

  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/host-network.sh" "$s" "0"
  local assert_exit=$status
  local assert_output="$output"

  local assert_status="FAIL"
  [ "$assert_exit" -eq 0 ] && assert_status="PASS"

  local result_file="$TEST_TMPDIR/result-e2e-hostnet.yaml"
  cat > "$result_file" <<EOF
scenario_id: e2e-hostnet
status: $assert_status
duration_s: 1.0
asserts:
  - type: host-network
    status: $assert_status
    depth_level: L1
    notes: |
      ${assert_output//$'\n'/$'\n      '}
EOF

  run_collect_and_verify_depth "$result_file" "host-network" "$assert_status" "L1"
}

@test "end-to-end: lifecycle-hooks assert result flows through result.yaml → collect.py with depth_level L1 (VAL-CROSS-010)" {
  local chart_dir="$TEST_TMPDIR/chart-e2e-lifecycle"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      containers:
        - name: app
          image: nginx
          lifecycle:
            postStart:
              exec:
                command: ["/bin/sh", "-c", "echo started"]
'
  local s="$TEST_TMPDIR/e2e-lifecycle.yaml"
  cat > "$s" <<EOF
id: e2e-lifecycle
name: e2e lifecycle-hooks flow
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: lifecycle-hooks
    namespace: sample
    source: rendered
    expect_present: true
    check_postStart: true
    check_preStop: false
EOF

  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/lifecycle-hooks.sh" "$s" "0"
  local assert_exit=$status
  local assert_output="$output"

  local assert_status="FAIL"
  [ "$assert_exit" -eq 0 ] && assert_status="PASS"

  local result_file="$TEST_TMPDIR/result-e2e-lifecycle.yaml"
  cat > "$result_file" <<EOF
scenario_id: e2e-lifecycle
status: $assert_status
duration_s: 1.0
asserts:
  - type: lifecycle-hooks
    status: $assert_status
    depth_level: L1
    notes: |
      ${assert_output//$'\n'/$'\n      '}
EOF

  run_collect_and_verify_depth "$result_file" "lifecycle-hooks" "$assert_status" "L1"
}

@test "end-to-end: dns-config assert result flows through result.yaml → collect.py with depth_level L1 (VAL-CROSS-010)" {
  local chart_dir="$TEST_TMPDIR/chart-e2e-dns"
  make_chart_with_template "$chart_dir" '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  template:
    spec:
      dnsPolicy: "None"
      containers:
        - name: app
          image: nginx
'
  local s="$TEST_TMPDIR/e2e-dns.yaml"
  cat > "$s" <<EOF
id: e2e-dns
name: e2e dns-config flow
cluster:
  provider: kind
product:
  chart: $chart_dir
  release: test-release
  namespace: sample
asserts:
  - type: dns-config
    namespace: sample
    source: rendered
    expect_present: true
    dns_policy: "None"
EOF

  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/dns-config.sh" "$s" "0"
  local assert_exit=$status
  local assert_output="$output"

  local assert_status="FAIL"
  [ "$assert_exit" -eq 0 ] && assert_status="PASS"

  local result_file="$TEST_TMPDIR/result-e2e-dns.yaml"
  cat > "$result_file" <<EOF
scenario_id: e2e-dns
status: $assert_status
duration_s: 1.0
asserts:
  - type: dns-config
    status: $assert_status
    depth_level: L1
    notes: |
      ${assert_output//$'\n'/$'\n      '}
EOF

  run_collect_and_verify_depth "$result_file" "dns-config" "$assert_status" "L1"
}
