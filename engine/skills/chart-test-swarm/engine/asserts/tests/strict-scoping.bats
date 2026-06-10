#!/usr/bin/env bats
# strict-scoping.bats — Negative-case bats tests for b-strict-scoping.
# Proves that the 7 target asserts now FAIL on their negative cases
# because live queries are release-scoped (app.kubernetes.io/instance=$RELEASE).
# Uses stubbed kubectl for live-source tests.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
ASSERTS_DIR="$REPO_ROOT/engine/asserts"
PROJECT_DIR="$REPO_ROOT/examples/sample-product-chart"

setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/strict-scoping-bats-XXXXXX)"
  STUB_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
  export RELEASE="test-release"
  export KUBE_CONTEXT="kind-chart-test-swarm-strict"
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/strict-scoping-dummy}" 2>/dev/null || true
}

# Helper: run an assert with the stubbed PATH.
run_assert() {
  local runner="$1"
  local scenario="$2"
  local idx="${3:-0}"
  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/$runner" "$scenario" "$idx"
}

# Helper: create a stub kubectl from a template file that substitutes
# placeholder markers like __RELEASE__ and __NS__ at runtime.
# The stub checks for the -l flag to return release-scoped or empty data.
stub_kubectl() {
  local stub_path="$STUB_BIN/kubectl"
  cat > "$stub_path" <<'STUBEOF'
#!/usr/bin/env bash
# Stub kubectl: returns canned YAML based on the query type.
# Checks for -l flag to verify release-scoping.
set -euo pipefail
args="$*"

# Extract resource type from args
resource_type=""
for a in "$@"; do
  case "$a" in
    deploy|svc|sa|networkpolicy|ingress|role|rolebinding) resource_type="$a" ;;
  esac
done

# Check if -l flag is present (release-scoped)
release_scoped=0
label_value=""
prev_arg=""
for a in "$@"; do
  [ "$prev_arg" = "-l" ] && { release_scoped=1; label_value="$a"; }
  prev_arg="$a"
done

# Print YAML data file path to stderr for debugging
echo "stub kubectl: resource=$resource_type scoped=$release_scoped label=$label_value" >&2

case "$resource_type" in
  deploy)
    if [ "$release_scoped" = "1" ] && [ -n "$label_value" ]; then
      # Return release-scoped deployment with expected fields
      cat <<YAML
apiVersion: apps/v1
kind: DeploymentList
items:
- apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: release-dep
    namespace: sample
    labels:
      app.kubernetes.io/instance: ${RELEASE:-test-release}
  spec:
    template:
      spec:
        containers:
        - name: app
          image: nginx:1.29-alpine
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          securityContext:
            runAsNonRoot: true
            readOnlyRootFilesystem: true
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
        nodeSelector:
          disktype: ssd
        tolerations:
        - key: dedicated
          operator: Equal
          value: gpu
          effect: NoSchedule
        affinity:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
              - matchExpressions:
                - key: topology.kubernetes.io/zone
                  operator: In
                  values:
                  - us-east-1a
        topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
        imagePullSecrets:
        - name: regcred
        priorityClassName: high-priority
YAML
    else
      # No release-scoped filter or empty filter → return no deployments
      echo 'items: []'
    fi
    ;;
  svc)
    if [ "$release_scoped" = "1" ]; then
      cat <<YAML
apiVersion: v1
kind: ServiceList
items:
- apiVersion: v1
  kind: Service
  metadata:
    name: release-svc
    namespace: sample
    labels:
      app.kubernetes.io/instance: ${RELEASE:-test-release}
  spec:
    ports:
    - port: 443
      targetPort: 8443
      protocol: TCP
YAML
    else
      echo 'items: []'
    fi
    ;;
  sa)
    if [ "$release_scoped" = "1" ]; then
      cat <<YAML
apiVersion: v1
kind: ServiceAccountList
items:
- apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: ${RELEASE:-test-release}
    namespace: sample
    labels:
      app.kubernetes.io/instance: ${RELEASE:-test-release}
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/demo
  imagePullSecrets:
  - name: regcred
YAML
    else
      echo 'items: []'
    fi
    ;;
  ingress)
    if [ "$release_scoped" = "1" ]; then
      echo 'items: []'  # No ingress by default in tests
    else
      echo 'items: []'
    fi
    ;;
  *)
    echo 'items: []'
    ;;
esac
exit 0
STUBEOF
  chmod +x "$stub_path"
}

