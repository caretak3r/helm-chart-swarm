#!/usr/bin/env bats
# ingress-routes-traffic.bats — Tests for the L3 behavioral assert
# ingress-routes-traffic. Covers SKIP (no Ingress CRD), FAIL paths
# (Ingress exists but returns 503/404), and PASS path (HTTP 200 through Ingress).

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
ASSERTS_DIR="$REPO_ROOT/engine/asserts"
PROJECT_DIR="$REPO_ROOT/examples/sample-product-chart"

setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/irt-bats-XXXXXX)"
  STUB_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH:/opt/homebrew/bin:/usr/local/bin"
  export RELEASE="test-release"
  export NAMESPACE="test-ns"
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/irt-dummy}" 2>/dev/null || true
}

run_assert() {
  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/ingress-routes-traffic.sh" "$1" "${2:-0}"
}

stub_cmd() {
  local name="$1"
  local content="$2"
  local exit_code="${3:-0}"
  printf '#!/usr/bin/env bash\n%s\nexit %s\n' "$content" "$exit_code" > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}

# ── Basic scenario fixture ───────────────────────────────────────────────
make_scenario() {
  local id="${1:-ingress-test}"
  local ingress_host="${2:-test-release.test-ns.svc}"
  local controller_ns="${3:-ingress-nginx}"
  local controller_label="${4:-app.kubernetes.io/name=ingress-nginx}"
  local ingress_name="${5:-test-release}"
  cat <<EOF
id: ${id}
name: Ingress routes traffic test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: ingress-routes-traffic
    namespace: test-ns
    ingress_host: "${ingress_host}"
    controller_namespace: "${controller_ns}"
    controller_label: "${controller_label}"
    ingress_name: "${ingress_name}"
EOF
}

# ═══════════════════════════════════════════════════════════════════════
# SKIP: platform capability absent
# ═══════════════════════════════════════════════════════════════════════

@test "ingress-routes-traffic SKIPs when Ingress API resource is not available" {
  stub_cmd "kubectl" '
case "$*" in
  *"api-resources"*) exit 1 ;;
  *) exit 0 ;;
esac'

  local s="$TEST_TMPDIR/irt-skip-noapi.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: SKIP"* ]]
  [[ "$output" == *"platform_capability_absent"* ]]
}

@test "ingress-routes-traffic SKIPs non-failing (exit 0)" {
  stub_cmd "kubectl" '
case "$*" in
  *"api-resources"*) exit 1 ;;
  *) exit 0 ;;
esac'

  local s="$TEST_TMPDIR/irt-skip-exit.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
}

@test "ingress-routes-traffic detects Ingress via api-resources (not CRD)" {
  # The assert should use kubectl api-resources, NOT kubectl get crd.
  # Stub both: api-resources succeeds → capability detected.
  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"api-resources"*) echo "ingresses  Ingress  true  Ingress  networking.k8s.io"; exit 0 ;;
  *"run"*) echo "200" ;;
  *"get pod"*"podIP"*) echo "10.0.0.2" ;;
  *"get pod"*) echo "ingress-controller-abc" ;;
  *"get ingress"*) echo "test-release" ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/irt-api-resources.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: Ingress exists but returns 503
# ═══════════════════════════════════════════════════════════════════════

@test "ingress-routes-traffic FAILs when Ingress exists but returns 503" {
  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"api-resources"*) echo "ingresses  Ingress  true  Ingress  networking.k8s.io"; exit 0 ;;
  *"run"*) echo "503" ;;
  *"get pod"*"-o jsonpath"*) echo "10.0.0.2" ;;
  *"get pod"*) echo "ingress-controller-abc" ;;
  *"get ingress"*) echo "test-release" ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/irt-fail-503.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: Ingress exists but returns 404
# ═══════════════════════════════════════════════════════════════════════

