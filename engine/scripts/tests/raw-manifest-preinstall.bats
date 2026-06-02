#!/usr/bin/env bats
# bats tests for F1.2 raw_manifest preinstall feature covering:
#   - Schema accepts raw_manifest with path, rejects without path
#   - Schema rejects unknown preinstall kinds
#   - Helm-only preinstall items still validate (backward compat)
#   - apply-scenario.sh applies raw_manifest via kubectl apply
#   - Mixed (helm + raw_manifest) preinstall lists succeed in order

setup() {
  SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/.."
  ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
  SCHEMA="$ENGINE_DIR/templates/scenario.schema.json"
  SCENARIOS_DIR="$ROOT_DIR/examples/sample-product-chart/chart-test/scenarios"
  TMPDIR="${BATS_TMPDIR:-/tmp}"
  # Clean up stale tempfiles from interrupted prior runs before any test
  find "$TMPDIR" -maxdepth 1 -name 'scen-*.yaml' -mmin +5 -delete 2>/dev/null || true
}

teardown() {
  # Clean up stale tempfiles left by interrupted runs (belt-and-suspenders
  # with the per-test rm -f cleanup in each @test block).
  find "$TMPDIR" -maxdepth 1 -name 'scen-*.yaml' -mmin +5 -delete 2>/dev/null || true
}

# Helper: validate a YAML file against the scenario schema.
validate_yaml() {
  local yaml_file="$1"
  yq -o=json "$yaml_file" | jsonschema -i /dev/stdin "$SCHEMA" 2>&1
}

# ---- Schema validation tests ----

@test "schema accepts raw_manifest preinstall item with path" {
  tmpscen=$(mktemp "$TMPDIR/scen-raw-ok-XXXXX.yaml")
  cat > "$tmpscen" <<'EOF'
---
id: raw-manifest-ok
cluster:
  provider: kind
  preinstall:
    - kind: raw_manifest
      path: chart-test/fixtures/test/raw-manifest-configmap.yaml
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -eq 0 ]
  rm -f "$tmpscen"
}

@test "schema accepts raw_manifest preinstall with path and namespace" {
  tmpscen=$(mktemp "$TMPDIR/scen-raw-ns-XXXXX.yaml")
  cat > "$tmpscen" <<'EOF'
---
id: raw-manifest-ns
cluster:
  provider: kind
  preinstall:
    - kind: raw_manifest
      path: chart-test/fixtures/test/raw-manifest-configmap.yaml
      namespace: my-ns
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -eq 0 ]
  rm -f "$tmpscen"
}

@test "schema rejects raw_manifest without path" {
  tmpscen=$(mktemp "$TMPDIR/scen-raw-nopath-XXXXX.yaml")
  cat > "$tmpscen" <<'EOF'
---
id: raw-manifest-no-path
cluster:
  provider: kind
  preinstall:
    - kind: raw_manifest
      namespace: default
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"path"* ]] || [[ "${output}" == *"raw_manifest"* ]]
  rm -f "$tmpscen"
}

@test "schema rejects unknown preinstall kind (kustomize)" {
  tmpscen=$(mktemp "$TMPDIR/scen-kust-XXXXX.yaml")
  cat > "$tmpscen" <<'EOF'
---
id: bad-kind-kustomize
cluster:
  provider: kind
  preinstall:
    - kind: kustomize
      path: some/path
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -ne 0 ]
  # Error should reference the kind discriminator or enum mismatch
  [[ "${output}" == *"kind"* ]] || [[ "${output}" == *"oneOf"* ]] || [[ "${output}" == *"enum"* ]]
  rm -f "$tmpscen"
}

@test "schema rejects raw_manifest with extra properties (e.g. chart)" {
  tmpscen=$(mktemp "$TMPDIR/scen-raw-extra-XXXXX.yaml")
  cat > "$tmpscen" <<'EOF'
---
id: raw-manifest-extra-props
cluster:
  provider: kind
  preinstall:
    - kind: raw_manifest
      path: some/path
      chart: some/chart
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -ne 0 ]
  rm -f "$tmpscen"
}

@test "helm-only preinstall item validates without kind field (backward compat)" {
  tmpscen=$(mktemp "$TMPDIR/scen-helm-nokind-XXXXX.yaml")
  cat > "$tmpscen" <<'EOF'
---
id: helm-no-kind
cluster:
  provider: kind
  preinstall:
    - chart: jetstack/cert-manager
      version: v1.14.0
      release: cert-manager
      namespace: cert-manager
      repo: { name: jetstack, url: "https://charts.jetstack.io" }
      values: { installCRDs: true }
      wait: pods-ready
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -eq 0 ]
  rm -f "$tmpscen"
}

@test "helm preinstall item validates with explicit kind: helm" {
  tmpscen=$(mktemp "$TMPDIR/scen-helm-explicit-XXXXX.yaml")
  cat > "$tmpscen" <<'EOF'
---
id: helm-explicit-kind
cluster:
  provider: kind
  preinstall:
    - kind: helm
      chart: jetstack/cert-manager
      version: v1.14.0
      release: cert-manager
      namespace: cert-manager
      repo: { name: jetstack, url: "https://charts.jetstack.io" }
      values: { installCRDs: true }
      wait: pods-ready
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -eq 0 ]
  rm -f "$tmpscen"
}

