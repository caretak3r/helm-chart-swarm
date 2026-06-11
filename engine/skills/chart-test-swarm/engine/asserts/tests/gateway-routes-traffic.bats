#!/usr/bin/env bats
# gateway-routes-traffic.bats — Tests for the L3 behavioral assert
# gateway-routes-traffic. Covers SKIP (no Gateway API CRDs), FAIL paths
# (Gateway/HTTPRoute present but not serving), and PASS path (traffic flows).

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
ASSERTS_DIR="$REPO_ROOT/engine/asserts"
PROJECT_DIR="$REPO_ROOT/examples/sample-product-chart"

setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/grt-bats-XXXXXX)"
  STUB_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH:/opt/homebrew/bin:/usr/local/bin"
  export RELEASE="test-release"
  export NAMESPACE="test-ns"
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/grt-dummy}" 2>/dev/null || true
}

run_assert() {
  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/gateway-routes-traffic.sh" "$1" "${2:-0}"
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
  local id="${1:-gateway-test}"
  local gateway_host="${2:-test-release.test-ns.svc}"
  local gateway_class="${3:-envoy}"
  local gateway_name="${4:-test-release-gw}"
  local route_name="${5:-test-release-route}"
  local controller_ns="${6:-envoy-gateway-system}"
  cat <<EOF
id: ${id}
name: Gateway routes traffic test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: gateway-routes-traffic
    namespace: test-ns
    gateway_host: "${gateway_host}"
    gateway_class: "${gateway_class}"
    gateway_name: "${gateway_name}"
    route_name: "${route_name}"
    controller_namespace: "${controller_ns}"
EOF
}

# ═══════════════════════════════════════════════════════════════════════
# SKIP: platform capability absent
# ═══════════════════════════════════════════════════════════════════════

@test "gateway-routes-traffic SKIPs when no Gateway API CRDs exist" {
  stub_cmd "kubectl" '
case "$*" in
  *"get crd"*) exit 1 ;;
  *) exit 0 ;;
esac'

  local s="$TEST_TMPDIR/grt-skip-nocrd.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: SKIP"* ]]
  [[ "$output" == *"platform_capability_absent"* ]]
}

@test "gateway-routes-traffic SKIPs non-failing (exit 0)" {
  stub_cmd "kubectl" '
case "$*" in
  *"get crd"*) exit 1 ;;
  *) exit 0 ;;
esac'

  local s="$TEST_TMPDIR/grt-skip-exit.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: GatewayClass not Accepted
# ═══════════════════════════════════════════════════════════════════════

@test "gateway-routes-traffic FAILs when GatewayClass is not Accepted" {
  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd"*) exit 0 ;;
  *"get gatewayclass"*) echo "False"; exit 0 ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/grt-fail-gatewayclass.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: Gateway listener not Programmed
# ═══════════════════════════════════════════════════════════════════════

@test "gateway-routes-traffic FAILs when Gateway listener not Programmed" {
  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd"*) exit 0 ;;
  *"get gatewayclass"*) echo "True"; exit 0 ;;
  *"get gateway"*"Programmed"*) echo "False"; exit 0 ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/grt-fail-gateway.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: HTTPRoute not Accepted
# ═══════════════════════════════════════════════════════════════════════

@test "gateway-routes-traffic FAILs when HTTPRoute not Accepted" {
  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd"*) exit 0 ;;
  *"get gatewayclass"*) echo "True"; exit 0 ;;
  *"get gateway"*"Programmed"*) echo "True"; exit 0 ;;
  *"get httproute"*) echo "False"; exit 0 ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/grt-fail-route.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: Gateway/HTTPRoute present but traffic returns 503
# ═══════════════════════════════════════════════════════════════════════

@test "gateway-routes-traffic FAILs when Gateway/HTTPRoute present but returns 503" {
  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd"*) exit 0 ;;
  *"get gatewayclass"*) echo "True"; exit 0 ;;
  *"get gateway"*"Programmed"*) echo "True"; exit 0 ;;
  *"get httproute"*) echo "True"; exit 0 ;;
  *"get svc"*"gateway.envoyproxy.io"*) echo "envoy-gateway-proxy 10.0.0.50"; exit 0 ;;
  *"get svc"*"-o jsonpath"*) echo "10.0.0.50"; exit 0 ;;
  *"run"*) echo "503" ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/grt-fail-503.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# PASS: Gateway route serves traffic (HTTP 200)
# ═══════════════════════════════════════════════════════════════════════

@test "gateway-routes-traffic PASSes when Gateway route returns HTTP 200" {
  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd"*) exit 0 ;;
  *"get gatewayclass"*) echo "True"; exit 0 ;;
  *"get gateway"*"Programmed"*) echo "True"; exit 0 ;;
  *"get httproute"*) echo "True"; exit 0 ;;
  *"get svc"*"gateway.envoyproxy.io"*) echo "envoy-gateway-proxy 10.0.0.50"; exit 0 ;;
  *"get svc"*"-o jsonpath"*) echo "10.0.0.50"; exit 0 ;;
  *"run"*) echo "200" ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/grt-pass.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# PASS: Gateway route serves traffic via product-namespace Service (Istio)
# ═══════════════════════════════════════════════════════════════════════

@test "gateway-routes-traffic finds Service in product namespace (Istio pattern)" {
  # Istio auto-provisions the data-plane Service in the product namespace,
  # labeled with gateway.networking.k8s.io/gateway-name=<gw>.
  # The assert must find it there BEFORE looking in the controller namespace.
  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd"*) exit 0 ;;
  *"get gatewayclass"*) echo "True"; exit 0 ;;
  *"get gateway"*"Programmed"*) echo "True"; exit 0 ;;
  *"get httproute"*) echo "True"; exit 0 ;;
  # Service lookup in product namespace (test-ns) → found (Istio pattern)
  *"-n test-ns get svc"*"gateway.networking.k8s.io/gateway-name"*) echo "sample-gw-istio 10.0.0.60"; exit 0 ;;
  *"get svc"*"-o jsonpath"*) echo "10.0.0.60"; exit 0 ;;
  *"run"*) echo "200" ;;
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/grt-istio-pass.yaml"
  cat > "$s" <<'EOF'
id: gateway-istio-test
name: Istio Gateway API traffic test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: gateway-routes-traffic
    namespace: test-ns
    gateway_host: sample.test.local
    gateway_class: istio
    gateway_name: sample-gw
    route_name: sample-route
    controller_namespace: istio-system
EOF

  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
  # Verify the Service was found in the product namespace, not istio-system
  [[ "$output" == *"product namespace"* ]]
}

@test "gateway-routes-traffic FAILs when no Service found in any namespace" {
  # Neither product namespace nor controller namespace has the Service.
  cat > "$STUB_BIN/kubectl" <<'STUBSCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd"*) exit 0 ;;
  *"get gatewayclass"*) echo "True"; exit 0 ;;
  *"get gateway"*"Programmed"*) echo "True"; exit 0 ;;
  *"get httproute"*) echo "True"; exit 0 ;;
  *"get svc"*) exit 1 ;;  # No Service found anywhere
  *) exit 0 ;;
esac
STUBSCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/grt-fail-no-svc.yaml"
  cat > "$s" <<'EOF'
id: gateway-no-svc-test
name: No Service test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: gateway-routes-traffic
    namespace: test-ns
    gateway_host: test.example.com
    gateway_class: istio
    gateway_name: sample-gw
    route_name: sample-route
    controller_namespace: istio-system
EOF

  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}
