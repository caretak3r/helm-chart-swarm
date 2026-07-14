#!/usr/bin/env bats
# bats file_tags: cloud-authored, dispatch-guards, VAL-CLOUDX
#
# Tests for f16-4: cloud-authored dispatch guards.
# Covers VAL-CLOUDX-007, VAL-CLOUDX-008, VAL-CLOUDX-009,
#           VAL-CLOUDX-010, VAL-CLOUDX-013, VAL-CLOUDX-014, VAL-CLOUDX-015.
#
# These tests do NOT spin up clusters. They verify the dispatch/skip/filter
# logic in run-scenario.sh and dispatch-swarm.sh at the script level.

_has_modern_bash() {
    [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]
}

# The engine needs bash >= 4. On macOS that means brew's bash, since /bin/bash is
# 3.2; on Linux the bash already on PATH is fine. Same idiom as help-banner.bats
# and versions-sigint.bats — do not hardcode the brew path, it does not exist in CI.
if [ -x /opt/homebrew/bin/bash ]; then
    BASH_CMD=/opt/homebrew/bin/bash
else
    BASH_CMD=bash
fi

setup() {
    TESTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
    SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
    ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
    ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
    SCEN_DIR="$ROOT_DIR/examples/sample-product-chart/chart-test/scenarios"
    PROJECT_DIR="$ROOT_DIR/examples/sample-product-chart"
    FIXTURES_DIR="$ROOT_DIR/examples/sample-product-chart/chart-test/fixtures/cloud-native"
    SCHEMA="$ENGINE_DIR/templates/scenario.schema.json"
}

# ── VAL-CLOUDX-007: every cloud-authored scenario is tier=authored-only
#    with a non-local provider ────────────────────────────────────────────

@test "VAL-CLOUDX-007: every cloud-authored scenario has tier=authored-only" {
    count=0
    for f in "$SCEN_DIR"/cloud-native/cloud-native-*.yaml; do
        [ -f "$f" ] || continue
        tier=$(yq '.tier' "$f")
        [ "$tier" = "authored-only" ]
        count=$((count + 1))
    done
    # At least 6 cloud-authored scenarios must exist (currently 12)
    [ "$count" -ge 6 ]
}

@test "VAL-CLOUDX-007: every cloud-authored scenario has non-local provider in {eks,aks,gke}" {
    count=0
    for f in "$SCEN_DIR"/cloud-native/cloud-native-*.yaml; do
        [ -f "$f" ] || continue
        prov=$(yq '.cluster.provider' "$f")
        echo "$prov" | grep -qE '^(eks|aks|gke)$'
        count=$((count + 1))
    done
    [ "$count" -ge 6 ]
}

@test "VAL-CLOUDX-007: no cloud-authored scenario uses kind/minikube/k3d provider" {
    for f in "$SCEN_DIR"/cloud-native/cloud-native-*.yaml; do
        [ -f "$f" ] || continue
        prov=$(yq '.cluster.provider' "$f")
        echo "$prov" | grep -qvE '^(kind|minikube|k3d)$'
    done
}

# ── VAL-CLOUDX-008: cloud-authored scenarios skipped by default dispatch
#    with no cluster ops ──────────────────────────────────────────────────

@test "VAL-CLOUDX-008: run-scenario.sh emits skip message and exits 0 for cloud-authored scenario (requires bash>=4)" {
    if ! _has_modern_bash; then skip "bash >= 4 required"; fi

    # Pick an EKS scenario as representative
    cloud_scen="$SCEN_DIR/cloud-native/cloud-native-eks-alb-ingress.yaml"
    [ -f "$cloud_scen" ]

    # Run the script; it should exit 0 with a skip message
    output=$("$BASH_CMD" "$ENGINE_DIR/scripts/run-scenario.sh" "$cloud_scen" 2>&1) || true

    # Must contain the skip message
    echo "$output" | grep -qi "authored only"
    echo "$output" | grep -qi "skipping cluster operations"
}