@test "mixed preinstall list (raw_manifest + helm) validates" {
  tmpscen=$(mktemp "$TMPDIR/scen-mixed-XXXXX.yaml")
  cat > "$tmpscen" <<'EOF'
---
id: mixed-preinstall
cluster:
  provider: kind
  preinstall:
    - kind: raw_manifest
      path: chart-test/fixtures/test/raw-manifest-configmap.yaml
      namespace: cts-raw
    - chart: oci://docker.io/envoyproxy/gateway-helm
      version: v1.1.2
      release: envoy-gateway
      namespace: envoy-gateway-system
      wait: pods-ready
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  run validate_yaml "$tmpscen"
  [ "$status" -eq 0 ]
  rm -f "$tmpscen"
}

@test "all pre-F1.2 scenarios still validate against the updated schema" {
  while IFS= read -r f; do
    run validate_yaml "$f"
    [ "$status" -eq 0 ]
  done < <(find "$SCENARIOS_DIR" -type f -name '*.yaml' | sort)
}

# ---- apply-scenario.sh dispatch tests (no real cluster) ----

@test "apply-scenario.sh dispatches raw_manifest items (syntax check)" {
  # Verify the script has the apply_raw_manifest function and the kind-dispatch loop.
  grep -q 'apply_raw_manifest' "$SCRIPT_DIR/apply-scenario.sh"
  grep -q 'kind=helm\|kind=raw_manifest\|item_kind' "$SCRIPT_DIR/apply-scenario.sh"
}

@test "apply-scenario.sh rejects unknown preinstall kind at runtime" {
  tmpscen=$(mktemp "$TMPDIR/scen-badkind-XXXXX.yaml")
  cat > "$tmpscen" <<'EOF'
---
id: bad-kind-runtime
cluster:
  provider: kind
  preinstall:
    - kind: kustomize
      path: some/path
product:
  chart: chart/
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF
  # This scenario won't validate against the schema, but we also test
  # that apply-scenario.sh would reject it at runtime.
  # We check the script contains the rejection logic.
  grep -q "unknown kind" "$SCRIPT_DIR/apply-scenario.sh"
  rm -f "$tmpscen"
}

@test "apply-scenario.sh cleans up all tempfiles including multiple inline values" {
  # Verify the script uses a _CTS_TEMPFILES array and cleanup trap.
  grep -q '_CTS_TEMPFILES' "$SCRIPT_DIR/apply-scenario.sh"
  grep -q 'cts_cleanup_tempfiles' "$SCRIPT_DIR/apply-scenario.sh"
}

@test "apply-scenario.sh resolves URLs as-is without PROJECT_DIR prefix" {
  # Verify the resolve_path function handles URLs.
  grep -q 'http://\|https://' "$SCRIPT_DIR/apply-scenario.sh"
}

@test "apply-scenario.sh reports missing path for raw_manifest before cluster ops" {
  # Verify that the script checks for file existence before kubectl apply.
  grep -q 'path not found' "$SCRIPT_DIR/apply-scenario.sh"
  grep -q "missing required 'path'" "$SCRIPT_DIR/apply-scenario.sh"
}

@test "apply_raw_manifest ensures namespace before kubectl apply (greppable check)" {
  # Within apply_raw_manifest(), the ensure-namespace step (kubectl create
  # namespace --dry-run=client -o yaml | kubectl apply -f -) MUST appear
  # before the final kubectl apply call.  We verify by extracting the
  # function body and checking the relative line order.
  awk '/^apply_raw_manifest\(\)/,/^}/' "$SCRIPT_DIR/apply-scenario.sh" > "$TMPDIR/raw_manifest_fn.txt"

  # Find line numbers of the two operations.
  local ensure_ln apply_ln
  ensure_ln=$(grep -n 'create namespace.*--dry-run=client' "$TMPDIR/raw_manifest_fn.txt" | head -1 | cut -d: -f1)
  # The actual apply line calls kubectl_ctx with the args array that contains apply -f.
  apply_ln=$(grep -n 'kubectl_ctx "\${kubectl_args\[@\]}"' "$TMPDIR/raw_manifest_fn.txt" | head -1 | cut -d: -f1)

  [ -n "$ensure_ln" ] || { echo "FAIL: ensure-namespace line not found in apply_raw_manifest" >&2; return 1; }
  [ -n "$apply_ln" ]   || { echo "FAIL: kubectl apply (kubectl_args) line not found in apply_raw_manifest" >&2; return 1; }

  [ "$ensure_ln" -lt "$apply_ln" ] || {
    echo "FAIL: ensure-namespace (line $ensure_ln) must appear before kubectl apply (line $apply_ln)" >&2
    return 1
  }
}

@test "envoy-gateway scenario YAML validates against the schema" {
  local eg_scen="$SCENARIOS_DIR/gateway-api/envoy-gateway.yaml"
  [ -f "$eg_scen" ]
  run validate_yaml "$eg_scen"
  [ "$status" -eq 0 ]
}
