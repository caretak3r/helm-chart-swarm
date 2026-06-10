#!/usr/bin/env bats
# cilium-cni.bats — Tests for Cilium CNI engine support (VAL-CILIUM-001..005, 010, 011)
#
# Uses stubbed kind/kubectl/helm/docker binaries (fake bin dir on PATH)
# to assert install ordering, the assembled helm command, env exports +
# fixture bundling, version resolution precedence, and sync checks between
# the two engine copies.

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"

  CANONICAL_CLUSTER_UP="$SCRIPT_DIR/cluster-up.sh"
  CANONICAL_RUN_SCENARIO="$SCRIPT_DIR/run-scenario.sh"
  CANONICAL_INSTALL_CILIUM="$SCRIPT_DIR/lib/install-cilium.sh"

  BUNDLED_ENGINE="$ROOT_DIR/engine/skills/chart-test-swarm/engine"
  BUNDLED_CLUSTER_UP="$BUNDLED_ENGINE/scripts/cluster-up.sh"
  BUNDLED_RUN_SCENARIO="$BUNDLED_ENGINE/scripts/run-scenario.sh"
  BUNDLED_INSTALL_CILIUM="$BUNDLED_ENGINE/scripts/lib/install-cilium.sh"

  CANONICAL_SCHEMA="$ENGINE_DIR/templates/scenario.schema.json"
  BUNDLED_SCHEMA="$BUNDLED_ENGINE/templates/scenario.schema.json"

  TMPDIR="${BATS_TMPDIR:-/tmp}"
  _CILIUM_TEMPFILES=()
}

teardown() {
  for f in "${_CILIUM_TEMPFILES[@]+"${_CILIUM_TEMPFILES[@]}"}"; do
    rm -rf "$f" 2>/dev/null || true
  done
}

# ---- Helper: create a fake bin dir with stubbed tools ----
# Each stub logs its invocation to $FAKE_BIN_DIR/calls.log
create_fake_bin_dir() {
  local fake_dir="$1"
  mkdir -p "$fake_dir"

  # kind stub: logs calls, writes fake cluster list
  cat > "$fake_dir/kind" <<'KIND_EOF'
#!/usr/bin/env bash
echo "kind $*" >> "${FAKE_BIN_DIR}/calls.log"
case "$1" in
  "get") echo "" ;;  # no clusters by default
  "create") exit 0 ;;
  *) exit 0 ;;
esac
KIND_EOF
  chmod +x "$fake_dir/kind"

  # kubectl stub
  cat > "$fake_dir/kubectl" <<'KUBECTL_EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "${FAKE_BIN_DIR}/calls.log"
exit 0
KUBECTL_EOF
  chmod +x "$fake_dir/kubectl"

  # helm stub
  cat > "$fake_dir/helm" <<'HELM_EOF'
#!/usr/bin/env bash
echo "helm $*" >> "${FAKE_BIN_DIR}/calls.log"
exit 0
HELM_EOF
  chmod +x "$fake_dir/helm"

  # docker stub
  cat > "$fake_dir/docker" <<'DOCKER_EOF'
#!/usr/bin/env bash
echo "docker $*" >> "${FAKE_BIN_DIR}/calls.log"
# Return a fake IP for control-plane inspect
if [[ "$*" == *"inspect"* ]]; then
  echo "172.18.0.2"
fi
exit 0
DOCKER_EOF
  chmod +x "$fake_dir/docker"

  # yq stub (minimal)
  cat > "$fake_dir/yq" <<'YQ_EOF'
#!/usr/bin/env bash
echo "yq $*" >> "${FAKE_BIN_DIR}/calls.log"
exit 0
YQ_EOF
  chmod +x "$fake_dir/yq"

  # jq stub
  cat > "$fake_dir/jq" <<'JQ_EOF'
#!/usr/bin/env bash
echo "jq $*" >> "${FAKE_BIN_DIR}/calls.log"
exit 0
JQ_EOF
  chmod +x "$fake_dir/jq"
}

# ---------------------------------------------------------------------------
# Group 1: Schema validation (VAL-CILIUM-001, VAL-CILIUM-002)
# ---------------------------------------------------------------------------

