#!/usr/bin/env bats
# network-policy-enforced.bats — Tests for the L3 behavioral assert
# network-policy-enforced. Covers FAIL paths (policy present but traffic
# flows, over-block), SKIP (no platform capability), and PASS paths.
#
# Non-live tests use stubbed kubectl to control CRD presence, service
# resolution, and in-cluster probe results.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
ASSERTS_DIR="$REPO_ROOT/engine/asserts"
PROJECT_DIR="$REPO_ROOT/examples/sample-product-chart"

setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/npe-bats-XXXXXX)"
  STUB_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  # Preserve access to real yq and other tools by keeping original PATH dirs
  export PATH="$STUB_BIN:$PATH:/opt/homebrew/bin:/usr/local/bin"
  export RELEASE="test-release"
  export NAMESPACE="test-ns"
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/npe-dummy}" 2>/dev/null || true
}

run_assert() {
  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/network-policy-enforced.sh" "$1" "${2:-0}"
}

# Helper: create a stub script that echoes content and exits with given code
stub_cmd() {
  local name="$1"
  local output="$2"
  local exit_code="${3:-0}"
  printf '#!/usr/bin/env bash\n%s\nexit %s\n' "$output" "$exit_code" > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}

# ── Basic scenario fixture ───────────────────────────────────────────────
make_scenario() {
  local id="${1:-npe-test}"
  local port="${2:-80}"
  local allowed_label="${3:-access=allowed}"
  cat <<EOF
id: ${id}
name: NPE test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: network-policy-enforced
    namespace: test-ns
    port: ${port}
    allowed_label: "${allowed_label}"
EOF
}

# ═══════════════════════════════════════════════════════════════════════
# SKIP: platform capability absent
# ═══════════════════════════════════════════════════════════════════════

@test "network-policy-enforced SKIPs when no NetworkPolicy CRD exists" {
  # Stub kubectl: all CRD checks fail (no NetworkPolicy/Cilium/Calico CRDs)
  stub_cmd "kubectl" 'exit 1' 1

  local s="$TEST_TMPDIR/npe-skip-nocrd.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: SKIP"* ]]
  [[ "$output" == *"platform_capability_absent"* ]]
}

@test "network-policy-enforced SKIPs non-failing (exit 0)" {
  stub_cmd "kubectl" 'exit 1' 1

  local s="$TEST_TMPDIR/npe-skip-exit.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: policy present but denied traffic still flows
# ═══════════════════════════════════════════════════════════════════════

@test "network-policy-enforced FAILs when denied traffic reaches the service (HTTP 200)" {
  # Denied probe returns 200 (policy not enforced)
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"run ct-npe-allowed"*)
    echo "200"
    exit 0
    ;;
  *"run ct-npe-denied"*)
    echo "200"
    exit 0
    ;;
  *"get crd"*)
    exit 0
    ;;
  *"get svc test-release"*)
    echo "10.0.0.1"
    exit 0
    ;;
  *"get svc -l"*)
    echo ""
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/npe-fail-denied-flows.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]] || [[ "$output" == *"policy present but traffic still flows"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: over-block — allowed path broken
# ═══════════════════════════════════════════════════════════════════════

@test "network-policy-enforced FAILs when allowed path is blocked (over-block)" {
  # Both allowed and denied probes return 000
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"run ct-npe-allowed"*)
    echo "000"
    exit 0
    ;;
  *"run ct-npe-denied"*)
    echo "000"
    exit 0
    ;;
  *"get crd"*)
    exit 0
    ;;
  *"get svc test-release"*)
    echo "10.0.0.1"
    exit 0
    ;;
  *"get svc -l"*)
    echo ""
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/npe-fail-overblock.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"over-block"* ]] || [[ "$output" == *"FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# PASS: both directions work
# ═══════════════════════════════════════════════════════════════════════

@test "network-policy-enforced PASSes when allowed succeeds and denied is blocked" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
# Match kubectl subcommands by pattern
case "$*" in
  *"run ct-npe-allowed"*)
    echo "200"
    exit 0
    ;;
  *"run ct-npe-denied"*)
    echo "000"
    exit 0
    ;;
  *"get crd networkpolicies"*|*"get crd ciliumnetwork"*|*"get crd networkpolicies.crd"*)
    exit 0
    ;;
  *"get svc test-release"*)
    echo "10.0.0.1"
    exit 0
    ;;
  *"get svc -l"*)
    echo ""
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/npe-pass.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
  [[ "$output" == *"allowed=reachable"* ]]
  [[ "$output" == *"denied=blocked"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: no Service found
# ═══════════════════════════════════════════════════════════════════════

@test "network-policy-enforced FAILs when no release-scoped Service exists" {
  # CRD exists but no service
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd"*)
    exit 0
    ;;
  *"get svc"*)
    echo ""
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/npe-fail-nosvc.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"no release-scoped Service"* ]] || [[ "$output" == *"FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# ASSERTION_RESULT + depth metadata
# ═══════════════════════════════════════════════════════════════════════

@test "network-policy-enforced emits ASSERTION_RESULT line on PASS" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"run ct-npe-allowed"*)
    echo "200"
    exit 0
    ;;
  *"run ct-npe-denied"*)
    echo "000"
    exit 0
    ;;
  *"get crd"*)
    exit 0
    ;;
  *"get svc test-release"*)
    echo "10.0.0.1"
    exit 0
    ;;
  *"get svc -l"*)
    echo ""
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/npe-ar-pass.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
}

@test "network-policy-enforced emits ASSERTION_RESULT line on FAIL" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"run ct-npe-allowed"*)
    echo "200"
    exit 0
    ;;
  *"run ct-npe-denied"*)
    echo "200"
    exit 0
    ;;
  *"get crd"*)
    exit 0
    ;;
  *"get svc test-release"*)
    echo "10.0.0.1"
    exit 0
    ;;
  *"get svc -l"*)
    echo ""
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/npe-ar-fail.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# L3 depth header verification
# ═══════════════════════════════════════════════════════════════════════

@test "network-policy-enforced.sh carries # DEPTH: L3 header" {
  run grep '^# DEPTH: L3' "$ASSERTS_DIR/network-policy-enforced.sh"
  [ $status -eq 0 ]
}

@test "network-policy-enforced registry entry is L3" {
  local depth
  depth=$(yq '.network-policy-enforced' "$ASSERTS_DIR/registry.yaml")
  [ "$depth" = "L3" ]
}

# ═══════════════════════════════════════════════════════════════════════
# Generalization: no hardcoded consumer names
# ═══════════════════════════════════════════════════════════════════════

@test "network-policy-enforced.sh has no hardcoded 'sample' release name" {
  run grep -n 'sample\.test\.local\|:-sample\b\|RELEASE:-sample' "$ASSERTS_DIR/network-policy-enforced.sh"
  [ $status -ne 0 ]
}

@test "network-policy-enforced.sh uses parameterized RELEASE/NAMESPACE" {
  local count
  count=$(grep -cE '\$\{?RELEASE\}?|\$\{?NS\}?|\$\{?NAMESPACE\}?' "$ASSERTS_DIR/network-policy-enforced.sh" 2>/dev/null)
  [ "${count:-0}" -gt 0 ]
}
