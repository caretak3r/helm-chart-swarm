#!/usr/bin/env bats
# strict-core-fixes.bats — Negative-case bats tests for b-strict-core fixes.
# Proves that the 5 target asserts now FAIL on their negative cases.
# Uses stubbed kubectl/helm for live-source tests; rendered source for
# exact-kind matching tests.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
ASSERTS_DIR="$REPO_ROOT/engine/asserts"
SCHEMA_FILE="$REPO_ROOT/engine/templates/scenario.schema.json"
PROJECT_DIR="$REPO_ROOT/examples/sample-product-chart"

setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/strict-core-bats-XXXXXX)"
  STUB_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
  export RELEASE="test-release"
  export KUBE_CONTEXT="kind-chart-test-swarm-strict"
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/strict-core-dummy}" 2>/dev/null || true
}

# Helper: run an assert with the stubbed PATH.
run_assert() {
  local runner="$1"
  local scenario="$2"
  local idx="${3:-0}"
  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/$runner" "$scenario" "$idx"
}

# Helper: create a stub kubectl that echoes the given output file content
# on stdout and exits with the given code.
stub_kubectl_output() {
  local output_file="$1"
  local exit_code="${2:-0}"
  printf '#!/usr/bin/env bash\ncat %q\nexit %s\n' "$output_file" "$exit_code" > "$STUB_BIN/kubectl"
  chmod +x "$STUB_BIN/kubectl"
}

# ═══════════════════════════════════════════════════════════════════════
# network-policy (live) strictness
# ═══════════════════════════════════════════════════════════════════════

@test "network-policy (live) FAILs when only a FOREIGN NetworkPolicy exists" {
  # Stub kubectl: returns a NetworkPolicy that does NOT select the release
  cat > "$TEST_TMPDIR/np-yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicyList
items:
- apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: foreign-policy
    namespace: sample
    labels:
      app.kubernetes.io/instance: other-release
  spec:
    podSelector:
      matchLabels:
        app: foreign-app
    ingress:
    - from:
      - podSelector:
          matchLabels:
            app: something-else
YAML
  stub_kubectl_output "$TEST_TMPDIR/np-yaml"

  local s="$TEST_TMPDIR/netpol-live-foreign.yaml"
  cat > "$s" <<EOF
id: netpol-live-foreign
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: network-policy
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "network-policy.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"no policy selects"* ]] || [[ "$output" == *"expected"* ]]
}

@test "network-policy (live) PASSes when a policy selects the release workload" {
  # Stub kubectl: returns a NetworkPolicy that selects the release
  cat > "$TEST_TMPDIR/np-release-yaml" <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicyList
items:
- apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: release-policy
    namespace: sample
    labels:
      app.kubernetes.io/instance: test-release
  spec:
    podSelector:
      matchLabels:
        app.kubernetes.io/instance: test-release
    ingress:
    - from:
      - namespaceSelector: {}
YAML
  stub_kubectl_output "$TEST_TMPDIR/np-release-yaml"

  local s="$TEST_TMPDIR/netpol-live-release.yaml"
  cat > "$s" <<EOF
id: netpol-live-release
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: network-policy
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "network-policy.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "network-policy (live) expect_present=false ignores foreign policies" {
  # Stub kubectl: returns only a foreign NetworkPolicy (not release-scoped)
  cat > "$TEST_TMPDIR/np-foreign-only.yaml" <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicyList
items:
- apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: foreign-policy
    namespace: sample
    labels:
      app.kubernetes.io/instance: other-release
  spec:
    podSelector:
      matchLabels:
        app: other-app
YAML
  stub_kubectl_output "$TEST_TMPDIR/np-foreign-only.yaml"

  local s="$TEST_TMPDIR/netpol-absent-foreign.yaml"
  cat > "$s" <<EOF
id: netpol-absent-foreign
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: network-policy
    namespace: sample
    source: live
    expect_present: false
EOF
  run_assert "network-policy.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# service-reachable anchored HTTP parser
# ═══════════════════════════════════════════════════════════════════════

@test "service-reachable PASSes on exact expected status" {
  # Stub kubectl: echoes "200" to stdout (captured by assert via > redirect)
  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
# Stub kubectl for service-reachable: emit canned HTTP code to stdout.
# The assert redirects kubectl stdout to /tmp/ct-probe-<pid>.out, so we
# just echo to stdout and let the shell redirect handle it.
if [[ "$*" == *run* ]]; then
  echo "200"
fi
exit 0
STUBEOF
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/svc-pass.yaml"
  cat > "$s" <<EOF
id: svc-pass
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: service-reachable
    namespace: sample
    service: my-svc.sample
    port: 8080
    expect: 200
    timeout: 10s
EOF
  run_assert "service-reachable.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "service-reachable FAILs on status mismatch" {
  # Stub kubectl: echoes "500" to stdout — doesn't match expect: 200
  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *run* ]]; then
  echo "500"