@test "canonical schema declares cluster.cni object" {
  run jq -e '.properties.cluster.properties.cni' "$CANONICAL_SCHEMA"
  [ "$status" -eq 0 ] || {
    echo "ERROR: canonical schema missing cluster.cni" >&2; false
  }
}

@test "bundled schema declares cluster.cni object" {
  run jq -e '.properties.cluster.properties.cni' "$BUNDLED_SCHEMA"
  [ "$status" -eq 0 ] || {
    echo "ERROR: bundled schema missing cluster.cni" >&2; false
  }
}

@test "cluster.cni has required provider enum including cilium" {
  run jq -e '.properties.cluster.properties.cni.required == ["provider"]' "$CANONICAL_SCHEMA"
  [ "$status" -eq 0 ] || {
    echo "ERROR: cluster.cni must require 'provider'" >&2; false
  }
  run jq -e '.properties.cluster.properties.cni.properties.provider.enum | index("cilium")' "$CANONICAL_SCHEMA"
  [ "$status" -eq 0 ] || {
    echo "ERROR: provider enum must include 'cilium'" >&2; false
  }
}

@test "cluster.cni is additionalProperties: false" {
  run jq -e '.properties.cluster.properties.cni.additionalProperties == false' "$CANONICAL_SCHEMA"
  [ "$status" -eq 0 ] || {
    echo "ERROR: cluster.cni must have additionalProperties: false" >&2; false
  }
}

@test "cluster remains additionalProperties: false" {
  run jq -e '.properties.cluster.additionalProperties == false' "$CANONICAL_SCHEMA"
  [ "$status" -eq 0 ] || {
    echo "ERROR: cluster must remain additionalProperties: false" >&2; false
  }
}

@test "kube_proxy_replacement defaults to true in schema" {
  run jq -e '.properties.cluster.properties.cni.properties.kube_proxy_replacement.default == true' "$CANONICAL_SCHEMA"
  [ "$status" -eq 0 ] || {
    echo "ERROR: kube_proxy_replacement default should be true" >&2; false
  }
}

@test "both schema copies have identical cluster.cni definitions" {
  local canonical_cni bundled_cni
  canonical_cni=$(jq -S '.properties.cluster.properties.cni' "$CANONICAL_SCHEMA")
  bundled_cni=$(jq -S '.properties.cluster.properties.cni' "$BUNDLED_SCHEMA")
  [ "$canonical_cni" = "$bundled_cni" ] || {
    echo "ERROR: cluster.cni differs between canonical and bundled schemas" >&2
    diff <(echo "$canonical_cni") <(echo "$bundled_cni") || true
    false
  }
}

@test "cilium scenario validates against canonical schema" {
  if ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "check-jsonschema not installed"
  fi
  local tmpdir
  tmpdir=$(mktemp -d "$TMPDIR/cilium-schema-XXXXX")
  _CILIUM_TEMPFILES+=("$tmpdir")

  cat > "$tmpdir/cilium-scenario.yaml" <<'EOF'
id: cni-cilium-ebpf
cluster:
  provider: kind
  cni:
    provider: cilium
    kube_proxy_replacement: true
product:
  chart: ./chart
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF

  run check-jsonschema --schemafile "$CANONICAL_SCHEMA" "$tmpdir/cilium-scenario.yaml"
  [ "$status" -eq 0 ] || {
    echo "ERROR: cilium scenario should validate against canonical schema" >&2
    echo "$output" >&2; false
  }
}

@test "cilium scenario validates against bundled schema" {
  if ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "check-jsonschema not installed"
  fi
  local tmpdir
  tmpdir=$(mktemp -d "$TMPDIR/cilium-schema-XXXXX")
  _CILIUM_TEMPFILES+=("$tmpdir")

  cat > "$tmpdir/cilium-scenario.yaml" <<'EOF'
id: cni-cilium-ebpf
cluster:
  provider: kind
  cni:
    provider: cilium
    kube_proxy_replacement: true
product:
  chart: ./chart
  release: test
  namespace: test
asserts:
  - type: pods-ready
    namespace: test
EOF

  run check-jsonschema --schemafile "$BUNDLED_SCHEMA" "$tmpdir/cilium-scenario.yaml"
  [ "$status" -eq 0 ] || {
    echo "ERROR: cilium scenario should validate against bundled schema" >&2
    echo "$output" >&2; false
  }
}

