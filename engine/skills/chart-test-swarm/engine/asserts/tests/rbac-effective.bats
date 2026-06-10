#!/usr/bin/env bats
# rbac-effective.bats — Tests for the L3 behavioral assert rbac-effective.
# Covers FAIL paths (granted=no, denied=yes), SKIP (no ServiceAccount),
# PASS paths, and depth metadata.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
ASSERTS_DIR="$REPO_ROOT/engine/asserts"

setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/rbac-bats-XXXXXX)"
  STUB_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH:/opt/homebrew/bin:/usr/local/bin"
  export RELEASE="test-release"
  export NAMESPACE="test-ns"
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/rbac-dummy}" 2>/dev/null || true
}

run_assert() {
  run "$ASSERTS_DIR/rbac-effective.sh" "$1" "${2:-0}"
}

make_scenario() {
  local id="${1:-rbac-test}"
  cat <<EOF
id: ${id}
name: RBAC test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: rbac-effective
    namespace: test-ns
    service_account: test-release
    granted:
      - verb: get
        resource: pods
      - verb: list
        resource: services
    denied:
      - verb: delete
        resource: pods
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
# SKIP: ServiceAccount not found
# ═══════════════════════════════════════════════════════════════════════

@test "rbac-effective SKIPs when ServiceAccount does not exist" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get serviceaccount"*)
    echo "Error from server (NotFound): serviceaccounts \"test-release\" not found"
    exit 1
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/rbac-skip-nosa.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: SKIP"* ]]
  [[ "$output" == *"platform_capability_absent"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: granted verb returns "no" (binding ineffective)
# ═══════════════════════════════════════════════════════════════════════

@test "rbac-effective FAILs when a granted permission returns 'no'" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get serviceaccount test-release"*)
    echo "NAME            SECRETS   AGE"
    echo "test-release   0         12d"
    exit 0
    ;;
  *"auth can-i get pods"*)
    echo "no"
    exit 0
    ;;
  *"auth can-i list services"*)
    echo "yes"
    exit 0
    ;;
  *"auth can-i delete pods"*)
    echo "no"
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/rbac-fail-granted-no.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]] || [[ "$output" == *"binding ineffective"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: denied verb returns "yes" (over-grant)
# ═══════════════════════════════════════════════════════════════════════

@test "rbac-effective FAILs when a denied permission returns 'yes'" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get serviceaccount test-release"*)
    echo "test-release"
    exit 0
    ;;
  *"auth can-i get pods"*)
    echo "yes"
    exit 0
    ;;
  *"auth can-i list services"*)
    echo "yes"
    exit 0
    ;;
  *"auth can-i delete pods"*)
    echo "yes"
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/rbac-fail-denied-yes.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]] || [[ "$output" == *"over-granted"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# PASS: all granted=yes, all denied=no
# ═══════════════════════════════════════════════════════════════════════

@test "rbac-effective PASSes when all granted=yes and denied=no" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get serviceaccount test-release"*)
    echo "test-release"
    exit 0
    ;;
  *"auth can-i get pods"*)
    echo "yes"
    exit 0
    ;;
  *"auth can-i list services"*)
    echo "yes"
    exit 0
    ;;
  *"auth can-i delete pods"*)
    echo "no"
    exit 0
    ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/rbac-pass.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
  [[ "$output" == *"granted=yes"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: missing granted list
# ═══════════════════════════════════════════════════════════════════════

@test "rbac-effective FAILs when granted list is empty" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get serviceaccount test-release"*) echo "test-release"; exit 0 ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/rbac-fail-no-granted.yaml"
  cat <<EOF > "$s"
id: rbac-empty
name: RBAC empty
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: rbac-effective
    namespace: test-ns
    service_account: test-release
    granted: []
EOF

  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"granted"*"required"* ]] || [[ "$output" == *"FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# ASSERTION_RESULT emissions
# ═══════════════════════════════════════════════════════════════════════

@test "rbac-effective emits ASSERTION_RESULT line on PASS" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get serviceaccount test-release"*) echo "test-release"; exit 0 ;;
  *"auth can-i get pods"*) echo "yes"; exit 0 ;;
  *"auth can-i list services"*) echo "yes"; exit 0 ;;
  *"auth can-i delete pods"*) echo "no"; exit 0 ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/rbac-ar-pass.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
}

@test "rbac-effective emits ASSERTION_RESULT line on FAIL" {
  cat > "$STUB_BIN/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *"get serviceaccount test-release"*) echo "test-release"; exit 0 ;;
  *"auth can-i get pods"*) echo "no"; exit 0 ;;
  *"auth can-i list services"*) echo "yes"; exit 0 ;;
  *"auth can-i delete pods"*) echo "no"; exit 0 ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/rbac-ar-fail.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# L3 depth header + registry
# ═══════════════════════════════════════════════════════════════════════

@test "rbac-effective.sh carries # DEPTH: L3 header" {
  run grep '^# DEPTH: L3' "$ASSERTS_DIR/rbac-effective.sh"
  [ $status -eq 0 ]
}

@test "rbac-effective registry entry is L3" {
  local depth
  depth=$(yq '.rbac-effective' "$ASSERTS_DIR/registry.yaml")
  [ "$depth" = "L3" ]
}

# ═══════════════════════════════════════════════════════════════════════
# Generalization: no hardcoded consumer names
# ═══════════════════════════════════════════════════════════════════════

@test "rbac-effective.sh has no hardcoded 'sample' release name" {
  run grep -n 'sample\.test\.local\|:-sample\b\|RELEASE:-sample' "$ASSERTS_DIR/rbac-effective.sh"
  [ $status -ne 0 ]
}

@test "rbac-effective.sh uses parameterized RELEASE/NAMESPACE env" {
  local count
  count=$(grep -cE '\$\{?RELEASE\}?|\$\{?NS\}?|\$\{?NAMESPACE\}?' "$ASSERTS_DIR/rbac-effective.sh" 2>/dev/null)
  [ "${count:-0}" -gt 0 ]
}