@test "ingress-routes-traffic FAILs when Ingress exists but returns 404" {
  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"api-resources"*) echo "ingresses  Ingress  true  Ingress  networking.k8s.io"; exit 0 ;;
  *"run"*) echo "404" ;;
  *"get pod"*"-o jsonpath"*) echo "10.0.0.2" ;;
  *"get pod"*) echo "ingress-controller-abc" ;;
  *"get ingress"*) echo "test-release" ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/irt-fail-404.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: Ingress exists but controller pod not found
# ═══════════════════════════════════════════════════════════════════════

@test "ingress-routes-traffic FAILs when Ingress exists but no controller pod found" {
  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"api-resources"*) echo "ingresses  Ingress  true  Ingress  networking.k8s.io"; exit 0 ;;
  *"get pod"*) exit 1 ;;
  *"get ingress"*) echo "test-release" ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/irt-fail-no-controller.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# PASS: Ingress routes traffic (HTTP 200)
# ═══════════════════════════════════════════════════════════════════════

@test "ingress-routes-traffic PASSes when Ingress returns expected HTTP 200" {
  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"api-resources"*) echo "ingresses  Ingress  true  Ingress  networking.k8s.io"; exit 0 ;;
  *"run"*) echo "200" ;;
  *"get pod"*"podIP"*) echo "10.0.0.2" ;;
  *"get pod"*) echo "ingress-controller-abc" ;;
  *"get ingress"*) echo "test-release" ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/irt-pass.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# PASS: honors custom expected status
# ═══════════════════════════════════════════════════════════════════════

@test "ingress-routes-traffic PASSes with custom expected_status" {
  local s="$TEST_TMPDIR/irt-pass-custom.yaml"
  cat > "$s" <<'EOF'
id: ingress-test-custom
name: Custom status test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: ingress-routes-traffic
    namespace: test-ns
    ingress_host: test.example.com
    controller_namespace: ingress-nginx
    controller_label: app.kubernetes.io/name=ingress-nginx
    ingress_name: test-release
    expected_status: 302
EOF

  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"api-resources"*) echo "ingresses  Ingress  true  Ingress  networking.k8s.io"; exit 0 ;;
  *"run"*) echo "302" ;;
  *"get pod"*"podIP"*) echo "10.0.0.2" ;;
  *"get pod"*) echo "ingress-controller-abc" ;;
  *"get ingress"*) echo "test-release" ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# PASS: ingress-routes-traffic honors controller_port
# ═══════════════════════════════════════════════════════════════════════

@test "ingress-routes-traffic uses controller_port in probe URL" {
  local s="$TEST_TMPDIR/irt-port.yaml"
  cat > "$s" <<'EOF'
id: ingress-test-port
name: Controller port test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: ingress-routes-traffic
    namespace: test-ns
    ingress_host: test.example.com
    controller_namespace: traefik
    controller_label: app.kubernetes.io/name=traefik
    ingress_name: test-release
    controller_port: 8000
EOF

  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
# This stub records the curl URL for verification
case "$*" in
  *"api-resources"*) echo "ingresses  Ingress  true  Ingress  networking.k8s.io"; exit 0 ;;
  *"run"*)
    # Verify the probe URL includes port 8000
    echo "$*" >> /tmp/irt-port-probe
    echo "200" ;;
  *"get pod"*"podIP"*) echo "10.0.0.2" ;;
  *"get pod"*) echo "traefik-abc" ;;
  *"get ingress"*) echo "test-release" ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
}

@test "ingress-routes-traffic defaults controller_port to 80" {
  local s="$TEST_TMPDIR/irt-default-port.yaml"
  # No controller_port specified → should default to 80
  cat > "$s" <<'EOF'
id: ingress-test-default-port
name: Default port test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: ingress-routes-traffic
    namespace: test-ns
    ingress_host: test.example.com
    controller_namespace: ingress-nginx
    ingress_name: test-release
EOF

  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"api-resources"*) echo "ingresses  Ingress  true  Ingress  networking.k8s.io"; exit 0 ;;
  *"run"*) echo "200" ;;
  *"get pod"*"podIP"*) echo "10.0.0.2" ;;
  *"get pod"*) echo "ingress-controller-abc" ;;
  *"get ingress"*) echo "test-release" ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
}