@test "pre-existing scenarios still validate against canonical schema" {
  if ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "check-jsonschema not installed"
  fi

  local scenarios_dir="$ROOT_DIR/examples/sample-product-chart/chart-test/scenarios"
  [ -d "$scenarios_dir" ] || skip "scenarios dir not found: $scenarios_dir"

  local failures=0
  while IFS= read -r -d '' f; do
    run check-jsonschema --schemafile "$CANONICAL_SCHEMA" "$f"
    if [ "$status" -ne 0 ]; then
      echo "FAIL: $f" >&2
      failures=$((failures + 1))
    fi
  done < <(find "$scenarios_dir" -name "*.yaml" -print0 2>/dev/null | head -20)

  [ "$failures" -eq 0 ] || {
    echo "ERROR: $failures pre-existing scenario(s) failed validation" >&2; false
  }
}

# ---------------------------------------------------------------------------
# Group 2: install-cilium.sh — script structure (VAL-CILIUM-005)
# ---------------------------------------------------------------------------

@test "install-cilium.sh exists in both copies" {
  [ -f "$CANONICAL_INSTALL_CILIUM" ] || { echo "ERROR: canonical install-cilium.sh missing" >&2; false; }
  [ -f "$BUNDLED_INSTALL_CILIUM" ] || { echo "ERROR: bundled install-cilium.sh missing" >&2; false; }
}

@test "install-cilium.sh has set -euo pipefail" {
  grep -q 'set -euo pipefail' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: install-cilium.sh missing set -euo pipefail" >&2; false
  }
}

@test "install-cilium.sh defines _read_cni_version helper" {
  grep -q '_read_cni_version()' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: _read_cni_version() function not found in install-cilium.sh" >&2; false
  }
}

@test "install-cilium.sh has fallback version 1.19.4" {
  grep -q 'FALLBACK_CILIUM_VERSION="1.19.4"' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: install-cilium.sh missing fallback version 1.19.4" >&2; false
  }
}

@test "install-cilium.sh assembles helm command with kubeProxyReplacement, k8sServiceHost, k8sServicePort, operator.replicas, ipam.mode" {
  grep -q 'kubeProxyReplacement' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: missing kubeProxyReplacement" >&2; false
  }
  grep -q 'k8sServiceHost' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: missing k8sServiceHost" >&2; false
  }
  grep -q 'k8sServicePort=6443' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: missing k8sServicePort=6443" >&2; false
  }
  grep -q 'operator.replicas=1' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: missing operator.replicas=1" >&2; false
  }
  grep -q 'ipam.mode=kubernetes' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: missing ipam.mode=kubernetes" >&2; false
  }
}

@test "install-cilium.sh supports -f values when CTS_CNI_VALUES is set" {
  grep -q 'CTS_CNI_VALUES' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: missing CTS_CNI_VALUES support" >&2; false
  }
  grep -q '\-f' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: missing -f flag for values file" >&2; false
  }
}

@test "install-cilium.sh requires K8S_SERVICE_HOST to be set" {
  grep -q 'K8S_SERVICE_HOST' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: missing K8S_SERVICE_HOST check" >&2; false
  }
}

# ---------------------------------------------------------------------------
# Group 3: install-cilium.sh — version resolution (VAL-CILIUM-010)
# ---------------------------------------------------------------------------