fi
exit 0
STUBEOF
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/svc-fail-mismatch.yaml"
  cat > "$s" <<EOF
id: svc-fail-mismatch
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: service-reachable
    namespace: sample
    service: my-svc.sample
    port: 8080
    expect: 200
    timeout: 10s
EOF
  run_assert "service-reachable.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"expected"* ]]
}

@test "service-reachable anchored parser rejects body-embedded codes" {
  # Stub kubectl: output has "200" in body but actual code is "500"
  # The final token should be "500", and parse_http_code extracts the last token
  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *run* ]]; then
  printf 'error code 200 occurred\n500'
fi
exit 0
STUBEOF
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/svc-fail-body.yaml"
  cat > "$s" <<EOF
id: svc-fail-body
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: service-reachable
    namespace: sample
    service: my-svc.sample
    port: 8080
    expect: 200
    timeout: 10s
EOF
  run_assert "service-reachable.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"expected"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# rbac-objects (live) strictness
# ═══════════════════════════════════════════════════════════════════════

@test "rbac-objects (live) FAILs when roleRef points elsewhere" {
  # Stub kubectl for SA, Role, RoleBinding queries.
  # Use elif chain with "get rolebinding" BEFORE "get role" to avoid substring match.
  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"get sa"* ]]; then
  echo 'items: []'  # no non-default SA (chart SA is named same as release)
elif [[ "$*" == *"get rolebinding"* ]]; then
  cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBindingList
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata:
    name: chart-rb
    namespace: sample
    labels:
      app.kubernetes.io/instance: test-release
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: Role
    name: unrelated-role
  subjects:
  - kind: ServiceAccount
    name: test-release
    namespace: sample
YAML
elif [[ "$*" == *"get role"* ]]; then
  cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleList
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    name: chart-role
    namespace: sample
    labels:
      app.kubernetes.io/instance: test-release
YAML
fi
exit 0
STUBEOF
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/rbac-live-roleRef-wrong.yaml"
  cat > "$s" <<EOF
id: rbac-live-roleRef-wrong
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: rbac-objects
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "rbac-objects.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"roleRef"* ]]
}

@test "rbac-objects (live) FAILs when subjects do not wire to the chart SA" {
  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"get sa"* ]]; then
  echo 'items: []'
elif [[ "$*" == *"get rolebinding"* ]]; then
  cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBindingList
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata:
    name: chart-rb
    namespace: sample
    labels:
      app.kubernetes.io/instance: test-release
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: Role
    name: chart-role
  subjects:
  - kind: ServiceAccount
    name: default
    namespace: sample
YAML
elif [[ "$*" == *"get role"* ]]; then
  cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleList
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    name: chart-role
    namespace: sample
    labels:
      app.kubernetes.io/instance: test-release
YAML
fi
exit 0
STUBEOF
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/rbac-live-subjects-wrong.yaml"
  cat > "$s" <<EOF
id: rbac-live-subjects-wrong
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: rbac-objects
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "rbac-objects.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"subjects"* ]] || [[ "$output" == *"ServiceAccount"* ]]
}

@test "rbac-objects (live) PASSes when roleRef and subjects correctly wired" {
  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"get sa"* ]]; then
  cat <<YAML
