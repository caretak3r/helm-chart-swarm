#!/usr/bin/env bats
# mesh-mtls-enforced.bats — Tests for the L3 behavioral assert
# mesh-mtls-enforced. Covers FAIL paths (STRICT policy present but
# plaintext still succeeds), SKIP (no mesh platform), and PASS paths.
#
# Non-live tests use stubbed kubectl to control CRD presence, service
# resolution, and in-cluster probe results.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
ASSERTS_DIR="$REPO_ROOT/engine/asserts"
PROJECT_DIR="$REPO_ROOT/examples/sample-product-chart"

setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/mme-bats-XXXXXX)"
  STUB_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  # Preserve access to real yq and other tools by keeping original PATH dirs
  export PATH="$STUB_BIN:$PATH:/opt/homebrew/bin:/usr/local/bin"
  export RELEASE="test-release"
  export NAMESPACE="test-ns"
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/mme-dummy}" 2>/dev/null || true
}

run_assert() {
  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/mesh-mtls-enforced.sh" "$1" "${2:-0}"
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
  local id="${1:-mme-test}"
  local port="${2:-80}"
  local mesh_type="${3:-istio}"
  cat <<EOF
id: ${id}
name: MME test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: mesh-mtls-enforced
    namespace: test-ns
    port: ${port}
    mesh_type: "${mesh_type}"
EOF
}

# ═══════════════════════════════════════════════════════════════════════
# SKIP: platform capability absent
# ═══════════════════════════════════════════════════════════════════════

@test "mesh-mtls-enforced SKIPs when no Istio PeerAuthentication CRD exists" {
  # Stub kubectl: CRD check fails, then no CRD found → SKIP
  stub_cmd "kubectl" 'exit 1' 1

  local s="$TEST_TMPDIR/mme-skip-nocrd.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: SKIP"* ]]
  [[ "$output" == *"platform_capability_absent"* ]]
}

@test "mesh-mtls-enforced SKIPs non-failing (exit 0)" {
  stub_cmd "kubectl" 'exit 1' 1

  local s="$TEST_TMPDIR/mme-skip-exit.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
}

@test "mesh-mtls-enforced SKIPs when Linkerd Server CRD absent" {
  # Stub kubectl: no linkerd CRD → SKIP
  stub_cmd "kubectl" 'exit 1' 1

  local s="$TEST_TMPDIR/mme-skip-linkerd.yaml"
  cat > "$s" <<'EOF'
id: mme-skip-linkerd
name: MME Linkerd skip
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: mesh-mtls-enforced
    namespace: test-ns
    port: 80
    mesh_type: "linkerd"
EOF
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: SKIP"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: STRICT policy present but plaintext still succeeds
# ═══════════════════════════════════════════════════════════════════════

@test "mesh-mtls-enforced FAILs when plaintext non-mesh probe returns 200 under STRICT" {
  # Stub kubectl: CRD exists, svc resolves, non-mesh exec returns 200 (bad),
  # mesh exec returns 200 — the plaintext 200 must be caught as FAIL.
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
# Pattern: if the command contains 'exec ct-mme-nonmesh', respond with 200 (plaintext succeeds!)
# if it contains 'exec ct-mme-mesh', respond with 200
# For CRD, svc, ns, pod create/wait: succeed
case "$*" in
  *"exec ct-mme-nonmesh"*)
    echo "200"
    exit 0
    ;;
  *"exec ct-mme-mesh"*)
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
  *)
    exit 0
    ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/mme-fail-plaintext.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]] || [[ "$output" == *"plaintext still succeeds"* ]] || [[ "$output" == *"FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# PASS: both directions work (plaintext rejected, mesh succeeds)
# ═══════════════════════════════════════════════════════════════════════

@test "mesh-mtls-enforced PASSes when plaintext rejected and mesh probe succeeds" {
  # Stub kubectl: CRD exists, svc resolves, non-mesh exec returns 000,
  # mesh exec returns 200.
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"exec ct-mme-nonmesh"*)
    echo "000"
    exit 0
    ;;
  *"exec ct-mme-mesh"*)
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
  *)
    exit 0
    ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/mme-pass.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
  [[ "$output" == *"REJECTED"* ]]
  [[ "$output" == *"auto-upgraded mTLS"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: no Service found
# ═══════════════════════════════════════════════════════════════════════

@test "mesh-mtls-enforced FAILs when no release-scoped Service exists" {
  # Stub kubectl: CRD exists but no service
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
  *)
    exit 0
    ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/mme-fail-nosvc.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"no release-scoped Service"* ]] || [[ "$output" == *"FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: unsupported mesh_type
# ═══════════════════════════════════════════════════════════════════════

@test "mesh-mtls-enforced FAILs on unsupported mesh_type" {
  # Stub kubectl: CRD check succeeds
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/mme-fail-badtype.yaml"
  cat > "$s" <<'EOF'
id: mme-badtype
name: MME bad type
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: mesh-mtls-enforced
    namespace: test-ns
    port: 80
    mesh_type: "consul"
EOF
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"unsupported mesh_type"* ]] || [[ "$output" == *"FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# ASSERTION_RESULT + depth metadata
# ═══════════════════════════════════════════════════════════════════════

@test "mesh-mtls-enforced emits ASSERTION_RESULT line on PASS" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"exec ct-mme-nonmesh"*)
    echo "000"
    exit 0
    ;;
  *"exec ct-mme-mesh"*)
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

  local s="$TEST_TMPDIR/mme-ar-pass.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
}

@test "mesh-mtls-enforced emits ASSERTION_RESULT line on FAIL" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"exec ct-mme-nonmesh"*)
    echo "200"
    exit 0
    ;;
  *"exec ct-mme-mesh"*)
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

  local s="$TEST_TMPDIR/mme-ar-fail.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# L3 depth header verification
# ═══════════════════════════════════════════════════════════════════════

@test "mesh-mtls-enforced.sh carries # DEPTH: L3 header" {
  run grep '^# DEPTH: L3' "$ASSERTS_DIR/mesh-mtls-enforced.sh"
  [ $status -eq 0 ]
}

@test "mesh-mtls-enforced registry entry is L3" {
  local depth
  depth=$(yq '.mesh-mtls-enforced' "$ASSERTS_DIR/registry.yaml")
  [ "$depth" = "L3" ]
}

# ═══════════════════════════════════════════════════════════════════════
# Generalization: no hardcoded consumer names
# ═══════════════════════════════════════════════════════════════════════

@test "mesh-mtls-enforced.sh has no hardcoded 'sample' release name" {
  run grep -n 'sample\.test\.local\|:-sample\b\|RELEASE:-sample' "$ASSERTS_DIR/mesh-mtls-enforced.sh"
  [ $status -ne 0 ]
}

@test "mesh-mtls-enforced.sh uses parameterized RELEASE/NAMESPACE" {
  local count
  count=$(grep -cE '\$\{?RELEASE\}?|\$\{?NS\}?|\$\{?NAMESPACE\}?' "$ASSERTS_DIR/mesh-mtls-enforced.sh" 2>/dev/null)
  [ "${count:-0}" -gt 0 ]
}