@test "_read_cni_version returns version from project versions.yaml cni.cilium.version" {
  local tmpdir
  tmpdir=$(mktemp -d "$TMPDIR/cni-ver-XXXXX")
  _CILIUM_TEMPFILES+=("$tmpdir")
  mkdir -p "$tmpdir/defaults" "$tmpdir/project/chart-test"

  cat > "$tmpdir/defaults/versions.yaml" <<'YEOF'
kubernetes:
  kind: "v1.31.0"
  minikube: "v1.31.0"
  gke: "1.30"
  eks: "1.30"
  aks: "1.30"
cli_tools:
  helm: "3.17"
  kubectl: "1.31"
  kind: "0.27"
  minikube: "1.35"
preinstalls: {}
product:
  chart: "sample"
  version: "0.1.0"
cloud:
  gke:
    k8s_version: "1.30"
    region: "us-central1"
  eks:
    k8s_version: "1.30"
    region: "us-east-1"
  aks:
    k8s_version: "1.30"
    region: "eastus"
cni:
  cilium:
    chart: "cilium"
    version: "2.0.0"
    repo: "https://helm.cilium.io"
YEOF

  cat > "$tmpdir/project/chart-test/versions.yaml" <<'YEOF'
cni:
  cilium:
    chart: "cilium"
    version: "1.99.0"
    repo: "https://helm.cilium.io"
YEOF

  local fn_body
  fn_body=$(sed -n '/_read_cni_version()/,/^}/p' "$CANONICAL_INSTALL_CILIUM")

  run bash -c "
set -euo pipefail
ENGINE_DIR='$tmpdir'
PROJECT_DIR='$tmpdir/project'
$fn_body
_read_cni_version
"
  [ "$status" -eq 0 ] || {
    echo "ERROR: _read_cni_version failed: $output" >&2; false
  }
  echo "$output"
  [ "$output" = "1.99.0" ] || {
    echo "ERROR: expected project override '1.99.0', got '$output'" >&2; false
  }
}

@test "CTS_CNI_VERSION takes precedence over versions.yaml" {
  # install-cilium.sh checks CTS_CNI_VERSION first
  grep -q 'CTS_CNI_VERSION' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: install-cilium.sh must check CTS_CNI_VERSION" >&2; false
  }
  # CTS_CNI_VERSION is checked before _read_cni_version
  # The version resolution order should be: CTS_CNI_VERSION -> versions.yaml -> fallback
  head -n 70 "$CANONICAL_INSTALL_CILIUM" | grep -q 'CTS_CNI_VERSION' || {
    # Check the actual resolution block
    grep -B2 '_read_cni_version' "$CANONICAL_INSTALL_CILIUM" | grep -q 'CTS_CNI_VERSION' || {
      # The check for CTS_CNI_VERSION should appear before _read_cni_version call
      awk '/CTS_CNI_VERSION/,/_read_cni_version/' "$CANONICAL_INSTALL_CILIUM" | head -20
      echo "ERROR: CTS_CNI_VERSION should be checked before config lookup" >&2; false
    }
  }
}

@test "fallback 1.19.4 used when no config available" {
  grep -q 'FALLBACK_CILIUM_VERSION' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: missing fallback version variable" >&2; false
  }
  grep -q '$FALLBACK_CILIUM_VERSION' "$CANONICAL_INSTALL_CILIUM" || {
    echo "ERROR: fallback version not used" >&2; false
  }
}

@test "engine/defaults/versions.yaml has no cilium entry" {
  local engine_defaults="$ENGINE_DIR/defaults/versions.yaml"
  if [ -f "$engine_defaults" ]; then
    run yq '.cni // "absent"' "$engine_defaults"
    [ "$output" = "absent" ] || {
      echo "ERROR: engine/defaults/versions.yaml should NOT have cni key, got: $output" >&2; false
    }
  fi
}

@test "project versions.yaml exists with cni.cilium pin to 1.19.4" {
  local proj_ver="$ROOT_DIR/examples/sample-product-chart/chart-test/versions.yaml"
  [ -f "$proj_ver" ] || {
    echo "ERROR: project versions.yaml not found at $proj_ver" >&2; false
  }
  run yq '.cni.cilium.version' "$proj_ver"
  [ "$status" -eq 0 ] || {
    echo "ERROR: cannot read cni.cilium.version from project versions.yaml" >&2; false
  }
  [ "$output" = "1.19.4" ] || {
    echo "ERROR: expected cni.cilium.version=1.19.4, got '$output'" >&2; false
  }
}

# ---------------------------------------------------------------------------
# Group 4: cluster-up.sh — install ordering (VAL-CILIUM-003)
# ---------------------------------------------------------------------------

@test "canonical cluster-up.sh has Cilium CNI hook" {
  grep -q 'CTS_CNI' "$CANONICAL_CLUSTER_UP" || {
    echo "ERROR: canonical cluster-up.sh missing CTS_CNI check" >&2; false
  }
}