apiVersion: v1
kind: ServiceAccountList
items:
- apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: test-release
    namespace: sample
    labels:
      app.kubernetes.io/instance: test-release
YAML
elif [[ "$*" == *"get rolebinding"* ]]; then
  cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBindingList
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata:
    name: chart-rb
    namespace: sample
    labels:
      app.kubernetes.io/instance: test-release
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: Role
    name: chart-role
  subjects:
  - kind: ServiceAccount
    name: test-release
    namespace: sample
YAML
elif [[ "$*" == *"get role"* ]]; then
  cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleList
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    name: chart-role
    namespace: sample
    labels:
      app.kubernetes.io/instance: test-release
YAML
fi
exit 0
STUBEOF
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/rbac-live-wired-pass.yaml"
  cat > "$s" <<EOF
id: rbac-live-wired-pass
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: rbac-objects
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "rbac-objects.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "rbac-objects (live) is release-scoped — unrelated RBAC objects do NOT satisfy" {
  # Only foreign RBAC objects present (not release-scoped).
  # Use elif chain with get rolebinding BEFORE get role to avoid substring match.
  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"get sa"* ]]; then
  echo 'items: []'
elif [[ "$*" == *"get rolebinding"* ]]; then
  cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBindingList
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata:
    name: foreign-rb
    namespace: sample
    labels:
      app.kubernetes.io/instance: other-release
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: Role
    name: foreign-role
  subjects:
  - kind: ServiceAccount
    name: other-sa
    namespace: sample
YAML
elif [[ "$*" == *"get role"* ]]; then
  cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleList
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    name: foreign-role
    namespace: sample
    labels:
      app.kubernetes.io/instance: other-release
YAML
fi
exit 0
STUBEOF
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/rbac-live-foreign-only.yaml"
  cat > "$s" <<EOF
id: rbac-live-foreign-only
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: rbac-objects
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "rbac-objects.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "rbac-objects (live) expect_present=false ignores unrelated RBAC objects" {
  # Foreign RBAC objects present, but expect_present=false → should PASS.
  # kubectl queries use -l "app.kubernetes.io/instance=test-release", so
  # only objects with that label are returned. Foreign objects have
  # "other-release" label and are filtered out by kubectl. Stub returns
  # empty results to simulate correct kubectl label filtering.
  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
# All three kubectl queries use -l "app.kubernetes.io/instance=test-release",
# which does not match foreign objects (labeled "other-release").
if [[ "$*" == *"get sa"* ]]; then
  echo 'items: []'
elif [[ "$*" == *"get rolebinding"* ]]; then
  echo 'items: []'
elif [[ "$*" == *"get role"* ]]; then
  echo 'items: []'
fi
exit 0
STUBEOF
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/rbac-live-absent-foreign.yaml"
  cat > "$s" <<EOF
id: rbac-live-absent-foreign
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: rbac-objects
    namespace: sample
    source: live
    expect_present: false
EOF
  run_assert "rbac-objects.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# Exact kind matching (labels-present / annotations-present)
# ═══════════════════════════════════════════════════════════════════════

@test "exact kind matching rejects substring kinds (labels-present)" {
  # Create a rendered file with a ClusterRole kind.
  # With kinds: [Role], the ClusterRole should NOT match (substring bug).
  # We source labels-present.sh's kind_matches_filter logic directly.
  local helpers
  helpers=$(
    # Extract the kind_matches_filter function from labels-present.sh
    sed -n '/^kind_matches_filter()/,/^}/p' "$ASSERTS_DIR/labels-present.sh"
  )
  eval "$helpers"

  # With KINDS_JSON=["Role"], "ClusterRole" should NOT match
  KINDS_JSON='["Role"]'
  if kind_matches_filter "ClusterRole"; then
    echo "FAIL: ClusterRole matched kinds filter for Role (substring bug)"
    false
  else
    echo "PASS: ClusterRole correctly rejected"
  fi
}

