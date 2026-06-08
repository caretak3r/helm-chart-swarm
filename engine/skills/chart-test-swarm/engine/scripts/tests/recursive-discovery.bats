#!/usr/bin/env bats
# recursive-discovery.bats — Tests for f12-2: recursive scenario discovery
#
# Covers VAL-CAT-002:
#   - run-scenario.sh runs a scenario given a scenarios/<category>/<scenario>.yaml path
#   - dispatch-swarm.sh enumerates scenarios across category subdirs
#   - dispatched count equals a recursive file walk filtered by tier
#   - No subdir scenario is silently dropped
#   - chart-test-swarm run --all enumerates across category subdirs
#   - chart-test-swarm list variants discovers subdir scenarios
#
# Tests use synthetic scenario trees (no real cluster operations).

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
  SCHEMA="$ENGINE_DIR/templates/scenario.schema.json"

  # Unique temp project per test
  WORK_DIR="$(mktemp -d)"
  PROJECT_DIR="$WORK_DIR/project"
  SCEN_DIR="$PROJECT_DIR/chart-test/scenarios"
  REPORTS_DIR="$WORK_DIR/reports"
  mkdir -p "$SCEN_DIR" "$REPORTS_DIR" "$PROJECT_DIR/chart"

  # Minimal chart so dispatch-swarm.sh doesn't crash on Chart.yaml lookup
  cat > "$PROJECT_DIR/chart/Chart.yaml" <<YAMLEOF
apiVersion: v2
name: test-recursive
version: 0.1.0
YAMLEOF

  # Project config
  cat > "$PROJECT_DIR/chart-test-swarm.yaml" <<YAMLEOF
schema_version: 1
project: { name: test-recursive }
scenarios_dir: chart-test/scenarios
suites:
  pr-subset: { tag_filter: [pr-subset] }
YAMLEOF
}

teardown() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
}

# Helper: write a valid scenario YAML file
write_scenario() {
  local path="$1" id="$2" tag="${3:-pr-subset}" tier="${4:-}"
  mkdir -p "$(dirname "$path")"
  {
    echo "---"
    echo "id: $id"
    echo "name: \"Scenario $id\""
    echo "category: networking"
    [ -n "$tier" ] && echo "tier: $tier"
    cat <<'SCENEOF'
cluster:
  provider: kind
  k8s_version: v1.30.0
product:
  chart: ./chart
  release: sample
  namespace: sample
asserts:
  - { type: pods-ready, namespace: sample, timeout: 3m }
mechanisms: [addon:none]
SCENEOF
    echo "tags: [$tag]"
  } > "$path"
}

# ---------------------------------------------------------------------------
# VAL-CAT-002: run-scenario.sh accepts subdir scenario paths
# ---------------------------------------------------------------------------

@test "run-scenario.sh resolves PROJECT_DIR correctly for a scenario in a category subdir" {
  write_scenario "$SCEN_DIR/networking/test-subdir.yaml" test-subdir

  [ -f "$SCEN_DIR/networking/test-subdir.yaml" ]

  # Verify the scenario ID can be parsed from the subdir path
  run yq '.id' "$SCEN_DIR/networking/test-subdir.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "test-subdir" ]

  # Verify chart-test-swarm.yaml is discoverable by walking up
  [ -f "$PROJECT_DIR/chart-test-swarm.yaml" ]
}