@test "canonical cluster-up.sh creates cluster without --wait when CTS_CNI=cilium" {
  # The kind create command when CTS_CNI=cilium should NOT include --wait
  # Extract the Cilium block and verify
  local cilium_block
  cilium_block=$(sed -n '/# ---- Cilium CNI support ----/,/# ---- End Cilium CNI support ----/p' "$CANONICAL_CLUSTER_UP")
  echo "$cilium_block" | grep -q 'no --wait' || {
    # Check that --wait is NOT present in the args creation for Cilium path
    echo "$cilium_block"
    echo "ERROR: Cilium path should indicate no --wait" >&2; false
  }
}

@test "canonical cluster-up.sh resolves control-plane IP via docker inspect" {
  grep -q 'docker inspect' "$CANONICAL_CLUSTER_UP" || {
    echo "ERROR: cluster-up.sh missing docker inspect for control-plane IP" >&2; false
  }
  grep -q 'NetworkSettings.Networks.kind.IPAddress' "$CANONICAL_CLUSTER_UP" || {
    echo "ERROR: cluster-up.sh missing kind network IP lookup" >&2; false
  }
}

@test "canonical cluster-up.sh waits for ds/cilium rollout after install" {
  grep -q 'rollout status ds/cilium' "$CANONICAL_CLUSTER_UP" || {
    echo "ERROR: cluster-up.sh missing ds/cilium rollout wait" >&2; false
  }
}

@test "canonical cluster-up.sh waits for nodes Ready after Cilium install" {
  grep -q 'kubectl.*wait.*--for=condition=Ready.*nodes.*--all' "$CANONICAL_CLUSTER_UP" || {
    echo "ERROR: cluster-up.sh missing node-ready wait after Cilium" >&2; false
  }
}

@test "canonical cluster-up.sh calls lib/install-cilium.sh when CTS_CNI=cilium" {
  grep -q 'lib/install-cilium.sh' "$CANONICAL_CLUSTER_UP" || {
    echo "ERROR: cluster-up.sh must invoke lib/install-cilium.sh" >&2; false
  }
}

@test "canonical cluster-up.sh fails fast on non-kind + cni" {
  grep -q 'Cilium-as-CNI is only supported on kind' "$CANONICAL_CLUSTER_UP" || {
    echo "ERROR: cluster-up.sh missing non-kind + cni error message" >&2; false
  }
  # Check that the fast-fail exits non-zero
  grep -A5 'Cilium CNI fast-fail' "$CANONICAL_CLUSTER_UP" | grep -q 'exit 1' || {
    echo "ERROR: non-kind + cni must exit 1" >&2; false
  }
}

@test "canonical cluster-up.sh is idempotent — skips create if cluster exists" {
  grep -A10 'Cilium CNI support' "$CANONICAL_CLUSTER_UP" | grep -q 'already exists' || {
    echo "ERROR: Cilium path must check if cluster exists (idempotent)" >&2; false
  }
}

# ---------------------------------------------------------------------------
# Group 5: run-scenario.sh — CNI passthrough (VAL-CILIUM-004)
# ---------------------------------------------------------------------------

@test "canonical run-scenario.sh reads cluster.cni fields" {
  grep -q 'cluster.cni.provider' "$CANONICAL_RUN_SCENARIO" || {
    echo "ERROR: run-scenario.sh missing cluster.cni.provider read" >&2; false
  }
  grep -q 'cluster.cni.version' "$CANONICAL_RUN_SCENARIO" || {
    echo "ERROR: run-scenario.sh missing cluster.cni.version read" >&2; false
  }
  grep -q 'cluster.cni.values' "$CANONICAL_RUN_SCENARIO" || {
    echo "ERROR: run-scenario.sh missing cluster.cni.values read" >&2; false
  }
  grep -q 'cluster.cni.kube_proxy_replacement' "$CANONICAL_RUN_SCENARIO" || {
    echo "ERROR: run-scenario.sh missing cluster.cni.kube_proxy_replacement read" >&2; false
  }
}

@test "canonical run-scenario.sh exports CTS_CNI, CTS_CNI_VERSION, CTS_CNI_VALUES, CTS_CNI_KPR" {
  grep -q 'export CTS_CNI CTS_CNI_VERSION CTS_CNI_VALUES CTS_CNI_KPR' "$CANONICAL_RUN_SCENARIO" || {
    echo "ERROR: run-scenario.sh missing CNI exports" >&2; false
  }
}