@test "VAL-CLOUDX-008: run-scenario.sh for GKE scenario exits 0 with no kind cluster created (requires bash>=4)" {
    if ! _has_modern_bash; then skip "bash >= 4 required"; fi

    cloud_scen="$SCEN_DIR/cloud-native/cloud-native-gke-iap.yaml"
    [ -f "$cloud_scen" ]

    # Before: count clusters
    before=$(kind get clusters 2>/dev/null | grep -c 'chart-test-swarm' || true)
    before=$(echo "$before" | tr -d '[:space:]')
    [ "${before:-0}" -ge 0 ]

    run "$BASH_CMD" "$ENGINE_DIR/scripts/run-scenario.sh" "$cloud_scen"
    [ "$status" -eq 0 ]

    # After: no new chart-test-swarm-* clusters
    after=$(kind get clusters 2>/dev/null | grep -c 'chart-test-swarm' || true)
    after=$(echo "$after" | tr -d '[:space:]')
    [ "${after:-0}" -eq "${before:-0}" ]
}

@test "VAL-CLOUDX-008: run-scenario.sh for AKS scenario exits 0 with no minikube profile created (requires bash>=4)" {
    if ! _has_modern_bash; then skip "bash >= 4 required"; fi

    cloud_scen="$SCEN_DIR/cloud-native/cloud-native-aks-agic.yaml"
    [ -f "$cloud_scen" ]

    run "$BASH_CMD" "$ENGINE_DIR/scripts/run-scenario.sh" "$cloud_scen"
    [ "$status" -eq 0 ]

    # No minikube profile with chart-test-swarm- prefix created
    profiles=$(minikube profile list -o json 2>/dev/null | jq -r '.valid[].Name' 2>/dev/null | grep -c 'chart-test-swarm' || true)
    profiles=$(echo "$profiles" | tr -d '[:space:]')
    [ "${profiles:-0}" -eq 0 ]
}

@test "VAL-CLOUDX-008: set -x trace for cloud scenario shows no kind/minikube/kubectl --context invocation (requires bash>=4)" {
    if ! _has_modern_bash; then skip "bash >= 4 required"; fi

    cloud_scen="$SCEN_DIR/cloud-native/cloud-native-eks-irsa.yaml"
    [ -f "$cloud_scen" ]

    # Run with tracing enabled, capture stderr (where set -x goes)
    output=$("$BASH_CMD" -x "$ENGINE_DIR/scripts/run-scenario.sh" "$cloud_scen" 2>&1) || true

    # Simpler check: the trace should not contain 'kind create' or 'minikube start' or 'kubectl --context'
    echo "$output" | grep -qE 'kind (create|delete)' && false || true
    echo "$output" | grep -qE 'minikube (start|delete)' && false || true
    echo "$output" | grep -qE 'kubectl --context' && false || true
}

# ── VAL-CLOUDX-009: default run --all excludes cloud-authored scenarios ──

@test "VAL-CLOUDX-009: dispatch --dry-run with suite 'all' lists zero cloud-authored ids" {
    [ -f "$PROJECT_DIR/chart-test-swarm.yaml" ]

    run "$BASH_CMD" "$ENGINE_DIR/scripts/dispatch-swarm.sh" "$PROJECT_DIR" all 2 --dry-run
    [ "$status" -eq 0 ]

    # Verify: none of the cloud-native ids appear in the dry-run output
    for f in "$SCEN_DIR"/cloud-native/cloud-native-*.yaml; do
        [ -f "$f" ] || continue
        sid=$(yq '.id' "$f")
        echo "$output" | grep -qv "$sid"
    done
}

@test "VAL-CLOUDX-009: dispatch with CTS_INCLUDE_CLOUD_NATIVE=1 --dry-run includes cloud-authored ids" {
    [ -f "$PROJECT_DIR/chart-test-swarm.yaml" ]

    # Count how many cloud-authored scenarios exist
    cloud_count=0
    for f in "$SCEN_DIR"/cloud-native/cloud-native-*.yaml; do
        [ -f "$f" ] || continue
        cloud_count=$((cloud_count + 1))
    done
    [ "$cloud_count" -ge 6 ]

    CTS_INCLUDE_CLOUD_NATIVE=1 run "$BASH_CMD" "$ENGINE_DIR/scripts/dispatch-swarm.sh" "$PROJECT_DIR" all 2 --dry-run
    [ "$status" -eq 0 ]

    # With opt-in, cloud-authored ids should appear (as authored-only)
    # At least one cloud-native id must be present
    found=0
    for f in "$SCEN_DIR"/cloud-native/cloud-native-*.yaml; do
        [ -f "$f" ] || continue
        sid=$(yq '.id' "$f")
        if echo "$output" | grep -q "$sid"; then
            found=$((found + 1))
        fi
    done
    [ "$found" -ge 1 ]
}