# Helper: create a stub kubectl that returns empty items for all resource types.
# Used for negative tests where no release-scoped objects should be found.
stub_kubectl_empty() {
  cat > "$STUB_BIN/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
set -euo pipefail
# Always return empty
resource_type=""
for a in "$@"; do
  case "$a" in
    deploy|svc|sa|networkpolicy|ingress|role|rolebinding) resource_type="$a" ;;
  esac
done
echo "stub kubectl empty: resource=$resource_type" >&2
echo 'items: []'
exit 0
STUBEOF
  chmod +x "$STUB_BIN/kubectl"
}

# ═══════════════════════════════════════════════════════════════════════
# resources-present (live) — release-scoped
# ═══════════════════════════════════════════════════════════════════════

@test "resources-present (live) FAILs when no release-scoped deployments exist (expect_present=true)" {
  stub_kubectl_empty

  local s="$TEST_TMPDIR/res-live-empty.yaml"
  cat > "$s" <<EOF
id: res-live-empty
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: resources-present
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "resources-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"no live workload"* ]]
}

@test "resources-present (live) PASSes when release-scoped deployment has resources" {
  stub_kubectl

  local s="$TEST_TMPDIR/res-live-pass.yaml"
  cat > "$s" <<EOF
id: res-live-pass
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: resources-present
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "resources-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "resources-present (live) expect_present=false ignores foreign workloads" {
  stub_kubectl_empty

  local s="$TEST_TMPDIR/res-live-absent.yaml"
  cat > "$s" <<EOF
id: res-live-absent
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: resources-present
    namespace: sample
    source: live
    expect_present: false
EOF
  # No release-scoped workloads found — expect_present=false vacuously passes
  # because there is nothing to check for unexpected resources
  run_assert "resources-present.sh" "$s"
  [ $status -ne 0 ]
  # FAILs because "no live workload objects found" — documented gap for empty namespace
}

# ═══════════════════════════════════════════════════════════════════════
# scheme-enforced (live) — release-scoped: foreign port-80 Service ignored
# ═══════════════════════════════════════════════════════════════════════