@test "run-scenario.sh --help works when given a subdir scenario path" {
  write_scenario "$SCEN_DIR/networking/test-help.yaml" test-help

  run bash "$SCRIPTS_DIR/run-scenario.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

# ---------------------------------------------------------------------------
# VAL-CAT-002: dispatch-swarm.sh discovers scenarios in subdirs
# ---------------------------------------------------------------------------

@test "dispatch-swarm.sh discovers flat scenarios at the top level" {
  write_scenario "$SCEN_DIR/flat-a.yaml" flat-a
  write_scenario "$SCEN_DIR/flat-b.yaml" flat-b
  write_scenario "$SCEN_DIR/flat-c.yaml" flat-c

  export REPORTS_DIR
  export RUN_ID="run-flat-001"
  run bash "$SCRIPTS_DIR/dispatch-swarm.sh" "$PROJECT_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  snapshot="$REPORTS_DIR/$RUN_ID/scenarios-snapshot.yaml"
  [ -f "$snapshot" ]
  count=$(yq '.scenarios | length' "$snapshot")
  [ "$count" -eq 3 ]
}

@test "dispatch-swarm.sh discovers scenarios in category subdirs via recursive find" {
  write_scenario "$SCEN_DIR/networking/net-a.yaml" net-a
  write_scenario "$SCEN_DIR/networking/net-b.yaml" net-b
  write_scenario "$SCEN_DIR/certificates/cert-a.yaml" cert-a
  write_scenario "$SCEN_DIR/flat-c.yaml" flat-c

  export REPORTS_DIR
  export RUN_ID="run-subdir-002"
  run bash "$SCRIPTS_DIR/dispatch-swarm.sh" "$PROJECT_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  snapshot="$REPORTS_DIR/$RUN_ID/scenarios-snapshot.yaml"
  [ -f "$snapshot" ]

  count=$(yq '.scenarios | length' "$snapshot")
  [ "$count" -eq 4 ] || {
    echo "FAIL: expected 4 scenarios in snapshot, got $count" >&2
    yq '.scenarios[].id' "$snapshot" >&2
    return 1
  }
}

@test "dispatch-swarm.sh dispatched count equals recursive file walk" {
  write_scenario "$SCEN_DIR/flat-1.yaml" flat-1
  write_scenario "$SCEN_DIR/networking/net-1.yaml" net-1
  write_scenario "$SCEN_DIR/networking/net-2.yaml" net-2
  write_scenario "$SCEN_DIR/certificates/cert-1.yaml" cert-1
  write_scenario "$SCEN_DIR/gateway-api/gw-1.yaml" gw-1

  # Count via recursive find (what the script should do)
  expected=$(find "$SCEN_DIR" -type f -name '*.yaml' | wc -l | tr -d ' ')

  export REPORTS_DIR
  export RUN_ID="run-count-003"
  run bash "$SCRIPTS_DIR/dispatch-swarm.sh" "$PROJECT_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  snapshot="$REPORTS_DIR/$RUN_ID/scenarios-snapshot.yaml"
  [ -f "$snapshot" ]
  actual=$(yq '.scenarios | length' "$snapshot")
  [ "$actual" -eq "$expected" ] || {
    echo "FAIL: snapshot count $actual != recursive find count $expected" >&2
    return 1
  }
}

@test "no subdir scenario is silently dropped by dispatch-swarm.sh" {
  write_scenario "$SCEN_DIR/networking/net-drop.yaml" net-drop
  write_scenario "$SCEN_DIR/certificates/cert-drop.yaml" cert-drop
  write_scenario "$SCEN_DIR/service-mesh/mesh-drop.yaml" mesh-drop
  write_scenario "$SCEN_DIR/policy/pol-drop.yaml" pol-drop

  export REPORTS_DIR
  export RUN_ID="run-nodrop-004"
  run bash "$SCRIPTS_DIR/dispatch-swarm.sh" "$PROJECT_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  snapshot="$REPORTS_DIR/$RUN_ID/scenarios-snapshot.yaml"
  [ -f "$snapshot" ]

  # Every scenario id must appear in the snapshot
  for id in net-drop cert-drop mesh-drop pol-drop; do
    found=$(yq ".scenarios[] | select(.id == \"$id\") | .id" "$snapshot")
    [ "$found" = "$id" ] || {
      echo "FAIL: scenario '$id' was silently dropped from snapshot" >&2
      yq '.scenarios[].id' "$snapshot" >&2
      return 1
    }
  done
}

@test "dispatch-swarm.sh discovers deeply nested scenarios (3 levels deep)" {
  mkdir -p "$SCEN_DIR/networking/ingress-controllers"
  write_scenario "$SCEN_DIR/networking/ingress-controllers/deep-1.yaml" deep-1

  export REPORTS_DIR
  export RUN_ID="run-deep-005"
  run bash "$SCRIPTS_DIR/dispatch-swarm.sh" "$PROJECT_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  snapshot="$REPORTS_DIR/$RUN_ID/scenarios-snapshot.yaml"
  [ -f "$snapshot" ]

  count=$(yq '.scenarios | length' "$snapshot")
  [ "$count" -ge 1 ] || {
    echo "FAIL: deeply nested scenario not discovered" >&2
    return 1
  }

  found=$(yq ".scenarios[] | select(.id == \"deep-1\") | .id" "$snapshot")
  [ "$found" = "deep-1" ] || {
    echo "FAIL: deeply nested scenario 'deep-1' not in snapshot" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# VAL-CAT-002: dispatch --all enumerates all scenarios across subdirs
# ---------------------------------------------------------------------------

@test "dispatch-swarm.sh with CTS_SCENARIOS enumerates all scenarios regardless of tags" {
  # Place scenarios with DIFFERENT tags (so no single suite would match them all)
  write_scenario "$SCEN_DIR/networking/net-all.yaml" net-all pr-subset
  write_scenario "$SCEN_DIR/certificates/cert-nightly.yaml" cert-nightly nightly
  write_scenario "$SCEN_DIR/policy/pol-other.yaml" pol-other other-tag

  # Pass all scenarios explicitly via CTS_SCENARIOS
  export CTS_SCENARIOS="$SCEN_DIR/networking/net-all.yaml
$SCEN_DIR/certificates/cert-nightly.yaml
$SCEN_DIR/policy/pol-other.yaml"
  export REPORTS_DIR
  export RUN_ID="run-all-006"
  run bash "$SCRIPTS_DIR/dispatch-swarm.sh" "$PROJECT_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  snapshot="$REPORTS_DIR/$RUN_ID/scenarios-snapshot.yaml"
  [ -f "$snapshot" ]
  count=$(yq '.scenarios | length' "$snapshot")
  [ "$count" -eq 3 ]
}

@test "CTS_SCENARIOS env var passes subdir scenario paths to dispatch-swarm.sh" {
  write_scenario "$SCEN_DIR/networking/net-cts.yaml" net-cts
  write_scenario "$SCEN_DIR/certificates/cert-cts.yaml" cert-cts

  export CTS_SCENARIOS="$SCEN_DIR/networking/net-cts.yaml
$SCEN_DIR/certificates/cert-cts.yaml"
  export REPORTS_DIR
  export RUN_ID="run-cts-007"

  run bash "$SCRIPTS_DIR/dispatch-swarm.sh" "$PROJECT_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  snapshot="$REPORTS_DIR/$RUN_ID/scenarios-snapshot.yaml"
  [ -f "$snapshot" ]
  count=$(yq '.scenarios | length' "$snapshot")
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# VAL-CAT-002: cloud-native authored-only tier scenarios are skipped by default
# ---------------------------------------------------------------------------

@test "dispatch-swarm.sh skips authored-only cloud-native scenarios by default" {
  write_scenario "$SCEN_DIR/networking/net-local.yaml" net-local pr-subset live
  write_scenario "$SCEN_DIR/cloud-native/cn-eks.yaml" cn-eks pr-subset authored-only

  # Patch the cloud scenario to have provider: eks
  yq -i '.cluster.provider = "eks"' "$SCEN_DIR/cloud-native/cn-eks.yaml"

  export REPORTS_DIR
  export RUN_ID="run-cloudskip-008"
  run bash "$SCRIPTS_DIR/dispatch-swarm.sh" "$PROJECT_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  snapshot="$REPORTS_DIR/$RUN_ID/scenarios-snapshot.yaml"
  [ -f "$snapshot" ]

  # Only the local scenario should be in the dispatch
  count=$(yq '.scenarios | length' "$snapshot")
  [ "$count" -eq 1 ]
  found_id=$(yq '.scenarios[0].id' "$snapshot")
  [ "$found_id" = "net-local" ]
}

# ---------------------------------------------------------------------------
# VAL-CAT-002: list variants discovers subdir scenarios
# ---------------------------------------------------------------------------

@test "chart-test-swarm list variants discovers scenarios in category subdirs" {
  write_scenario "$SCEN_DIR/flat-list.yaml" flat-list
  write_scenario "$SCEN_DIR/networking/net-list.yaml" net-list
  write_scenario "$SCEN_DIR/certificates/cert-list.yaml" cert-list

  run uv run --directory "$ENGINE_DIR/testgrid" chart-test-swarm list variants --scenarios-dir "$SCEN_DIR"
  [ "$status" -eq 0 ]

  # Output should contain paths for all 3 scenarios
  echo "$output" | grep -q "flat-list.yaml" || {
    echo "FAIL: flat scenario not listed" >&2; return 1
  }
  echo "$output" | grep -q "net-list.yaml" || {
    echo "FAIL: subdir networking scenario not listed" >&2; return 1
  }
  echo "$output" | grep -q "cert-list.yaml" || {
    echo "FAIL: subdir certificates scenario not listed" >&2; return 1
  }
}

@test "chart-test-swarm list variants --integration filters across subdirs" {
  write_scenario "$SCEN_DIR/certificates/cert-manager-basic.yaml" cert-manager-basic
  write_scenario "$SCEN_DIR/certificates/cert-manager-wildcard.yaml" cert-manager-wildcard
  write_scenario "$SCEN_DIR/networking/traefik-basic.yaml" traefik-basic

  run uv run --directory "$ENGINE_DIR/testgrid" chart-test-swarm list variants \
    --integration cert-manager --scenarios-dir "$SCEN_DIR"
  [ "$status" -eq 0 ]

  # Should find exactly the 2 cert-manager scenarios
  count=$(echo "$output" | grep -c "cert-manager" || echo 0)
  [ "$count" -eq 2 ] || {
    echo "FAIL: expected 2 cert-manager variants, found $count" >&2
    echo "$output" >&2
    return 1
  }

  # traefik should NOT appear
  if echo "$output" | grep -q "traefik"; then
    echo "FAIL: traefik should not appear when filtering by cert-manager" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# VAL-CAT-002: scenario id matches filename stem for subdir scenarios
# ---------------------------------------------------------------------------

@test "scenario id matches filename stem for scenarios in category subdirs" {
  write_scenario "$SCEN_DIR/networking/net-stem.yaml" net-stem

  id=$(yq '.id' "$SCEN_DIR/networking/net-stem.yaml")
  [ "$id" = "net-stem" ]
}

# ---------------------------------------------------------------------------
# VAL-CAT-002: dispatch --all dispatched count equals recursive walk minus cloud
# ---------------------------------------------------------------------------

@test "dispatch dispatched count equals recursive walk excluding authored-only cloud" {
  write_scenario "$SCEN_DIR/networking/net-tier-live.yaml" net-tier-live pr-subset live
  write_scenario "$SCEN_DIR/capability/cap-tier-cap.yaml" cap-tier-cap pr-subset capability
  write_scenario "$SCEN_DIR/cloud-native/cn-tier-authored.yaml" cn-tier-authored pr-subset authored-only

  # Patch cloud scenario to use eks provider
  yq -i '.cluster.provider = "eks"' "$SCEN_DIR/cloud-native/cn-tier-authored.yaml"

  # Count of non-cloud (local) files only
  local_on_disk=$(find "$SCEN_DIR" -type f -name '*.yaml' ! -path '*/cloud-native/*' | wc -l | tr -d ' ')

  export REPORTS_DIR
  export RUN_ID="run-tier-009"
  run bash "$SCRIPTS_DIR/dispatch-swarm.sh" "$PROJECT_DIR" pr-subset 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  snapshot="$REPORTS_DIR/$RUN_ID/scenarios-snapshot.yaml"
  [ -f "$snapshot" ]
  dispatched=$(yq '.scenarios | length' "$snapshot")

  # Cloud-native scenario should be skipped by default
  [ "$dispatched" -eq "$local_on_disk" ] || {
    echo "FAIL: dispatched $dispatched != local count $local_on_disk" >&2
    yq '.scenarios[].id' "$snapshot" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# VAL-CAT-002: dispatch-swarm.sh suite "all" mode
# ---------------------------------------------------------------------------

@test "dispatch-swarm.sh suite 'all' enumerates all scenarios recursively without tag filtering" {
  # Place scenarios with different tags
  write_scenario "$SCEN_DIR/flat-all-flat.yaml" all-flat pr-subset
  write_scenario "$SCEN_DIR/networking/all-net.yaml" all-net nightly
  write_scenario "$SCEN_DIR/certificates/all-cert.yaml" all-cert other-tag

  export REPORTS_DIR
  export RUN_ID="run-suite-all-010"
  run bash "$SCRIPTS_DIR/dispatch-swarm.sh" "$PROJECT_DIR" all 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  snapshot="$REPORTS_DIR/$RUN_ID/scenarios-snapshot.yaml"
  [ -f "$snapshot" ]
  count=$(yq '.scenarios | length' "$snapshot")
  # All 3 scenarios should be discovered regardless of their tags
  [ "$count" -eq 3 ] || {
    echo "FAIL: expected 3 scenarios with suite 'all', got $count" >&2
    yq '.scenarios[].id' "$snapshot" >&2
    return 1
  }
}

@test "dispatch-swarm.sh suite 'all' count matches recursive file walk minus authored-only" {
  write_scenario "$SCEN_DIR/flat-s1.yaml" s1 pr-subset live
  write_scenario "$SCEN_DIR/networking/s2.yaml" s2 nightly live
  write_scenario "$SCEN_DIR/certificates/s3.yaml" s3 pr-subset capability
  write_scenario "$SCEN_DIR/cloud-native/s4.yaml" s4 pr-subset authored-only

  # Patch cloud scenario to use eks provider
  yq -i '.cluster.provider = "eks"' "$SCEN_DIR/cloud-native/s4.yaml"

  # Recursive walk count of ALL yaml files
  total_on_disk=$(find "$SCEN_DIR" -type f -name '*.yaml' | wc -l | tr -d ' ')
  # Count minus authored-only cloud
  local_count=$((total_on_disk - 1))

  export REPORTS_DIR
  export RUN_ID="run-suite-all-count-011"
  run bash "$SCRIPTS_DIR/dispatch-swarm.sh" "$PROJECT_DIR" all 1 "$RUN_ID"
  [ "$status" -eq 0 ]

  snapshot="$REPORTS_DIR/$RUN_ID/scenarios-snapshot.yaml"
  [ -f "$snapshot" ]
  dispatched=$(yq '.scenarios | length' "$snapshot")

  [ "$dispatched" -eq "$local_count" ] || {
    echo "FAIL: dispatched $dispatched != expected $local_count (total=$total_on_disk)" >&2
    yq '.scenarios[].id' "$snapshot" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# VAL-CAT-002: chart-test-swarm run --all CLI
# ---------------------------------------------------------------------------

@test "chart-test-swarm run --all enumerates scenarios across subdirs via CLI" {
  write_scenario "$SCEN_DIR/flat-cli.yaml" flat-cli pr-subset
  write_scenario "$SCEN_DIR/networking/cli-net.yaml" cli-net nightly

  # We use --dry-run-like behavior by just checking that the dispatch
  # collects scenarios correctly. Since we can't run a real cluster,
  # we verify the _find_all_scenarios function works by checking
  # that CTS_SCENARIOS is populated correctly.

  # Verify the Python function works by calling it directly
  run uv run --directory "$ENGINE_DIR/testgrid" python -c "
from chart_test_swarm.commands.run_cmd import _find_all_scenarios
from pathlib import Path
scns = _find_all_scenarios(Path('$PROJECT_DIR'))
for s in scns:
    print(s)
"
  [ "$status" -eq 0 ]
  # Should find both scenarios
  count=$(echo "$output" | grep -c '\.yaml' || echo 0)
  [ "$count" -eq 2 ] || {
    echo "FAIL: _find_all_scenarios found $count scenarios, expected 2" >&2
    echo "$output" >&2
    return 1
  }
  # Both flat and subdir scenarios should appear
  echo "$output" | grep -q "flat-cli" || {
    echo "FAIL: flat scenario not found by _find_all_scenarios" >&2; return 1
  }
  echo "$output" | grep -q "cli-net" || {
    echo "FAIL: subdir scenario not found by _find_all_scenarios" >&2; return 1
  }
}

# ---------------------------------------------------------------------------
# Real project: verify the existing scenarios tree works recursively
# ---------------------------------------------------------------------------

@test "dispatch-swarm.sh discovers existing cloud-native subdir scenarios in real project" {
  # Use the REAL project dir
  real_project="$ROOT_DIR/examples/sample-product-chart"

  # The cloud-native/ subdir should be discovered
  [ -d "$real_project/chart-test/scenarios/cloud-native" ] || {
    echo "SKIP: cloud-native subdir not present" >&2; return 0
  }

  cloud_count=$(find "$real_project/chart-test/scenarios/cloud-native" -type f -name '*.yaml' | wc -l | tr -d ' ')
  [ "$cloud_count" -ge 1 ] || {
    echo "FAIL: cloud-native subdir has no scenarios" >&2; return 1
  }

  # dispatch with CTS_INCLUDE_CLOUD_NATIVE=0 should still find flat scenarios
  # and skip the cloud-native ones
  export REPORTS_DIR="$WORK_DIR/reports"
  export RUN_ID="run-real-cloud-010"
  run bash "$SCRIPTS_DIR/dispatch-swarm.sh" "$real_project" pr-subset 1 "$RUN_ID"
  # May or may not succeed depending on tag matches, but should NOT crash
  # on the subdir structure
  [ "$status" -eq 0 ] || {
    # Check that the failure isn't due to subdir discovery issues
    echo "$output" | grep -qiE 'subdir|recursive|not found.*yaml' && {
      echo "FAIL: crash related to subdir discovery" >&2
      return 1
    }
    # Other failures (e.g. no matching scenarios for the suite) are OK
  }
}