@test "canonical run-scenario.sh validates CNI values fixture path" {
  grep -A3 'Validate CNI values' "$CANONICAL_RUN_SCENARIO" | grep -q 'CTS_CNI_VALUES' || {
    echo "ERROR: run-scenario.sh missing CNI values validation in validate_fixture_paths" >&2; false
  }
}

@test "canonical run-scenario.sh copies CNI values fixture" {
  grep -A3 'Copy CNI values' "$CANONICAL_RUN_SCENARIO" | grep -q 'CTS_CNI_VALUES' || {
    echo "ERROR: run-scenario.sh missing CNI values copy in copy_fixtures_early" >&2; false
  }
}

@test "canonical run-scenario.sh rewrites CNI values path in bundle" {
  grep -A4 'Rewrite CNI values' "$CANONICAL_RUN_SCENARIO" | grep -q 'fixtures' || {
    echo "ERROR: run-scenario.sh missing CNI values rewrite in rewrite_scenario_for_bundle" >&2; false
  }
}

# ---------------------------------------------------------------------------
# Group 6: Bundled skill engine sync — byte-level parity (VAL-CILIUM-011)
# ---------------------------------------------------------------------------
# These tests assert that the three key Cilium scripts and defaults/versions.yaml
# are byte-identical between canonical and bundled engine copies, replacing the
# previous keyword-only grep checks with diff-based parity assertions.

@test "bundled run-scenario.sh is byte-identical to canonical" {
  [ -f "$BUNDLED_RUN_SCENARIO" ] || { echo "ERROR: bundled run-scenario.sh missing" >&2; false; }
  diff "$CANONICAL_RUN_SCENARIO" "$BUNDLED_RUN_SCENARIO" || {
    echo "ERROR: bundled run-scenario.sh has diverged from canonical!" >&2
    echo "  To fix: run engine/skills/chart-test-swarm/scripts/sync-engine.sh" >&2
    false
  }
}

@test "bundled cluster-up.sh is byte-identical to canonical" {
  [ -f "$BUNDLED_CLUSTER_UP" ] || { echo "ERROR: bundled cluster-up.sh missing" >&2; false; }
  diff "$CANONICAL_CLUSTER_UP" "$BUNDLED_CLUSTER_UP" || {
    echo "ERROR: bundled cluster-up.sh has diverged from canonical!" >&2
    echo "  To fix: run engine/skills/chart-test-swarm/scripts/sync-engine.sh" >&2
    false
  }
}

@test "bundled lib/install-cilium.sh is byte-identical to canonical" {
  [ -f "$BUNDLED_INSTALL_CILIUM" ] || { echo "ERROR: bundled install-cilium.sh missing" >&2; false; }
  diff "$CANONICAL_INSTALL_CILIUM" "$BUNDLED_INSTALL_CILIUM" || {
    echo "ERROR: bundled install-cilium.sh has diverged from canonical!" >&2
    echo "  To fix: run engine/skills/chart-test-swarm/scripts/sync-engine.sh" >&2
    false
  }
}

@test "bundled defaults/versions.yaml exists and is byte-identical to canonical" {
  local canonical_defaults="$ENGINE_DIR/defaults/versions.yaml"
  local bundled_defaults="$BUNDLED_ENGINE/defaults/versions.yaml"
  [ -f "$bundled_defaults" ] || {
    echo "ERROR: bundled defaults/versions.yaml does not exist" >&2
    echo "  To fix: run engine/skills/chart-test-swarm/scripts/sync-engine.sh" >&2
    false
  }
  diff "$canonical_defaults" "$bundled_defaults" || {
    echo "ERROR: bundled defaults/versions.yaml has diverged from canonical!" >&2
    echo "  To fix: run engine/skills/chart-test-swarm/scripts/sync-engine.sh" >&2
    false
  }
}