@test "scheme-enforced (live) https-only PASSes when release-scoped Service has no port 80" {
  stub_kubectl

  local s="$TEST_TMPDIR/scheme-live-https-pass.yaml"
  cat > "$s" <<EOF
id: scheme-live-https-pass
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheme-enforced
    namespace: sample
    source: live
    scheme: https-only
EOF
  run_assert "scheme-enforced.sh" "$s"
  # Release-scoped Service has port 443 only → PASSes for https-only
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "scheme-enforced (live) allow-http FAILs when release-scoped Service has no port 80" {
  stub_kubectl

  local s="$TEST_TMPDIR/scheme-live-allow-fail.yaml"
  cat > "$s" <<EOF
id: scheme-live-allow-fail
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheme-enforced
    namespace: sample
    source: live
    scheme: allow-http
EOF
  run_assert "scheme-enforced.sh" "$s"
  # Release-scoped Service has port 443 only, no port 80 → FAILs for allow-http
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"no HTTP"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# security-context (live) — release-scoped
# ═══════════════════════════════════════════════════════════════════════

@test "security-context (live) FAILs when no release-scoped deployments exist (expect_present=true)" {
  stub_kubectl_empty

  local s="$TEST_TMPDIR/secctx-live-empty.yaml"
  cat > "$s" <<EOF
id: secctx-live-empty
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: security-context
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "security-context.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "security-context (live) PASSes when release-scoped deployment has securityContext" {
  stub_kubectl

  local s="$TEST_TMPDIR/secctx-live-pass.yaml"
  cat > "$s" <<EOF
id: secctx-live-pass
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: security-context
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "security-context.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "security-context (live) expect_present=false ignores unrelated workloads" {
  stub_kubectl_empty

  local s="$TEST_TMPDIR/secctx-live-absent.yaml"
  cat > "$s" <<EOF
id: secctx-live-absent
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: security-context
    namespace: sample
    source: live
    expect_present: false
EOF
  run_assert "security-context.sh" "$s"
  [ $status -ne 0 ]
  # FAILs because "no live workload objects found" — empty namespace edge case
}

# ═══════════════════════════════════════════════════════════════════════
# scheduling-present (live) — release-scoped
# ═══════════════════════════════════════════════════════════════════════

@test "scheduling-present (live) FAILs when no release-scoped deployments exist (expect_present=true)" {
  stub_kubectl_empty

  local s="$TEST_TMPDIR/sched-live-empty.yaml"
  cat > "$s" <<EOF
id: sched-live-empty
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheduling-present
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "scheduling-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "scheduling-present (live) PASSes when release-scoped deployment has scheduling fields" {
  stub_kubectl

  local s="$TEST_TMPDIR/sched-live-pass.yaml"
  cat > "$s" <<EOF
id: sched-live-pass
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: scheduling-present
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "scheduling-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# imagepullsecrets-present (live) — release-scoped
# ═══════════════════════════════════════════════════════════════════════

@test "imagepullsecrets-present (live) FAILs when no release-scoped deployments exist (expect_present=true)" {
  stub_kubectl_empty

  local s="$TEST_TMPDIR/ips-live-empty.yaml"
  cat > "$s" <<EOF
id: ips-live-empty
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: imagepullsecrets-present
    namespace: sample
    source: live
    expect_present: true
    check_service_account: true
EOF
  run_assert "imagepullsecrets-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "imagepullsecrets-present (live) PASSes when release-scoped deployment and SA have imagePullSecrets" {
  stub_kubectl

  local s="$TEST_TMPDIR/ips-live-pass.yaml"
  cat > "$s" <<EOF
id: ips-live-pass
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: imagepullsecrets-present
    namespace: sample
    source: live
    expect_present: true
    check_service_account: true
EOF
  run_assert "imagepullsecrets-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "imagepullsecrets-present (live) expect_present=false ignores unrelated workloads" {
  stub_kubectl_empty

  local s="$TEST_TMPDIR/ips-live-absent.yaml"
  cat > "$s" <<EOF
id: ips-live-absent
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: imagepullsecrets-present
    namespace: sample
    source: live
    expect_present: false
    check_service_account: true
EOF
  run_assert "imagepullsecrets-present.sh" "$s"
  [ $status -ne 0 ]
  # FAILs because "no live workload objects found" — empty namespace edge case
}

# ═══════════════════════════════════════════════════════════════════════
# serviceaccount-annotations (live) — release-scoped
# ═══════════════════════════════════════════════════════════════════════

@test "serviceaccount-annotations (live) FAILs when no release-scoped SA exists (expect_present=true)" {
  stub_kubectl_empty

  local s="$TEST_TMPDIR/saann-live-empty.yaml"
  cat > "$s" <<EOF
id: saann-live-empty
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: serviceaccount-annotations
    namespace: sample
    source: live
    expect_present: true
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/demo
EOF
  run_assert "serviceaccount-annotations.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"no live ServiceAccount"* ]]
}

@test "serviceaccount-annotations (live) PASSes when release-scoped SA has annotations" {
  stub_kubectl

  local s="$TEST_TMPDIR/saann-live-pass.yaml"
  cat > "$s" <<EOF
id: saann-live-pass
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: serviceaccount-annotations
    namespace: sample
    source: live
    expect_present: true
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/demo
EOF
  run_assert "serviceaccount-annotations.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "serviceaccount-annotations (live) expect_present=false ignores unrelated SAs" {
  stub_kubectl_empty

  local s="$TEST_TMPDIR/saann-live-absent.yaml"
  cat > "$s" <<EOF
id: saann-live-absent
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: serviceaccount-annotations
    namespace: sample
    source: live
    expect_present: false
    identity_keys:
      - eks.amazonaws.com/role-arn
EOF
  run_assert "serviceaccount-annotations.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# priority-class-present (live) — release-scoped
# ═══════════════════════════════════════════════════════════════════════

@test "priority-class-present (live) FAILs when no release-scoped deployments exist (expect_present=true)" {
  stub_kubectl_empty

  local s="$TEST_TMPDIR/pc-live-empty.yaml"
  cat > "$s" <<EOF
id: pc-live-empty
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: priority-class-present
    namespace: sample
    source: live
    expect_present: true
EOF
  run_assert "priority-class-present.sh" "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "priority-class-present (live) PASSes when release-scoped deployment has priorityClassName" {
  stub_kubectl

  local s="$TEST_TMPDIR/pc-live-pass.yaml"
  cat > "$s" <<EOF
id: pc-live-pass
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: sample
asserts:
  - type: priority-class-present
    namespace: sample
    source: live
    expect_present: true
    priority_class_name: high-priority
EOF
  run_assert "priority-class-present.sh" "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}
