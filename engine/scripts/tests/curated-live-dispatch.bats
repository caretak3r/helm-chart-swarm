#!/usr/bin/env bats
# bats file_tags: curated-live, f17-3
# Validates dispatching the curated-live suite on real kind clusters (f17-3).
#
# Covers:
#   VAL-E2E-002: each live/capability/gap-probe member produces result.yaml
#   VAL-E2E-010: no orphan kind clusters after completion
#   VAL-E2E-011: no orphan docker containers after completion
#
# These tests exercise the --run execution flag on dispatch-swarm.sh.

setup() {
  PROJECT_DIR="$(cd "$BATS_TEST_DIRNAME/../../../examples/sample-product-chart" && pwd)"
  ENGINE_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DISPATCH="$ENGINE_DIR/dispatch-swarm.sh"
  RUN_SCENARIO="$ENGINE_DIR/run-scenario.sh"
  CLUSTER_DOWN="$ENGINE_DIR/cluster-down.sh"
  SCEN_DIR="$PROJECT_DIR/chart-test/scenarios"
  REPORTS_ROOT="$PROJECT_DIR/chart-test/reports"
  # Use bash 4+ if available (required by dispatch-swarm.sh)
  BASH4="${BASH4:-$(command -v bash5 2>/dev/null || command -v bash 2>/dev/null || echo /bin/bash)}"
}

teardown() {
  # Cleanup only clusters created by THIS test file (run ids embed f17-3).
  # Never pattern-delete every chart-test-swarm-* cluster: a developer's
  # chart-test-swarm-default or a concurrent run's clusters must survive.
  #
  # LENGTH BUDGET: cts_run_id_slug keeps only the LAST 24 chars, so 'f17-3'
  # survives in 'bats-f17-3-<name>-<pid>' only while '<name>-<pid>' <= 18
  # chars. The longest current name, 'containers-' + a 7-digit PID, is
  # exactly 18 — zero margin. Keep new run-id <name> parts <= 'containers'
  # in length or these f17-3-scoped greps go silently vacuous.
  for cl in $(kind get clusters 2>/dev/null | grep '^chart-test-swarm-' | grep 'f17-3' || true); do
    kind delete cluster --name "$cl" 2>/dev/null || true
  done
  # Cleanup only this file's orphan containers (kind node containers inherit
  # the cluster name, so they also embed f17-3)
  for c in $(docker ps -a --filter "name=chart-test-swarm-" --format '{{.Names}}' 2>/dev/null | grep 'f17-3' || true); do
    docker rm -f "$c" 2>/dev/null || true
  done
}

# ── Flag acceptance (no cluster required) ──────────────────────────────

@test "dispatch-swarm.sh accepts --run flag" {
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 test-run-acceptance --dry-run --run
  # --dry-run should still exit 0 even with --run
  [ "$status" -eq 0 ]
}

@test "dispatch-swarm.sh --run is documented in --help" {
  run bash "$DISPATCH" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\-\-run"
}

# ── Suite resolution with --run (dry-run, no cluster) ──────────────────

@test "dispatch-swarm.sh --run --dry-run resolves 18 curated-live scenarios" {
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 test-dry-run --dry-run --run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "matched 18 scenario"
}

@test "cloud-authored scenarios are excluded from curated-live dispatch even with --run" {
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 test-dry-cloud --dry-run --run
  [ "$status" -eq 0 ]

  # None of these cloud-authored ids should appear
  local cloud_ids=(
    cloud-native-eks-alb-ingress
    cloud-native-eks-irsa
    cloud-native-aks-agic
    cloud-native-gke-iap
    networking-aws-lbc-alb-ingress
    networking-azure-lb-agic
    networking-gcp-lb-external
  )

  for id in "${cloud_ids[@]}"; do
    if echo "$output" | grep -q "$id"; then
      echo "FAIL: cloud-authored '$id' should not appear in curated-live --run dispatch"
      return 1
    fi
  done
}

# ── Live execution: small-scale dispatch (2 capability scenarios) ──────
# These tests spin up real kind clusters and verify the execution flow.

# Skip on bash 3.2 (dispatch-swarm.sh requires bash 4+)
_has_modern_bash() {
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "Requires bash >= 4 (running ${BASH_VERSION:-unknown})" >&3
    return 1
  fi
  return 0
}

@test "dispatch --run executes a single capability scenario and produces result.yaml" {
  _has_modern_bash || skip

  # Pick the lightest capability scenario: labels-on
  local scenario="$SCEN_DIR/capability/labels-on.yaml"
  [ -f "$scenario" ] || skip "labels-on.yaml not found"

  local run_id="run-bats-f17-3-single-$$"
  local run_dir="$REPORTS_ROOT/$run_id"

  # Run dispatch with --run for a single scenario
  CTS_SCENARIOS="$scenario" \
  RUN_ID="$run_id" \
  KEEP_CLUSTER=0 \
  KEEP_ON_FAILURE=0 \
  REPORTS_DIR="$REPORTS_ROOT" \
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 "$run_id" --run

  # Should exit 0 (PASS or FAIL is fine; we just need a result)
  [ "$status" -eq 0 ]

  # Verify scenario-level result.yaml was produced (under scenario-*/ subdirs)
  local result_count
  result_count=$(find "$run_dir" -path '*/scenario-*/result.yaml' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$result_count" -ge 1 ] || {
    echo "FAIL: no scenario result.yaml found under $run_dir"
    find "$run_dir" -type f -name 'result.yaml' 2>/dev/null >&2
    find "$run_dir" -type d 2>/dev/null | head -20 >&2
    return 1
  }

  # Verify the scenario result.yaml has a real status field (PASS or FAIL)
  local result_file
  result_file=$(find "$run_dir" -path '*/scenario-*/result.yaml' -type f 2>/dev/null | head -1)
  # Use grep for status extraction — some result.yaml have multi-line notes
  # that confuse yq's YAML parser
  local status_val
  status_val=$(grep -E '^status:' "$result_file" 2>/dev/null | head -1 | sed 's/^status:[[:space:]]*//' || echo "")
  [ -n "$status_val" ] || {
    echo "FAIL: scenario result.yaml has no status field"
    cat "$result_file" >&2
    return 1
  }
  # Status must be PASS or FAIL (a real outcome)
  echo "$status_val" | grep -qE '^(PASS|FAIL|SKIP|INTERRUPTED)$' || {
    echo "FAIL: unexpected status: $status_val"
    return 1
  }
}

