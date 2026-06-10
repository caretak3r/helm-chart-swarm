#!/usr/bin/env bats
# policy-denies-violation.bats — Tests for the L3 behavioral assert
# policy-denies-violation. Covers FAIL paths (violating admitted, compliant
# denied), SKIP (no platform capability), PASS paths, and depth metadata.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
ASSERTS_DIR="$REPO_ROOT/engine/asserts"
PROJECT_DIR="$REPO_ROOT/examples/sample-product-chart"

setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/pdv-bats-XXXXXX)"
  STUB_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH:/opt/homebrew/bin:/usr/local/bin"
  export RELEASE="test-release"
  export NAMESPACE="test-ns"
  export PROJECT_DIR="/tmp/pdv-project"

  mkdir -p "$PROJECT_DIR"
  echo "apiVersion: v1
kind: Pod
metadata:
  name: test-violating
  namespace: test-ns" > "$PROJECT_DIR/test-violating.yaml"
  echo "apiVersion: v1
kind: Pod
metadata:
  name: test-compliant
  namespace: test-ns" > "$PROJECT_DIR/test-compliant.yaml"
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/pdv-dummy}" 2>/dev/null || true
  rm -rf "/tmp/pdv-project" 2>/dev/null || true
}

run_assert() {
  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/policy-denies-violation.sh" "$1" "${2:-0}"
}

make_scenario() {
  local id="${1:-pdv-test}"
  local policy_type="${2:-kyverno}"
  cat <<EOF
id: ${id}
name: PDV test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: policy-denies-violation
    namespace: test-ns
    policy_type: "${policy_type}"
    violating_fixture: test-violating.yaml
    compliant_fixture: test-compliant.yaml
EOF
}

# ── Stub helpers ─────────────────────────────────────────────────────────
stub_cmd() {
  local name="$1"
  local output="$2"
  local exit_code="${3:-0}"
  printf '#!/usr/bin/env bash\n%s\nexit %s\n' "$output" "$exit_code" > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}

# ═══════════════════════════════════════════════════════════════════════
# SKIP: platform capability absent
# ═══════════════════════════════════════════════════════════════════════

@test "policy-denies-violation SKIPs when no Kyverno CRD exists" {
  stub_cmd "kubectl" 'exit 1' 1

  local s="$TEST_TMPDIR/pdv-skip-nocrd.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: SKIP"* ]]
  [[ "$output" == *"platform_capability_absent"* ]]
}

@test "policy-denies-violation SKIPs non-failing (exit 0)" {
  stub_cmd "kubectl" 'exit 1' 1

  local s="$TEST_TMPDIR/pdv-skip-exit.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: violating fixture admitted (policy not enforcing)
# ═══════════════════════════════════════════════════════════════════════

@test "policy-denies-violation FAILs when violating object is admitted" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd clusterpolicies"*)
    exit 0
    ;;
  *"apply --dry-run=server"*"-f"*"test-violating"*)
    echo "pod/test-violating created (server dry run)"
    exit 0
    ;;
  *"apply --dry-run=server"*"-f"*"test-compliant"*)
    echo "pod/test-compliant created (server dry run)"
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/pdv-fail-violating-admitted.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]] || [[ "$output" == *"violating object was ADMITTED"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: compliant fixture denied (over-block)
# ═══════════════════════════════════════════════════════════════════════

@test "policy-denies-violation FAILs when compliant object is denied" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd clusterpolicies"*)
    exit 0
    ;;
  *"apply --dry-run=server"*"-f"*"test-violating"*)
    echo "Error from server (Forbidden): admission webhook denied"
    exit 1
    ;;
  *"apply --dry-run=server"*"-f"*"test-compliant"*)
    echo "Error from server (Forbidden): admission webhook denied"
    exit 1
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/pdv-fail-compliant-denied.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]] || [[ "$output" == *"over-blocking"* ]] || [[ "$output" == *"DENIED"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: missing required fields
# ═══════════════════════════════════════════════════════════════════════

@test "policy-denies-violation FAILs when violating_fixture is missing" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd clusterpolicies"*) exit 0 ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/pdv-fail-missing-violating.yaml"
  cat <<EOF > "$s"
id: pdv-missing
name: PDV missing
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: policy-denies-violation
    namespace: test-ns
    policy_type: kyverno
    compliant_fixture: test-compliant.yaml
EOF

  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"violating_fixture"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# PASS: violating denied, compliant admitted
# ═══════════════════════════════════════════════════════════════════════

@test "policy-denies-violation PASSes when violating denied and compliant admitted" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd clusterpolicies"*)
    exit 0
    ;;
  *"apply --dry-run=server"*"-f"*"test-violating"*)
    echo "Error from server: admission webhook \"validate.kyverno.svc\" denied the request"
    exit 1
    ;;
  *"apply --dry-run=server"*"-f"*"test-compliant"*)
    echo "pod/test-compliant created (server dry run)"
    exit 0
    ;;
  *"wait pod"*)
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/pdv-pass.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
  [[ "$output" == *"violating=denied"* ]]
  [[ "$output" == *"compliant=accepted"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# ASSERTION_RESULT emissions
# ═══════════════════════════════════════════════════════════════════════

@test "policy-denies-violation emits ASSERTION_RESULT line on PASS" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd clusterpolicies"*) exit 0 ;;
  *"apply --dry-run=server"*"-f"*"test-violating"*) echo "denied"; exit 1 ;;
  *"apply --dry-run=server"*"-f"*"test-compliant"*) echo "created (server dry run)"; exit 0 ;;
  *"wait pod"*) exit 0 ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/pdv-ar-pass.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
}

@test "policy-denies-violation emits ASSERTION_RESULT line on FAIL" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get crd clusterpolicies"*) exit 0 ;;
  *"apply --dry-run=server"*"-f"*"test-violating"*) echo "created (server dry run)"; exit 0 ;;
  *"apply --dry-run=server"*"-f"*"test-compliant"*) echo "created (server dry run)"; exit 0 ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/pdv-ar-fail.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# L3 depth header + registry
# ═══════════════════════════════════════════════════════════════════════

@test "policy-denies-violation.sh carries # DEPTH: L3 header" {
  run grep '^# DEPTH: L3' "$ASSERTS_DIR/policy-denies-violation.sh"
  [ $status -eq 0 ]
}

@test "policy-denies-violation registry entry is L3" {
  local depth
  depth=$(yq '.policy-denies-violation' "$ASSERTS_DIR/registry.yaml")
  [ "$depth" = "L3" ]
}

# ═══════════════════════════════════════════════════════════════════════
# Generalization: no hardcoded consumer names
# ═══════════════════════════════════════════════════════════════════════

@test "policy-denies-violation.sh has no hardcoded 'sample' release name" {
  run grep -n 'sample\.test\.local\|:-sample\b\|RELEASE:-sample' "$ASSERTS_DIR/policy-denies-violation.sh"
  [ $status -ne 0 ]
}

@test "policy-denies-violation.sh uses parameterized RELEASE/NAMESPACE env" {
  local count
  count=$(grep -cE '\$\{?RELEASE\}?|\$\{?NS\}?|\$\{?NAMESPACE\}?' "$ASSERTS_DIR/policy-denies-violation.sh" 2>/dev/null)
  [ "${count:-0}" -gt 0 ]
}
