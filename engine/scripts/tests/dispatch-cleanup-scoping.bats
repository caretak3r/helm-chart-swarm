#!/usr/bin/env bats
# dispatch-cleanup-scoping.bats — dispatch-swarm.sh --run must
#   (a) name per-scenario clusters chart-test-swarm-<run-id-slug>-<index>
#       (RUN_ID-scoped, concurrency-safe, prefix-guard compliant)
#   (b) delete ONLY the exact cluster names this invocation created
#       (tracked in _CREATED_CLUSTERS), in both the final cleanup and the
#       SIGINT/SIGTERM handler
#   (c) never touch unrelated chart-test-swarm-* clusters
#       (chart-test-swarm-default, another run's chart-test-swarm-other-run-1)
#
# Hermetic: kind is stubbed on PATH (state file + deletion log); run-scenario.sh
# and cluster-down.sh are stubs. No real clusters or docker containers.

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

  WORK_DIR="$(mktemp -d)"
  export DISPATCH_TEST_STATE="$WORK_DIR/state"
  mkdir -p "$DISPATCH_TEST_STATE"

  # dispatch-swarm.sh requires bash >= 4
  BASH_CMD="$(command -v bash)"
  if [ -x /opt/homebrew/bin/bash ]; then
    BASH_CMD=/opt/homebrew/bin/bash
  fi
}

teardown() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
}

_has_modern_bash() {
  "$BASH_CMD" -c '[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]'
}

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------

# Fake kind on PATH: cluster list lives in $KIND_STATE (one name per line);
# every delete is appended to $KIND_DELETIONS. Pre-seeded with an unrelated
# developer cluster and a concurrent run's cluster.
_setup_fake_kind() {
  FAKE_BIN="$WORK_DIR/bin"
  mkdir -p "$FAKE_BIN"
  export KIND_STATE="$DISPATCH_TEST_STATE/kind-clusters"
  export KIND_DELETIONS="$DISPATCH_TEST_STATE/kind-deletions.log"
  printf 'chart-test-swarm-default\nchart-test-swarm-other-run-1\n' > "$KIND_STATE"
  : > "$KIND_DELETIONS"

  cat > "$FAKE_BIN/kind" <<'KINDEOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    # kind get clusters
    cat "$KIND_STATE"
    ;;
  delete)
    # kind delete cluster --name <name>
    name=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--name" ] && [ $# -ge 2 ]; then name="$2"; shift; fi
      shift
    done
    if [ -n "$name" ]; then
      echo "$name" >> "$KIND_DELETIONS"
      grep -vx "$name" "$KIND_STATE" > "$KIND_STATE.tmp" || true
      mv "$KIND_STATE.tmp" "$KIND_STATE"
    fi
    ;;
esac
exit 0
KINDEOF
  chmod +x "$FAKE_BIN/kind"
}

# Temp scripts dir with the real dispatch-swarm.sh + stub helpers
# (same pattern as live-result-yaml.bats).
_setup_fake_scripts() {
  FAKE_SCRIPTS="$WORK_DIR/scripts"
  mkdir -p "$FAKE_SCRIPTS/lib"

  cp "$SCRIPTS_DIR/dispatch-swarm.sh" "$FAKE_SCRIPTS/"

  for f in "$SCRIPTS_DIR/lib/"*; do
    [ -e "$f" ] || continue
    ln -sf "$f" "$FAKE_SCRIPTS/lib/$(basename "$f")"
  done

  # Stub cluster-down.sh — no-op (the dispatch loop falls through to
  # `kind delete cluster --name`, which the fake kind records).
  cat > "$FAKE_SCRIPTS/cluster-down.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$FAKE_SCRIPTS/cluster-down.sh"

  mkdir -p "$WORK_DIR/templates"
  ln -sf "$ENGINE_DIR/templates/agent-brief.md.tmpl" \
         "$WORK_DIR/templates/agent-brief.md.tmpl"
}