@test "after dispatch --run, no orphan chart-test-swarm-* kind clusters remain" {
  _has_modern_bash || skip

  # Run a single lightweight scenario to verify cleanup
  local scenario="$SCEN_DIR/capability/labels-on.yaml"
  [ -f "$scenario" ] || skip "labels-on.yaml not found"

  local run_id="run-bats-f17-3-orphan-$$"

  CTS_SCENARIOS="$scenario" \
  RUN_ID="$run_id" \
  KEEP_CLUSTER=0 \
  KEEP_ON_FAILURE=0 \
  REPORTS_DIR="$REPORTS_ROOT" \
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 "$run_id" --run

  # After completion, none of THIS run's clusters remain (names embed the
  # RUN_ID slug, which contains f17-3). Unrelated chart-test-swarm-* clusters
  # are allowed to exist — cleanup is scoped to the invocation.
  local orphan_clusters
  orphan_clusters=$(kind get clusters 2>/dev/null | grep '^chart-test-swarm-' | grep 'f17-3' || true)
  [ -z "$orphan_clusters" ] || {
    echo "FAIL: orphan kind clusters found: $orphan_clusters"
    return 1
  }
}

@test "after dispatch --run, no orphan chart-test-swarm-* docker containers remain" {
  _has_modern_bash || skip

  # Run a single lightweight scenario to verify container cleanup
  local scenario="$SCEN_DIR/capability/labels-on.yaml"
  [ -f "$scenario" ] || skip "labels-on.yaml not found"

  local run_id="run-bats-f17-3-containers-$$"

  CTS_SCENARIOS="$scenario" \
  RUN_ID="$run_id" \
  KEEP_CLUSTER=0 \
  KEEP_ON_FAILURE=0 \
  REPORTS_DIR="$REPORTS_ROOT" \
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 "$run_id" --run

  # After completion, none of THIS run's containers remain (node containers
  # inherit the cluster name, which embeds the f17-3 slug)
  local orphan_containers
  orphan_containers=$(docker ps -a --filter "name=chart-test-swarm-" --format '{{.Names}}' 2>/dev/null | grep '^chart-test-swarm-' | grep 'f17-3' || true)
  [ -z "$orphan_containers" ] || {
    echo "FAIL: orphan docker containers found: $orphan_containers"
    return 1
  }
}

@test "no result.yaml reflects a cluster apply for any cloud-authored id" {
  _has_modern_bash || skip

  # Run a small dispatch that includes only local scenarios
  local scenario="$SCEN_DIR/capability/labels-on.yaml"
  [ -f "$scenario" ] || skip "labels-on.yaml not found"

  local run_id="run-bats-f17-3-no-cloud-$$"
  local run_dir="$REPORTS_ROOT/$run_id"

  CTS_SCENARIOS="$scenario" \
  RUN_ID="$run_id" \
  KEEP_CLUSTER=0 \
  KEEP_ON_FAILURE=0 \
  REPORTS_DIR="$REPORTS_ROOT" \
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 "$run_id" --run

  [ "$status" -eq 0 ]

  # Check that no scenario result.yaml references a cloud provider (gke/eks/aks)
  local cloud_results
  cloud_results=$(find "$run_dir" -path '*/scenario-*/result.yaml' -exec grep -l 'provider:.*\(gke\|eks\|aks\)' {} \; 2>/dev/null || true)
  [ -z "$cloud_results" ] || {
    echo "FAIL: result.yaml files reference cloud providers: $cloud_results"
    return 1
  }
}

@test "dispatch --run writes run-level result.yaml with scenario summary" {
  _has_modern_bash || skip

  local scenario="$SCEN_DIR/capability/labels-on.yaml"
  [ -f "$scenario" ] || skip "labels-on.yaml not found"

  local run_id="run-bats-f17-3-summary-$$"
  local run_dir="$REPORTS_ROOT/$run_id"

  CTS_SCENARIOS="$scenario" \
  RUN_ID="$run_id" \
  KEEP_CLUSTER=0 \
  KEEP_ON_FAILURE=0 \
  REPORTS_DIR="$REPORTS_ROOT" \
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 "$run_id" --run

  [ "$status" -eq 0 ]

  # Verify run-level result.yaml exists and has a scenarios section
  [ -f "$run_dir/result.yaml" ] || {
    echo "FAIL: no run-level result.yaml at $run_dir/result.yaml"
    find "$run_dir" -type f -name 'result.yaml' >&2
    return 1
  }

  # Verify it has a status summary
  yq -e '.scenarios' "$run_dir/result.yaml" >/dev/null 2>&1 || {
    echo "FAIL: run-level result.yaml missing .scenarios"
    cat "$run_dir/result.yaml" >&2
    return 1
  }
}