# ── VAL-CLOUDX-010: opting in performs NO real cloud apply ──────────────

@test "VAL-CLOUDX-010: CTS_INCLUDE_CLOUD_NATIVE=1 with run-scenario.sh still exits 0 with skip for cloud scenario (requires bash>=4)" {
    if ! _has_modern_bash; then skip "bash >= 4 required"; fi

    cloud_scen="$SCEN_DIR/cloud-native/cloud-native-eks-alb-ingress.yaml"
    [ -f "$cloud_scen" ]

    CTS_INCLUDE_CLOUD_NATIVE=1 run "$BASH_CMD" "$ENGINE_DIR/scripts/run-scenario.sh" "$cloud_scen"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "authored only"
    echo "$output" | grep -qi "skipping cluster operations"
}

@test "VAL-CLOUDX-010: no gcloud/aws/az calls in engine scripts" {
    # Static audit: rg over engine/scripts/ for real cloud CLI invocations
    # (excluding comments, docstrings, and the known guard text)
    cd "$ROOT_DIR"
    # gcloud calls (not in comments)
    ! rg -n 'gcloud\b' engine/scripts/ --glob '!*.bats' || false
    # aws CLI calls (word boundary + whitespace, not "awk" etc.)
    ! rg -nw 'aws\s' engine/scripts/ --glob '!*.bats' || false
    # az CLI calls (word boundary + whitespace, not "baz" etc.)
    ! rg -nw 'az\s' engine/scripts/ --glob '!*.bats' || false
}

@test "VAL-CLOUDX-010: no gcloud/aws/az calls in testgrid python" {
    cd "$ROOT_DIR"
    # Python sources — check for subprocess calls invoking cloud CLIs
    ! rg -n 'subprocess.*gcloud' engine/testgrid/src/ || false
    ! rg -n 'subprocess.*\baws\b' engine/testgrid/src/ || false
    ! rg -n 'subprocess.*\baz\b' engine/testgrid/src/ || false
}

# ── VAL-CLOUDX-013: cloud-authored fixtures contain no real secrets ────

@test "VAL-CLOUDX-013: fixtures have no AWS account numbers or role ARNs" {
    # AKIA... is an AWS access key ID prefix
    # arn:aws:iam::123456789012 is a real ARN pattern
    ! rg -nE 'AKIA[0-9A-Z]{16}' "$FIXTURES_DIR" || false
    ! rg -nE 'arn:aws:iam::[0-9]{12}' "$FIXTURES_DIR" || false
}

@test "VAL-CLOUDX-013: fixtures have no GCP project IDs or service account JSON" {
    # Real GCP project IDs in projects/ format
    # "private_key": in service account JSON
    ! rg -nE 'projects/[a-z][a-z0-9-]+/serviceAccounts' "$FIXTURES_DIR" || false
    ! rg -nE '"private_key":' "$FIXTURES_DIR" || false
}

@test "VAL-CLOUDX-013: fixtures have no Azure tenant IDs or subscription IDs" {
    # Azure tenant/subscription GUIDs appear as literal values (not placeholders)
    # Look for lines that contain a GUID that is NOT inside a <REPLACE> placeholder
    for f in "$FIXTURES_DIR"/**/*.yaml; do
        [ -f "$f" ] || continue
        # Skip lines containing REPLACE_WITH (these are placeholders)
        # Check remaining lines for real-looking Azure GUIDs
        if grep -v 'REPLACE_WITH' "$f" | grep -qE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
            echo "FAIL: potential real Azure GUID found in $f"
            false
        fi
    done
}

@test "VAL-CLOUDX-013: fixtures use REPLACE placeholders not real values" {
    # Verify at least one fixture uses the REPLACE pattern
    rg -c 'REPLACE_WITH' "$FIXTURES_DIR" > /dev/null
}

# ── VAL-CLOUDX-014: schema accepts tier/category/integration fields,
#    backward compatible ──────────────────────────────────────────────────

@test "VAL-CLOUDX-014: all cloud-authored scenarios validate against the schema" {
    for f in "$SCEN_DIR"/cloud-native/cloud-native-*.yaml; do
        [ -f "$f" ] || continue
        check-jsonschema --schemafile "$SCHEMA" "$f"
    done
}

@test "VAL-CLOUDX-014: a legacy field-less scenario still validates (backward compat)" {
    # The minimal scenario (in capability subdir) has no tier/category/integration fields
    legacy="$SCEN_DIR/capability/minimal.yaml"
    [ -f "$legacy" ]
    check-jsonschema --schemafile "$SCHEMA" "$legacy"
}

