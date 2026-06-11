#!/usr/bin/env bats
# scheduled-on-target.bats — Tests for the L3 behavioral assert
# scheduled-on-target. Covers FAIL paths (pod on wrong node, pod Pending),
# SKIP (no pods, no scheduling config), PASS paths, and depth metadata.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
ASSERTS_DIR="$REPO_ROOT/engine/asserts"

setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/sot-bats-XXXXXX)"
  STUB_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH:/opt/homebrew/bin:/usr/local/bin"
  export RELEASE="test-release"
  export NAMESPACE="test-ns"
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/sot-dummy}" 2>/dev/null || true
}

run_assert() {
  run "$ASSERTS_DIR/scheduled-on-target.sh" "$1" "${2:-0}"
}

make_scenario() {
  local id="${1:-sot-test}"
  local target_label="${2:-node-role.kubernetes.io/worker=}"
  cat <<EOF
id: ${id}
name: SOT test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: scheduled-on-target
    namespace: test-ns
    target_label: "${target_label}"
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
# SKIP: no pods found
# ═══════════════════════════════════════════════════════════════════════

@test "scheduled-on-target SKIPs when no release pods exist" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get pods -l app.kubernetes.io/instance=test-release"*)
    echo '{"items":[]}'
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/sot-skip-nopods.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: SKIP"* ]]
  [[ "$output" == *"platform_capability_absent"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: pod is Pending
# ═══════════════════════════════════════════════════════════════════════

@test "scheduled-on-target FAILs when a pod is Pending" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get pods -l app.kubernetes.io/instance=test-release"*)
    echo '{"items":[{"metadata":{"name":"test-pod-1"},"status":{"phase":"Pending"},"spec":{"nodeName":null}}]}'
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/sot-fail-pending.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]] || [[ "$output" == *"Pending"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: pod on non-target node (wrong label)
# ═══════════════════════════════════════════════════════════════════════

@test "scheduled-on-target FAILs when pod is on a non-target node (dot-key)" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get pods -l"*)
    echo '{"items":[{"metadata":{"name":"test-pod-1"},"status":{"phase":"Running"},"spec":{"nodeName":"worker-1"}}]}'
    exit 0
    ;;
  *"get node worker-1"*"-o json"*)
    echo '{"metadata":{"labels":{"other-label":"value"}}}'
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/sot-fail-wrong-node.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]] || [[ "$output" == *"does NOT have label"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: pod on node with wrong label value
# ═══════════════════════════════════════════════════════════════════════

@test "scheduled-on-target FAILs when node label value mismatches" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get pods -l"*)
    echo '{"items":[{"metadata":{"name":"test-pod-1"},"status":{"phase":"Running"},"spec":{"nodeName":"worker-1"}}]}'
    exit 0
    ;;
  *"get node worker-1"*"-o json"*)
    echo '{"metadata":{"labels":{"disktype":"hdd"}}}'
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/sot-fail-wrong-value.yaml"
  make_scenario "sot-value" "disktype=ssd" > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]] || [[ "$output" == *"expected:"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# PASS: all pods on target nodes
# ═══════════════════════════════════════════════════════════════════════

@test "scheduled-on-target PASSes when all pods are on target nodes" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get pods -l"*)
    echo '{"items":[{"metadata":{"name":"test-pod-1"},"status":{"phase":"Running"},"spec":{"nodeName":"worker-1"}},{"metadata":{"name":"test-pod-2"},"status":{"phase":"Running"},"spec":{"nodeName":"worker-2"}}]}'
    exit 0
    ;;
  *"get node worker-1"*"-o json"*)
    echo '{"metadata":{"labels":{"disktype":"ssd"}}}'
    exit 0
    ;;
  *"get node worker-2"*"-o json"*)
    echo '{"metadata":{"labels":{"disktype":"ssd"}}}'
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/sot-pass.yaml"
  make_scenario "sot-pass" "disktype=ssd" > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
  [[ "$output" == *"on target nodes"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: no .spec.nodeName (null)
# ═══════════════════════════════════════════════════════════════════════

@test "scheduled-on-target FAILs when pod has no nodeName" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get pods -l"*)
    echo '{"items":[{"metadata":{"name":"test-pod-1"},"status":{"phase":"Running"},"spec":{}}]}'
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/sot-fail-no-nodename.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]] || [[ "$output" == *"not scheduled"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# ASSERTION_RESULT emissions
# ═══════════════════════════════════════════════════════════════════════

@test "scheduled-on-target emits ASSERTION_RESULT line on PASS" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get pods -l"*)
    echo '{"items":[{"metadata":{"name":"p1"},"status":{"phase":"Running"},"spec":{"nodeName":"w1"}}]}'
    exit 0
    ;;
  *"get node w1"*"-o json"*)
    echo '{"metadata":{"labels":{"disktype":"ssd"}}}'
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/sot-ar-pass.yaml"
  make_scenario "sot-ar-pass" "disktype=ssd" > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
}

@test "scheduled-on-target emits ASSERTION_RESULT line on FAIL" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get pods -l"*)
    echo '{"items":[{"metadata":{"name":"p1"},"status":{"phase":"Pending"},"spec":{"nodeName":null}}]}'
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/sot-ar-fail.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# L3 depth header + registry
# ═══════════════════════════════════════════════════════════════════════

@test "scheduled-on-target.sh carries # DEPTH: L3 header" {
  run grep '^# DEPTH: L3' "$ASSERTS_DIR/scheduled-on-target.sh"
  [ $status -eq 0 ]
}

@test "scheduled-on-target registry entry is L3" {
  local depth
  depth=$(yq '.scheduled-on-target' "$ASSERTS_DIR/registry.yaml")
  [ "$depth" = "L3" ]
}

# ═══════════════════════════════════════════════════════════════════════
# PASS: dot/slash label key (Issue 5 — JSONPath safe via jq)
# ═══════════════════════════════════════════════════════════════════════

@test "scheduled-on-target PASSes with dot-key label (node-role.kubernetes.io/control-plane=)" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get pods -l"*)
    echo '{"items":[{"metadata":{"name":"p1"},"status":{"phase":"Running"},"spec":{"nodeName":"cp-1"}}]}'
    exit 0
    ;;
  *"get node cp-1"*"-o json"*)
    echo '{"metadata":{"labels":{"node-role.kubernetes.io/control-plane":""}}}'
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/sot-pass-dotkey.yaml"
  make_scenario "sot-dotkey" "node-role.kubernetes.io/control-plane=" > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
  [[ "$output" == *"on target nodes"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# Generalization: no hardcoded consumer names
# ═══════════════════════════════════════════════════════════════════════

@test "scheduled-on-target.sh has no hardcoded 'sample' release name" {
  run grep -n 'sample\.test\.local\|:-sample\b\|RELEASE:-sample' "$ASSERTS_DIR/scheduled-on-target.sh"
  [ $status -ne 0 ]
}

@test "scheduled-on-target.sh uses parameterized RELEASE/NAMESPACE env" {
  local count
  count=$(grep -cE '\$\{?RELEASE\}?|\$\{?NS\}?|\$\{?NAMESPACE\}?' "$ASSERTS_DIR/scheduled-on-target.sh" 2>/dev/null)
  [ "${count:-0}" -gt 0 ]
}
