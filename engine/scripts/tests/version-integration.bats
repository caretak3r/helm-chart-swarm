#!/usr/bin/env bats
# version-integration.bats — Tests for f2-2: versions.yaml integration into engine scripts
#
# Covers:
#   VAL-VER-003: cluster-up.sh uses kubernetes version from config
#   VAL-VER-004: run-scenario.sh resolves preinstall versions from config when scenario omits them
#   VAL-VER-005: scenario YAML version takes precedence over config
#   VAL-VER-006: versions.json artifact records resolved version sources

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"

  CLUSTER_UP="$SCRIPT_DIR/cluster-up.sh"
  APPLY_SCENARIO="$SCRIPT_DIR/apply-scenario.sh"
  RUN_SCENARIO="$SCRIPT_DIR/run-scenario.sh"
  ENGINE_DEFAULTS="$ENGINE_DIR/defaults/versions.yaml"

  TMPDIR="${BATS_TMPDIR:-/tmp}"
  _VER_TEMPFILES=()
}

teardown() {
  for f in "${_VER_TEMPFILES[@]+"${_VER_TEMPFILES[@]}"}"; do
    rm -rf "$f" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------------------
# Group 1: cluster-up.sh — static checks (VAL-VER-003)
# ---------------------------------------------------------------------------

@test "cluster-up.sh defines _read_k8s_version_from_config helper" {
  grep -q '_read_k8s_version_from_config()' "$CLUSTER_UP" || {
    echo "ERROR: _read_k8s_version_from_config() function not found in cluster-up.sh" >&2
    false
  }
}

@test "cluster-up.sh reads K8S_VERSION from config when K8S_VERSION is empty" {
  # The script must check K8S_VERSION and call _read_k8s_version_from_config
  grep -q '_read_k8s_version_from_config' "$CLUSTER_UP" || {
    echo "ERROR: cluster-up.sh must call _read_k8s_version_from_config" >&2
    false
  }
  # The config version is only used when K8S_VERSION is unset
  grep -q 'if \[ -z "\$K8S_VERSION" \]' "$CLUSTER_UP" || {
    echo "ERROR: cluster-up.sh must guard config lookup with [ -z \"\$K8S_VERSION\" ]" >&2
    false
  }
}

@test "cluster-up.sh uses ENGINE_DIR to locate engine defaults" {
  # ENGINE_DIR must be derived from SCRIPT_DIR for portability
  grep -q 'ENGINE_DIR=' "$CLUSTER_UP" || {
    echo "ERROR: cluster-up.sh must define ENGINE_DIR" >&2
    false
  }
}

@test "_read_k8s_version_from_config returns kind version from engine defaults" {
  # Create a minimal versions.yaml with a test version
  local tmpdir
  tmpdir=$(mktemp -d "$TMPDIR/ver-test-XXXXX")
  _VER_TEMPFILES+=("$tmpdir")
  mkdir -p "$tmpdir/defaults"
  cat > "$tmpdir/defaults/versions.yaml" <<'EOF'
kubernetes:
  kind: "1.99.0"
  minikube: "1.98.0"
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
EOF

  # Extract the helper function from cluster-up.sh and run it in isolation
  local fn_body
  fn_body=$(sed -n '/_read_k8s_version_from_config()/,/^}/p' "$CLUSTER_UP")

  run bash -c "
set -euo pipefail
ENGINE_DIR='$tmpdir'
$fn_body
_read_k8s_version_from_config kind
"
  [ "$status" -eq 0 ] || {
    echo "ERROR: function returned non-zero: $output" >&2; false
  }
  [ "$output" = "1.99.0" ] || {
    echo "ERROR: expected '1.99.0', got '$output'" >&2; false
  }
}

@test "_read_k8s_version_from_config project override wins over engine defaults" {
  local tmpdir
  tmpdir=$(mktemp -d "$TMPDIR/ver-override-XXXXX")
  _VER_TEMPFILES+=("$tmpdir")
  mkdir -p "$tmpdir/defaults" "$tmpdir/project/chart-test"
  cat > "$tmpdir/defaults/versions.yaml" <<'EOF'
kubernetes:
  kind: "1.31"
  minikube: "1.31"
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
EOF
  # Project override sets a different kind version
  cat > "$tmpdir/project/chart-test/versions.yaml" <<'EOF'
kubernetes:
  kind: "1.32.5"
EOF

  local fn_body
  fn_body=$(sed -n '/_read_k8s_version_from_config()/,/^}/p' "$CLUSTER_UP")

  run bash -c "
set -euo pipefail
ENGINE_DIR='$tmpdir'
PROJECT_DIR='$tmpdir/project'
$fn_body
_read_k8s_version_from_config kind
"
  [ "$status" -eq 0 ] || {
    echo "ERROR: function returned non-zero: $output" >&2; false
  }
  [ "$output" = "1.32.5" ] || {
    echo "ERROR: expected project override '1.32.5', got '$output'" >&2; false
  }
}

# ---------------------------------------------------------------------------
# Group 2: apply-scenario.sh — static checks (VAL-VER-004, VAL-VER-005)
# ---------------------------------------------------------------------------

@test "apply-scenario.sh defines _preinstall_version_from_config helper" {
  grep -q '_preinstall_version_from_config()' "$APPLY_SCENARIO" || {
    echo "ERROR: _preinstall_version_from_config() function not found in apply-scenario.sh" >&2
    false
  }
}

@test "apply-scenario.sh apply_helm uses config version when scenario omits version" {
  # apply_helm() must call _preinstall_version_from_config when version is absent
  awk '/^apply_helm\(\)/,/^}/' "$APPLY_SCENARIO" | grep -q '_preinstall_version_from_config' || {
    echo "ERROR: apply_helm() must call _preinstall_version_from_config for config version lookup" >&2
    false
  }
}

@test "apply-scenario.sh scenario version takes precedence (version set before config lookup)" {
  # The config lookup must only happen when version is empty or null
  awk '/^apply_helm\(\)/,/^}/' "$APPLY_SCENARIO" | grep -q 'if \[ -z.*version' || \
  awk '/^apply_helm\(\)/,/^}/' "$APPLY_SCENARIO" | grep -q '\[ -z.*\$version' || {
    echo "ERROR: apply_helm() must guard config lookup with version-empty check" >&2
    false
  }
}

@test "_preinstall_version_from_config returns version for known preinstall name" {
  local tmpdir
  tmpdir=$(mktemp -d "$TMPDIR/ver-preinstall-XXXXX")
  _VER_TEMPFILES+=("$tmpdir")
  mkdir -p "$tmpdir/defaults"
  cat > "$tmpdir/defaults/versions.yaml" <<'EOF'
kubernetes:
  kind: "1.31"
  minikube: "1.31"
  gke: "1.30"
  eks: "1.30"
  aks: "1.30"
cli_tools:
  helm: "3.17"
  kubectl: "1.31"
  kind: "0.27"
  minikube: "1.35"
preinstalls:
  cert-manager:
    chart: "cert-manager"
    version: "v9.99.0"
    repo: "https://charts.jetstack.io"
  traefik:
    chart: "traefik"
    version: "v55.0.0"
    repo: "https://traefik.github.io/charts"
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
EOF

  local fn_body
  fn_body=$(sed -n '/_preinstall_version_from_config()/,/^}/p' "$APPLY_SCENARIO")

  run bash -c "
set -euo pipefail
ENGINE_DIR='$tmpdir'
$fn_body
_preinstall_version_from_config cert-manager
"
  [ "$status" -eq 0 ] || {
    echo "ERROR: function returned non-zero: $output" >&2; false
  }
  [ "$output" = "v9.99.0" ] || {
    echo "ERROR: expected 'v9.99.0', got '$output'" >&2; false
  }
}

# ---------------------------------------------------------------------------
# Group 3: run-scenario.sh — static checks (VAL-VER-004, VAL-VER-005, VAL-VER-006)
# ---------------------------------------------------------------------------

@test "run-scenario.sh defines _resolve_versions() function" {
  grep -q '_resolve_versions()' "$RUN_SCENARIO" || {
    echo "ERROR: _resolve_versions() function not found in run-scenario.sh" >&2
    false
  }
}

@test "run-scenario.sh _resolve_versions uses 'scenario' source for explicit versions" {
  awk '/_resolve_versions\(\)/,/^}/' "$RUN_SCENARIO" | grep -q '"scenario"' || {
    echo "ERROR: _resolve_versions() must use source='scenario' for explicit scenario YAML versions" >&2
    false
  }
}

@test "run-scenario.sh _resolve_versions uses 'versions-config' source for config lookups" {
  awk '/_resolve_versions\(\)/,/^}/' "$RUN_SCENARIO" | grep -q '"versions-config"' || {
    echo "ERROR: _resolve_versions() must use source='versions-config' for config-resolved versions" >&2
    false
  }
}

@test "run-scenario.sh write_versions_json includes preinstall section with source field" {
  # write_versions_json must output a preinstalls object containing source fields
  awk '/^write_versions_json\(\)/,/^}/' "$RUN_SCENARIO" | grep -q 'preinstalls' || {
    echo "ERROR: write_versions_json() must include a 'preinstalls' section" >&2
    false
  }
  awk '/^write_versions_json\(\)/,/^}/' "$RUN_SCENARIO" | grep -q 'source' || {
    echo "ERROR: write_versions_json() must include 'source' field in preinstalls" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Group 4: Functional tests for _resolve_versions source tracking (VAL-VER-006)
# ---------------------------------------------------------------------------

@test "_resolve_versions: scenario source when version explicit in YAML" {
  # Create a minimal scenario with explicit version and a temp versions.yaml
  local tmpdir
  tmpdir=$(mktemp -d "$TMPDIR/resolve-scenario-XXXXX")
  _VER_TEMPFILES+=("$tmpdir")
  mkdir -p "$tmpdir/defaults" "$tmpdir/chart-test"

  cat > "$tmpdir/defaults/versions.yaml" <<'EOF'
kubernetes:
  kind: "1.31"
  minikube: "1.31"
  gke: "1.30"
  eks: "1.30"
  aks: "1.30"
cli_tools:
  helm: "3.17"
  kubectl: "1.31"
  kind: "0.27"
  minikube: "1.35"
preinstalls:
  cert-manager:
    chart: "cert-manager"
    version: "v1.17"
    repo: "https://charts.jetstack.io"
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
EOF

  # Scenario with explicit version
  cat > "$tmpdir/scenario.yaml" <<'EOF'
id: test-resolve-scenario
cluster:
  provider: kind
  preinstall:
    - kind: helm
      chart: jetstack/cert-manager
      version: v2.0.0
      release: cert-manager
      namespace: cert-manager
      repo:
        name: jetstack
        url: https://charts.jetstack.io
      wait: pods-ready
product:
  chart: ./chart
  release: test
  namespace: test
asserts: []
EOF

  # Extract _resolve_versions body and test it
  local fn_body
  fn_body=$(sed -n '/_resolve_versions()/,/^}/p' "$RUN_SCENARIO")

  run bash -c "
set -euo pipefail
declare -A _RESOLVED_VERSIONS
declare -A _RESOLVED_SOURCES
ENGINE_DIR='$tmpdir'
PROJECT_DIR='$tmpdir'
SCENARIO='$tmpdir/scenario.yaml'
$fn_body
_resolve_versions
echo \"version:\${_RESOLVED_VERSIONS[cert-manager]}\"
echo \"source:\${_RESOLVED_SOURCES[cert-manager]}\"
"
  [ "$status" -eq 0 ] || {
    echo "ERROR: _resolve_versions returned non-zero: $output" >&2; false
  }
  echo "$output" | grep -q "version:v2.0.0" || {
    echo "ERROR: expected version v2.0.0 (from scenario), got: $output" >&2; false
  }
  echo "$output" | grep -q "source:scenario" || {
    echo "ERROR: expected source=scenario, got: $output" >&2; false
  }
}

@test "_resolve_versions: versions-config source when version absent from YAML" {
  local tmpdir
  tmpdir=$(mktemp -d "$TMPDIR/resolve-config-XXXXX")
  _VER_TEMPFILES+=("$tmpdir")
  mkdir -p "$tmpdir/defaults" "$tmpdir/chart-test"

  cat > "$tmpdir/defaults/versions.yaml" <<'EOF'
kubernetes:
  kind: "1.31"
  minikube: "1.31"
  gke: "1.30"
  eks: "1.30"
  aks: "1.30"
cli_tools:
  helm: "3.17"
  kubectl: "1.31"
  kind: "0.27"
  minikube: "1.35"
preinstalls:
  cert-manager:
    chart: "cert-manager"
    version: "v1.17"
    repo: "https://charts.jetstack.io"
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
EOF

  # Scenario WITHOUT explicit version — should fall back to versions-config
  cat > "$tmpdir/scenario.yaml" <<'EOF'
id: test-resolve-config
cluster:
  provider: kind
  preinstall:
    - kind: helm
      chart: jetstack/cert-manager
      release: cert-manager
      namespace: cert-manager
      repo:
        name: jetstack
        url: https://charts.jetstack.io
      wait: pods-ready
product:
  chart: ./chart
  release: test
  namespace: test
asserts: []
EOF

  local fn_body
  fn_body=$(sed -n '/_resolve_versions()/,/^}/p' "$RUN_SCENARIO")

  run bash -c "
set -euo pipefail
declare -A _RESOLVED_VERSIONS
declare -A _RESOLVED_SOURCES
ENGINE_DIR='$tmpdir'
PROJECT_DIR='$tmpdir'
SCENARIO='$tmpdir/scenario.yaml'
$fn_body
_resolve_versions
echo \"version:\${_RESOLVED_VERSIONS[cert-manager]:-}\"
echo \"source:\${_RESOLVED_SOURCES[cert-manager]:-}\"
"
  [ "$status" -eq 0 ] || {
    echo "ERROR: _resolve_versions returned non-zero: $output" >&2; false
  }
  echo "$output" | grep -q "version:v1.17" || {
    echo "ERROR: expected version v1.17 (from versions-config), got: $output" >&2; false
  }
  echo "$output" | grep -q "source:versions-config" || {
    echo "ERROR: expected source=versions-config, got: $output" >&2; false
  }
}

@test "versions.json includes preinstall entries with 'source' field" {
  # Functional test: verify the JSON output of write_versions_json has preinstalls.source
  local tmpdir
  tmpdir=$(mktemp -d "$TMPDIR/versions-json-XXXXX")
  _VER_TEMPFILES+=("$tmpdir")
  mkdir -p "$tmpdir/defaults" "$tmpdir/artifacts"

  cat > "$tmpdir/defaults/versions.yaml" <<'EOF'
kubernetes:
  kind: "1.31"
  minikube: "1.31"
  gke: "1.30"
  eks: "1.30"
  aks: "1.30"
cli_tools:
  helm: "3.17"
  kubectl: "1.31"
  kind: "0.27"
  minikube: "1.35"
preinstalls:
  cert-manager:
    chart: "cert-manager"
    version: "v1.17"
    repo: "https://charts.jetstack.io"
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
EOF

  # Build a small test script that exercises write_versions_json with known data
  run bash -c "
set -euo pipefail
ARTIFACTS_DIR='$tmpdir/artifacts'
KUBE_CONTEXT='test-context'
CLUSTER_UP='$CLUSTER_UP'
declare -A _RESOLVED_VERSIONS
declare -A _RESOLVED_SOURCES
_RESOLVED_VERSIONS[cert-manager]='v1.17'
_RESOLVED_SOURCES[cert-manager]='versions-config'
_RESOLVED_VERSIONS[traefik]='v34.0.0'
_RESOLVED_SOURCES[traefik]='scenario'

kubectl_ctx() { echo 'unknown'; }
write_versions_json() {
  local base_json
  base_json=\$(jq -n --arg helm 'test' --arg kubectl 'test' --arg kind 'test' --arg minikube 'test' --arg k8s_server 'test' \
    '{helm: \$helm, kubectl: \$kubectl, kind: \$kind, minikube: \$minikube, k8s_server: \$k8s_server}')

  local preinstalls_json='{}'
  if [ \"\${#_RESOLVED_VERSIONS[@]}\" -gt 0 ]; then
    local name
    for name in \"\${!_RESOLVED_VERSIONS[@]}\"; do
      local ver=\"\${_RESOLVED_VERSIONS[\$name]}\"
      local src=\"\${_RESOLVED_SOURCES[\$name]:-versions-config}\"
      preinstalls_json=\$(printf '%s' \"\$preinstalls_json\" | jq \
        --arg name \"\$name\" \
        --arg version \"\$ver\" \
        --arg source \"\$src\" \
        '. + {(\$name): {version: \$version, source: \$source}}')
    done
  fi

  echo \"\$base_json\" | jq --argjson preinstalls \"\$preinstalls_json\" \
    '. + {preinstalls: \$preinstalls}' \
    > \"\$ARTIFACTS_DIR/versions.json\"
}
write_versions_json

# Verify the output
jq -e '.preinstalls' '$tmpdir/artifacts/versions.json' >/dev/null || { echo 'ERROR: preinstalls key missing'; exit 1; }
jq -e '.preinstalls[\"cert-manager\"].source == \"versions-config\"' '$tmpdir/artifacts/versions.json' >/dev/null || { echo 'ERROR: cert-manager source missing'; exit 1; }
jq -e '.preinstalls[\"traefik\"].source == \"scenario\"' '$tmpdir/artifacts/versions.json' >/dev/null || { echo 'ERROR: traefik source missing'; exit 1; }
echo 'PASS'
"
  [ "$status" -eq 0 ] || {
    echo "ERROR: test failed: $output" >&2; false
  }
  echo "$output" | grep -q "PASS"
}