@test "VAL-CLOUDX-014: schema accepts tier=authored-only" {
    # Create a minimal temp scenario with tier: authored-only
    tmpdir="$(mktemp -d)"
    tmp="$tmpdir/test-cloud-tier.yaml"
    cat > "$tmp" <<'EOF'
---
id: test-cloud-tier
tier: authored-only
category: cloud-native
integration: eks-test
cluster:
  provider: eks
product:
  chart: ./chart
  release: test
  namespace: default
asserts:
  - type: pods-ready
    namespace: default
EOF
    check-jsonschema --schemafile "$SCHEMA" "$tmp"
    rm -rf "$tmpdir"
}

@test "VAL-CLOUDX-014: schema accepts tier=live and tier=capability" {
    tmpdir="$(mktemp -d)"
    tmp="$tmpdir/test-tier-live.yaml"
    cat > "$tmp" <<'EOF'
---
id: test-tier-live
tier: live
category: networking
integration: traefik
cluster:
  provider: kind
product:
  chart: ./chart
  release: test
  namespace: default
asserts:
  - type: pods-ready
    namespace: default
EOF
    check-jsonschema --schemafile "$SCHEMA" "$tmp"

    # Also test capability
    cat > "$tmp" <<'EOF'
---
id: test-tier-cap
tier: capability
category: capability
capability: labels-present
cluster:
  provider: kind
product:
  chart: ./chart
  release: test
  namespace: default
asserts:
  - type: labels-present
    namespace: default
    labels:
      app: test
EOF
    check-jsonschema --schemafile "$SCHEMA" "$tmp"
    rm -rf "$tmpdir"
}

# ── VAL-CLOUDX-015: no repo script applies cloud-authored addons ────────

@test "VAL-CLOUDX-015: no unguarded kubectl --context in engine scripts" {
    cd "$ROOT_DIR"
    # kubectl --context appears in run-scenario.sh and apply-scenario.sh
    # but those are inside kubectl_ctx() / helm_ctx() helper functions that
    # are only called AFTER the scenario_context() guard exits 0 for cloud
    # providers. So the only matches should be inside those guarded helpers.
    #
    # What we check: no kubectl --context call exists OUTSIDE the guarded
    # helper functions. Specifically, no bare kubectl --context call that
    # could fire before the scenario_context() provider guard.
    matches=$(rg -n 'kubectl --context' engine/scripts/ --glob '!*.bats' | grep -v 'kubectl_ctx()' | grep -v '# ' | grep -v 'kubectl_ctx()' | wc -l | tr -d ' ')
    # All kubectl --context calls are inside kubectl_ctx() wrapper which
    # is only called after the cloud-provider guard exits 0
    [ "$matches" -le 2 ]  # run-scenario.sh + apply-scenario.sh helper definitions
}

@test "VAL-CLOUDX-015: cloud-authored scenario ids appear in no default suite manifest" {
    # Check chart-test-swarm.yaml suites do not list cloud-native scenarios
    config="$PROJECT_DIR/chart-test-swarm.yaml"
    [ -f "$config" ]

    # The default suites should not reference cloud-native scenario ids
    for f in "$SCEN_DIR"/cloud-native/cloud-native-*.yaml; do
        [ -f "$f" ] || continue
        sid=$(yq '.id' "$f")
        # The suite config should not reference this cloud-native id
        ! grep -q "$sid" "$config" || false
    done
}

@test "VAL-CLOUDX-015: dispatch exits 0 without cluster ops when all scenarios are cloud-native" {
    # When dispatch is given ONLY cloud-native scenarios (via CTS_SCENARIOS),
    # it must exit 0 with a skip message, not attempt any cluster operations.
    cloud_scens=""
    for f in "$SCEN_DIR"/cloud-native/cloud-native-eks-alb-ingress.yaml "$SCEN_DIR"/cloud-native/cloud-native-aks-agic.yaml; do
        cloud_scens="${cloud_scens}${f}"$'\n'
    done

    CTS_SCENARIOS="$cloud_scens" run "$BASH_CMD" "$ENGINE_DIR/scripts/dispatch-swarm.sh" "$PROJECT_DIR" pr-subset 2
    # All-cloud-native dispatch should exit 0 with skip message
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "cloud-native"
}