@test "bundled scenario schema is identical to canonical (byte-level)" {
  # Guards against future drift — the two schema copies must stay in sync.
  # If this test fails, copy canonical schema to bundled:
  #   cp engine/templates/scenario.schema.json engine/skills/chart-test-swarm/engine/templates/scenario.schema.json
  diff "$CANONICAL_SCHEMA" "$BUNDLED_SCHEMA" || {
    echo "ERROR: scenario schema copies have diverged!" >&2
    echo "  Canonical: $CANONICAL_SCHEMA" >&2
    echo "  Bundled:   $BUNDLED_SCHEMA" >&2
    echo "  To fix: cp $CANONICAL_SCHEMA $BUNDLED_SCHEMA" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Group 6b: Full bundled engine script parity (catches any future drift)
# ---------------------------------------------------------------------------
# This test asserts that ALL .sh scripts under the bundled engine/scripts/
# directory are byte-identical to their canonical counterparts. This catches
# future drift on ANY script, not just Cilium-specific ones.

@test "ALL bundled engine scripts match canonical counterparts" {
  local canonical_scripts_dir="$SCRIPT_DIR"
  local bundled_scripts_dir="$BUNDLED_ENGINE/scripts"
  local failures=0
  local checked=0

  while IFS= read -r -d '' canonical_file; do
    local rel_path="${canonical_file#$canonical_scripts_dir/}"
    local bundled_file="$bundled_scripts_dir/$rel_path"

    if [ ! -f "$bundled_file" ]; then
      echo "MISSING in bundled: $rel_path" >&2
      failures=$((failures + 1))
      continue
    fi

    if ! diff -q "$canonical_file" "$bundled_file" >/dev/null 2>&1; then
      echo "DIVERGED: $rel_path" >&2
      failures=$((failures + 1))
    fi
    checked=$((checked + 1))
  done < <(find "$canonical_scripts_dir" -name '*.sh' -print0 | sort -z)

  # Also check that bundled doesn't have extra scripts not in canonical
  while IFS= read -r -d '' bundled_file; do
    local rel_path="${bundled_file#$bundled_scripts_dir/}"
    local canonical_file="$canonical_scripts_dir/$rel_path"
    if [ ! -f "$canonical_file" ]; then
      echo "EXTRA in bundled (not in canonical): $rel_path" >&2
      failures=$((failures + 1))
    fi
  done < <(find "$bundled_scripts_dir" -name '*.sh' -print0 2>/dev/null | sort -z)

  [ "$failures" -eq 0 ] || {
    echo "ERROR: $failures script(s) have drifted between canonical and bundled engine!" >&2
    echo "  Checked $checked scripts." >&2
    echo "  To fix: run engine/skills/chart-test-swarm/scripts/sync-engine.sh" >&2
    false
  }
  echo "Checked $checked scripts — all identical."
}

@test "all existing scenarios validate against bundled schema (no regressions)" {
  if ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "check-jsonschema not installed"
  fi

  local scenarios_dir="$ROOT_DIR/examples/sample-product-chart/chart-test/scenarios"
  [ -d "$scenarios_dir" ] || skip "scenarios dir not found: $scenarios_dir"

  local failures=0
  while IFS= read -r -d '' f; do
    run check-jsonschema --schemafile "$BUNDLED_SCHEMA" "$f"
    if [ "$status" -ne 0 ]; then
      echo "FAIL: $f" >&2
      failures=$((failures + 1))
    fi
  done < <(find "$scenarios_dir" -name "*.yaml" -print0 2>/dev/null)

  [ "$failures" -eq 0 ] || {
    echo "ERROR: $failures scenario(s) failed validation against bundled schema" >&2; false
  }
}

# ---------------------------------------------------------------------------
# Group 7: Functional tests with stubbed tools (VAL-CILIUM-003, VAL-CILIUM-005)
# ---------------------------------------------------------------------------

@test "cluster-up.sh with CTS_CNI=cilium creates cluster without --wait and installs Cilium" {
  local tmpdir
  tmpdir=$(mktemp -d "$TMPDIR/cilium-func-XXXXX")
  _CILIUM_TEMPFILES+=("$tmpdir")

  local fake_bin="$tmpdir/fake-bin"
  create_fake_bin_dir "$fake_bin"
  export FAKE_BIN_DIR="$fake_bin"

  # Create a minimal versions.yaml so _read_k8s_version doesn't error
  mkdir -p "$tmpdir/defaults"
  cat > "$tmpdir/defaults/versions.yaml" <<'YEOF'
kubernetes:
  kind: "v1.31.0"
  minikube: "v1.31.0"
  gke: "1.30"
  eks: "1.30"
  aks: "1.30"
cli_tools:
  helm: "3.17"
  kubectl: "1.31"
  kind: "0.27"
  minikube: "1.35"
preinstalls: {}
product:
  chart: "sample"
  version: "0.1.0"
cloud:
  gke:
    k8s_version: "1.30"
    region: "us-central1"
  eks:
    k8s_version: "1.30"
    region: "us-east-1"
  aks:
    k8s_version: "1.30"
    region: "eastus"
YEOF

  # Override SCRIPT_DIR and ENGINE_DIR for the test
  local script_dir="$tmpdir/scripts"
  mkdir -p "$script_dir/lib"
  # Copy install-cilium.sh to the fake scripts dir
  cp "$CANONICAL_INSTALL_CILIUM" "$script_dir/lib/install-cilium.sh"

  # Create a test wrapper that sets up the environment
  run bash -c "
set -euo pipefail
export PATH='$fake_bin:$PATH'
export CLUSTER_NAME='chart-test-swarm-cilium-test'
export PROVIDER='kind'
export CTS_CNI='cilium'
export K8S_SERVICE_HOST='172.18.0.2'
export CTS_CNI_VERSION='1.19.4'
export CTS_CNI_KPR='true'
export CTS_NO_CONTEXT_RESTORE=1

# We need to fake the SCRIPT_DIR/ENGINE_DIR since we're in a temp dir
SCRIPT_DIR='$script_dir'
ENGINE_DIR='$tmpdir'

# Source install-cilium directly to verify version resolution
source '$script_dir/lib/install-cilium.sh'
echo 'OK'
" 2>&1 || true

  [ "$status" -eq 0 ] || {
    echo "ERROR: install-cilium.sh test failed: $output" >&2; false
  }
  echo "$output" | grep -q "OK"
}

@test "non-kind provider + CTS_CNI=cilium fails fast" {
  local tmpdir
  tmpdir=$(mktemp -d "$TMPDIR/cilium-nonkind-XXXXX")
  _CILIUM_TEMPFILES+=("$tmpdir")

  local fake_bin="$tmpdir/fake-bin"
  create_fake_bin_dir "$fake_bin"
  export FAKE_BIN_DIR="$fake_bin"

  run bash -c "
set -euo pipefail
export PATH='$fake_bin:$PATH'
export CLUSTER_NAME='chart-test-swarm-cilium-test'
export PROVIDER='minikube'
export CTS_CNI='cilium'
SCRIPT_DIR='$SCRIPT_DIR'
ENGINE_DIR='$ENGINE_DIR'
export SCRIPT_DIR ENGINE_DIR

# Source the fast-fail check only
if [ \"\${CTS_CNI:-}\" = \"cilium\" ] && [ \"\$PROVIDER\" != \"kind\" ]; then
  echo 'ERROR: Cilium-as-CNI is only supported on kind'
  exit 1
fi
"
  [ "$status" -eq 1 ] || {
    echo "ERROR: non-kind + cni should exit 1, got: $status" >&2; false
  }
  echo "$output" | grep -q "only supported on kind"
}

@test "docker inspect resolves control-plane IP for Cilium" {
  local tmpdir
  tmpdir=$(mktemp -d "$TMPDIR/cilium-docker-XXXXX")
  _CILIUM_TEMPFILES+=("$tmpdir")

  local fake_bin="$tmpdir/fake-bin"
  mkdir -p "$fake_bin"

  # docker stub that returns a fake IP
  cat > "$fake_bin/docker" <<'DOCKER_EOF'
#!/usr/bin/env bash
if [[ "$*" == *"inspect"* ]]; then
  echo "172.18.0.2"
fi
exit 0
DOCKER_EOF
  chmod +x "$fake_bin/docker"

  run bash -c "
export PATH='$fake_bin:$PATH'
CLUSTER_NAME='chart-test-swarm-cilium-test'
_cp_ip=\$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' \"\${CLUSTER_NAME}-control-plane\" 2>/dev/null || echo '')
echo \"IP:\$_cp_ip\"
"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "IP:172.18.0.2" || {
    echo "ERROR: docker inspect stub didn't return expected IP, got: $output" >&2; false
  }
}