# Stub run-scenario.sh:
#   - registers $CLUSTER_NAME in the fake kind state (simulates cluster
#     creation and a leftover: the stub never deletes it, so the dispatch
#     teardown/cleanup paths must)
#   - bumps a call counter
#   - writes a PASS scenario result dir
#   - if CTS_TEST_SEND_TERM=1, SIGTERMs the dispatch process (its parent)
#     on the FIRST call to exercise the signal handler
_setup_stub_run_scenario() {
  cat > "$FAKE_SCRIPTS/run-scenario.sh" <<'STUBEOF'
#!/usr/bin/env bash
set -euo pipefail

SCENARIO_FILE="${1:?scenario file required}"
SCENARIO_ID=$(grep '^id:' "$SCENARIO_FILE" | head -1 | sed 's/^id:[[:space:]]*//')

# Simulate cluster creation: register CLUSTER_NAME in the fake kind state.
echo "${CLUSTER_NAME:?CLUSTER_NAME must be set}" >> "$KIND_STATE"

CALL_COUNTER_FILE="${DISPATCH_TEST_STATE}/call_count"
if [ -f "$CALL_COUNTER_FILE" ]; then
  CALL_NUM=$(( $(cat "$CALL_COUNTER_FILE") + 1 ))
else
  CALL_NUM=1
fi
echo "$CALL_NUM" > "$CALL_COUNTER_FILE"

RESULT_DIR="${REPORTS_DIR}/scenario-${SCENARIO_ID}-$(date +%s)-$$"
mkdir -p "$RESULT_DIR"
cat > "$RESULT_DIR/result.yaml" <<YAML
run_id: fake
id: ${SCENARIO_ID}
status: PASS
fail_stage: ""
fail_msg: ""
asserts: []
YAML

if [ "${CTS_TEST_SEND_TERM:-0}" = "1" ] && [ "$CALL_NUM" -eq 1 ]; then
  kill -TERM "$PPID" 2>/dev/null || true
fi

exit 0
STUBEOF
  chmod +x "$FAKE_SCRIPTS/run-scenario.sh"
}

# Minimal fake project with N scenarios tagged 'test'
# (same shape as live-result-yaml.bats).
_setup_fake_project() {
  local n="${1:-2}"
  FAKE_PROJECT="$WORK_DIR/project"
  mkdir -p "$FAKE_PROJECT/chart-test/scenarios"
  mkdir -p "$FAKE_PROJECT/chart"

  cat > "$FAKE_PROJECT/chart/Chart.yaml" <<YAML
apiVersion: v2
name: fake-chart
version: 0.1.0
YAML

  cat > "$FAKE_PROJECT/chart-test-swarm.yaml" <<YAML
schema_version: 1
project:
  name: fake
scenarios_dir: chart-test/scenarios
suites:
  test-suite:
    tag_filter: [test]
YAML

  for i in $(seq 1 "$n"); do
    cat > "$FAKE_PROJECT/chart-test/scenarios/fake-$i.yaml" <<YAML
id: fake-scenario-$i
name: "Fake scenario $i"
cluster:
  provider: kind
  k8s_version: v1.36.1
product:
  chart: chart
  release: fake
  namespace: fake
asserts:
  - type: pods-ready
    namespace: fake
    timeout: 1m
tags: [test]
mechanisms: [addon:none]
YAML
  done
}

_run_dispatch() {
  # $1 = RUN_ID, remaining args appended (e.g. env overrides handled by caller)
  local run_id="$1"
  export REPORTS_DIR="$WORK_DIR/reports"
  mkdir -p "$REPORTS_DIR"
  run env PATH="$FAKE_BIN:$PATH" "$BASH_CMD" \
    "$FAKE_SCRIPTS/dispatch-swarm.sh" "$FAKE_PROJECT" test-suite 1 "$run_id" --run
}

# ---------------------------------------------------------------------------
# (b) naming: cluster names embed the sanitized RUN_ID slug
# ---------------------------------------------------------------------------

@test "per-scenario cluster names embed the sanitized RUN_ID slug" {
  _has_modern_bash || skip "bash >= 4 required"
  _setup_fake_kind
  _setup_fake_scripts
  _setup_stub_run_scenario
  _setup_fake_project 2

  _run_dispatch "run-20260601-070133-7511"
  [ "$status" -eq 0 ]

  # run- prefix stripped, timestamp+PID tail kept, index appended
  echo "$output" | grep -q '==> Cluster: chart-test-swarm-20260601-070133-7511-1'
  echo "$output" | grep -q '==> Cluster: chart-test-swarm-20260601-070133-7511-2'
  # Old index-only names must NOT appear.
  # (Positive count assertion: bats' set -e ignores '!'-negated commands, so a
  #  plain '! grep' here could never fail the test.)
  [ "$(echo "$output" | grep -c 'Cluster: chart-test-swarm-run-1$')" -eq 0 ]
}