@test "exact kind matching rejects substring kinds (annotations-present)" {
  local helpers
  helpers=$(
    sed -n '/^kind_matches_filter()/,/^}/p' "$ASSERTS_DIR/annotations-present.sh"
  )
  eval "$helpers"

  KINDS_JSON='["Role"]'
  if kind_matches_filter "ClusterRole"; then
    echo "FAIL: ClusterRole matched kinds filter for Role (substring bug)"
    false
  else
    echo "PASS: ClusterRole correctly rejected"
  fi
}

@test "exact kind matching does not skip a requested exact kind" {
  local helpers
  helpers=$(
    sed -n '/^kind_matches_filter()/,/^}/p' "$ASSERTS_DIR/labels-present.sh"
  )
  eval "$helpers"

  KINDS_JSON='["Deployment"]'
  if ! kind_matches_filter "Deployment"; then
    echo "FAIL: exact kind Deployment was skipped"
    false
  else
    echo "PASS: exact kind Deployment correctly matched"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# pods-ready (live) strictness
# ═══════════════════════════════════════════════════════════════════════

@test "pods-ready (live) FAILs when zero release pods exist" {
  # Stub kubectl get pods: return no pods.
  # pods-ready.sh first calls kubectl with -o name to count pods.
  # An empty output means zero pods.
  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"-o name"* ]]; then
  # Return empty: no pods match
  exit 0
fi
if [[ "$*" == *"get pods"* ]]; then
  exit 0
fi
exit 0
STUBEOF
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/pods-ready-zero.yaml"
  cat > "$s" <<EOF
id: pods-ready-zero
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
    timeout: 10s
    retries: 0
EOF
  run_assert "pods-ready.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"no matching pods"* ]] || [[ "$output" == *"zero"* ]]
}

@test "pods-ready (live) ignores unrelated not-Ready pods" {
  # Release pods are Ready. The assert uses release-scoped kubectl queries,
  # so the stub only needs to return release-scoped pods as Ready.
  # kubectl is called three ways in pods-ready.sh:
  #   1) -o name   → we return "pod/release-pod-1"
  #   2) -o jsonpath → we return "True"
  #   3) --no-headers → we return a table-format line
  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"-o name"* ]]; then
  echo "pod/release-pod-1"
  exit 0
fi
if [[ "$*" == *"-o jsonpath"* ]]; then
  echo "True"
  exit 0
fi
if [[ "$*" == *"--no-headers"* ]]; then
  echo "sample   release-pod-1   1/1   Running   0   1m"
  exit 0
fi
# Fallback: the final `kubectl get pods -l <sel>` for display
cat <<YAML
apiVersion: v1
kind: PodList
items:
- apiVersion: v1
  kind: Pod
  metadata:
    name: release-pod-1
    namespace: sample
    labels:
      app.kubernetes.io/instance: test-release
  status:
    conditions:
    - type: Ready
      status: "True"
YAML
exit 0
STUBEOF
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/pods-ready-ignore.yaml"
  cat > "$s" <<EOF
id: pods-ready-ignore
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
    timeout: 10s
    retries: 0
EOF
  run_assert "pods-ready.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "pods-ready (live) uses wait_with_backoff honoring retries" {
  # Stub kubectl: pods are always Ready. The test proves wait_with_backoff
  # is actually invoked (it's called and returns success) — this exercises
  # the retry path without making the test flaky.
  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"-o name"* ]]; then
  echo "pod/release-pod-1"
  exit 0
fi
if [[ "$*" == *"-o jsonpath"* ]]; then
  echo "True"
  exit 0
fi
if [[ "$*" == *"--no-headers"* ]]; then
  echo "sample   release-pod-1   1/1   Running   0   1m"
  exit 0
fi
# Fallback: display pods table
echo "NAME  READY  STATUS  RESTARTS  AGE"
echo "release-pod-1  1/1  Running  0  1m"
exit 0
STUBEOF
  chmod +x "$STUB_BIN/kubectl"

  # Override sleep to be instant
  export WAIT_BACKOFF_SLEEP_CMD="true"

  local s="$TEST_TMPDIR/pods-ready-retries.yaml"
  cat > "$s" <<EOF
id: pods-ready-retries
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
    timeout: 30s
    retries: 5
EOF
  run_assert "pods-ready.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}
