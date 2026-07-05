#!/usr/bin/env bats
# Tests for run-scenario.sh scenario-load validation of assert fields.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
RUN_SCENARIO="$REPO_ROOT/engine/scripts/run-scenario.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/scenario-load-validation-bats-XXXXXX)"
  STUB_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"

  cat > "$STUB_BIN/helm" <<'STUBEOF'
#!/usr/bin/env bash
echo "helm should not be called after scenario-load validation fails" >&2
exit 2
STUBEOF
  chmod +x "$STUB_BIN/helm"

  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "config" ] && [ "${2:-}" = "current-context" ]; then
  echo "test-context"
  exit 0
fi
echo "kubectl should not be called after scenario-load validation fails" >&2
exit 2
STUBEOF
  chmod +x "$STUB_BIN/kubectl"
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/scenario-load-validation-dummy}" 2>/dev/null || true
}

@test "run-scenario rejects assert selector metacharacters during scenario load" {
  local sentinel="$TEST_TMPDIR/selector-injection-ran"
  local s="$TEST_TMPDIR/invalid-selector.yaml"

  cat > "$s" <<EOF
id: invalid-selector
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
    selector: "app=demo\"; touch \"$sentinel\"; #"
    timeout: 1s
    retries: 0
EOF

  run env PATH="$STUB_BIN:$PATH" \
    CLUSTER_NAME="chart-test-swarm-validation" \
    REPORTS_DIR="$TEST_TMPDIR/reports" \
    "$RUN_SCENARIO" "$s"

  [ $status -ne 0 ]
  [[ "$output" == *"asserts[0].selector"* ]]
  [[ "$output" == *"disallowed characters"* ]]
  [ ! -e "$sentinel" ]
  [ ! -d "$TEST_TMPDIR/reports" ]
}

@test "run-scenario rejects product release metacharacters during scenario load" {
  local s="$TEST_TMPDIR/invalid-release.yaml"

  cat > "$s" <<'EOF'
id: invalid-release
cluster:
  provider: kind
product:
  chart: chart
  release: 'test-release$(touch /tmp/should-not-run)'
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
    timeout: 1s
    retries: 0
EOF

  run env PATH="$STUB_BIN:$PATH" \
    CLUSTER_NAME="chart-test-swarm-validation" \
    REPORTS_DIR="$TEST_TMPDIR/reports" \
    "$RUN_SCENARIO" "$s"

  [ $status -ne 0 ]
  [[ "$output" == *"product.release"* ]]
  [[ "$output" == *"disallowed characters"* ]]
  [ ! -d "$TEST_TMPDIR/reports" ]
}