@test "explicit RUN_ID with uppercase/underscores is sanitized into the cluster name" {
  _has_modern_bash || skip "bash >= 4 required"
  _setup_fake_kind
  _setup_fake_scripts
  _setup_stub_run_scenario
  _setup_fake_project 1

  _run_dispatch "My_Run.ID"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '==> Cluster: chart-test-swarm-my-run-id-1'
}

# ---------------------------------------------------------------------------
# (a)+(c) cleanup: only this invocation's recorded names are deleted
# ---------------------------------------------------------------------------

@test "cleanup deletes exactly this invocation's clusters; unrelated clusters survive" {
  _has_modern_bash || skip "bash >= 4 required"
  _setup_fake_kind
  _setup_fake_scripts
  _setup_stub_run_scenario
  _setup_fake_project 2

  _run_dispatch "run-20260601-070133-7511"
  [ "$status" -eq 0 ]

  # Deleted: exactly the two clusters this run created, nothing else.
  # (Positive count assertions throughout: bats' set -e ignores '!'-negated
  #  commands, so '! grep' mid-test could never fail the test.)
  grep -qx 'chart-test-swarm-20260601-070133-7511-1' "$KIND_DELETIONS"
  grep -qx 'chart-test-swarm-20260601-070133-7511-2' "$KIND_DELETIONS"
  [ "$(grep -c 'chart-test-swarm-default' "$KIND_DELETIONS")" -eq 0 ]
  [ "$(grep -c 'chart-test-swarm-other-run-1' "$KIND_DELETIONS")" -eq 0 ]
  # Every deleted name belongs to this run
  [ "$(grep -vc '^chart-test-swarm-20260601-070133-7511-' "$KIND_DELETIONS")" -eq 0 ]

  # Survivors: the developer's default cluster and the concurrent run's cluster
  grep -qx 'chart-test-swarm-default' "$KIND_STATE"
  grep -qx 'chart-test-swarm-other-run-1' "$KIND_STATE"
  # This run's clusters are gone
  [ "$(grep -c '^chart-test-swarm-20260601-070133-7511-' "$KIND_STATE")" -eq 0 ]
}

@test "SIGTERM mid-run: handler deletes only recorded clusters; chart-test-swarm-default survives" {
  _has_modern_bash || skip "bash >= 4 required"
  _setup_fake_kind
  _setup_fake_scripts
  _setup_stub_run_scenario
  _setup_fake_project 2

  export CTS_TEST_SEND_TERM=1
  _run_dispatch "run-20260601-070133-7511"
  unset CTS_TEST_SEND_TERM

  # Interrupted: non-zero exit, and scenario 2 never ran
  [ "$status" -ne 0 ]
  [ "$(cat "$DISPATCH_TEST_STATE/call_count")" = "1" ]

  # The handler removed the one cluster this run had created...
  grep -qx 'chart-test-swarm-20260601-070133-7511-1' "$KIND_DELETIONS"
  # ...and nothing else (positive count form — see note in the test above)
  [ "$(grep -vc '^chart-test-swarm-20260601-070133-7511-' "$KIND_DELETIONS")" -eq 0 ]
  grep -qx 'chart-test-swarm-default' "$KIND_STATE"
  grep -qx 'chart-test-swarm-other-run-1' "$KIND_STATE"
}

# ---------------------------------------------------------------------------
# Static source guards (grep the script, per existing repo test style)
# ---------------------------------------------------------------------------

@test "dispatch-swarm.sh contains no pattern-based chart-test-swarm-* cluster deletion" {
  run grep -c "grep '\^chart-test-swarm-'" "$SCRIPTS_DIR/dispatch-swarm.sh"
  [ "$output" = "0" ]
}

@test "dispatch-swarm.sh records created clusters and scopes cleanup to them" {
  grep -q '_CREATED_CLUSTERS=()' "$SCRIPTS_DIR/dispatch-swarm.sh"
  grep -q '_CREATED_CLUSTERS+=("$_cluster_name")' "$SCRIPTS_DIR/dispatch-swarm.sh"
  # The signal handler must use the scoped cleanup, not a pattern scan
  sed -n '/_exec_cleanup() {/,/^  }/p' "$SCRIPTS_DIR/dispatch-swarm.sh" \
    | grep -q '_cleanup_created_clusters'
  # The composed name embeds the RUN_ID slug
  grep -q '_cluster_name="chart-test-swarm-${_RUN_SLUG}-${_RUN_IDX}"' "$SCRIPTS_DIR/dispatch-swarm.sh"
}
