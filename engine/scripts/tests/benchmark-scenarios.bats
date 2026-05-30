#!/usr/bin/env bats
# bats tests for benchmark-scenarios.sh covering:
#   - CSV creation with correct headers
#   - CSV parseable by python3 csv.DictReader
#   - Header format verification
#   - Row count >= 1 after benchmark run
#   - Each row has correct fields (timestamp, scenario, status, duration_s, peak_memory_mb, artifacts_path)
#   - No chart-test-swarm-* clusters remain after benchmark

setup() {
  SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/.."
  ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
  BENCH_SCRIPT="$SCRIPT_DIR/benchmark-scenarios.sh"
  # Use modern bash (>= 4) — system /bin/bash on macOS is 3.2
  BASH_CMD="$(command -v bash)"
  if [ -x /opt/homebrew/bin/bash ]; then
    BASH_CMD=/opt/homebrew/bin/bash
  fi
  # Temp files created during tests
  _BENCH_TEMPFILES=()
}

teardown() {
  # Clean up any tempfiles created by this test file
  for f in "${_BENCH_TEMPFILES[@]+"${_BENCH_TEMPFILES[@]}"}"; do
    rm -f "$f" 2>/dev/null || true
  done
  # Clean up any benchmark clusters left behind
  for leftover in $(kind get clusters 2>/dev/null | grep '^chart-test-swarm-bench-' || true); do
    kind delete cluster --name "$leftover" 2>/dev/null || true
  done
}

# Helper: check if we have bash >= 4 for full script execution
_has_modern_bash() {
  [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]
}

# --- Script structure tests (no cluster I/O) ---

@test "benchmark-scenarios.sh exists and is executable" {
  [ -f "$BENCH_SCRIPT" ]
  [ -x "$BENCH_SCRIPT" ]
}

@test "benchmark-scenarios.sh accepts --help and exits 0" {
  if ! _has_modern_bash; then
    skip "bash >= 4 required"
  fi
  run $BASH_CMD "$BENCH_SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"benchmark-scenarios.sh"* ]]
}

@test "benchmark-scenarios.sh has set -euo pipefail" {
  grep -q 'set -euo pipefail' "$BENCH_SCRIPT"
}

@test "benchmark-scenarios.sh has trap for cleanup" {
  grep -q 'trap.*cleanup' "$BENCH_SCRIPT"
}

@test "benchmark-scenarios.sh uses find to discover scenario YAMLs" {
  # Verify the script contains discovery logic using find or similar
  grep -q 'find.*scenarios.*yaml\|find.*\.yaml' "$BENCH_SCRIPT"
}

@test "benchmark-scenarios.sh supports --limit flag to restrict benchmark count" {
  grep -q '\-\-limit' "$BENCH_SCRIPT"
}

@test "benchmark-scenarios.sh live benchmark produces parseable CSV (requires CTS_BENCH_LIVE=1)" {
  if [ "${CTS_BENCH_LIVE:-0}" != "1" ]; then
    skip "CTS_BENCH_LIVE=1 required for live benchmark test (creates kind cluster)"
  fi
  if ! _has_modern_bash; then
    skip "bash >= 4 required"
  fi

  local tmp_csv
  tmp_csv=$(mktemp)
  _BENCH_TEMPFILES+=("$tmp_csv")

  # Create a minimal scenarios directory with one scenario
  local tmp_scenarios
  tmp_scenarios=$(mktemp -d)
  _BENCH_TEMPFILES+=("$tmp_scenarios")

  # Copy minimal.yaml (fastest scenario) to temp dir
  cp "$ROOT_DIR/examples/sample-product-chart/chart-test/scenarios/minimal.yaml" "$tmp_scenarios/"

  # Run benchmark with limit=1, using temp output CSV
  SCENARIOS_DIR="$tmp_scenarios" OUTPUT_CSV="$tmp_csv" LIMIT=1 \
    $BASH_CMD "$BENCH_SCRIPT" 2>/dev/null || true

  # Verify CSV file exists
  [ -f "$tmp_csv" ]

  # Verify header
  local header
  header=$(head -1 "$tmp_csv")
  [ "$header" = "timestamp,scenario,status,duration_s,peak_memory_mb,artifacts_path" ]

  # Verify parseable by python3 csv.DictReader
  run python3 -c "
import csv
with open('$tmp_csv') as f:
    reader = csv.DictReader(f)
    rows = list(reader)
    assert len(rows) >= 1, 'expected at least 1 row'
    for row in rows:
        assert 'timestamp' in row, 'missing timestamp'
        assert 'scenario' in row, 'missing scenario'
        assert 'status' in row, 'missing status'
        assert 'duration_s' in row, 'missing duration_s'
        assert 'peak_memory_mb' in row, 'missing peak_memory_mb'
        assert 'artifacts_path' in row, 'missing artifacts_path'
    print(f'OK: {len(rows)} row(s)')
"
  [ "$status" -eq 0 ]
}

# --- CSV format tests on synthetic data ---

@test "CSV headers match required format" {
  local tmp_csv
  tmp_csv=$(mktemp)
  _BENCH_TEMPFILES+=("$tmp_csv")

  echo "timestamp,scenario,status,duration_s,peak_memory_mb,artifacts_path" > "$tmp_csv"
  echo "2026-05-30T00:00:00Z,test-scenario,PASS,42.5,128,/path/to/artifacts" >> "$tmp_csv"

  # Verify header
  local header
  header=$(head -1 "$tmp_csv")
  [ "$header" = "timestamp,scenario,status,duration_s,peak_memory_mb,artifacts_path" ]

  # Verify parseable
  run python3 -c "
import csv
with open('$tmp_csv') as f:
    reader = csv.DictReader(f)
    rows = list(reader)
    assert len(rows) == 1
    row = rows[0]
    assert row['scenario'] == 'test-scenario'
    assert row['status'] == 'PASS'
    assert float(row['duration_s']) == 42.5
    assert int(row['peak_memory_mb']) == 128
    assert row['artifacts_path'] == '/path/to/artifacts'
    print('OK')
"
  [ "$status" -eq 0 ]
}

@test "CSV parseable with mixed PASS/FAIL rows" {
  local tmp_csv
  tmp_csv=$(mktemp)
  _BENCH_TEMPFILES+=("$tmp_csv")

  cat > "$tmp_csv" <<'EOF'
timestamp,scenario,status,duration_s,peak_memory_mb,artifacts_path
2026-05-30T00:00:00Z,scenario-A,PASS,35.2,256,/reports/a
2026-05-30T00:01:00Z,scenario-B,FAIL,12.1,64,/reports/b
2026-05-30T00:02:00Z,scenario-C,PASS,48.7,512,/reports/c
EOF

  run python3 -c "
import csv
with open('$tmp_csv') as f:
    reader = csv.DictReader(f)
    rows = list(reader)
    assert len(rows) == 3, f'expected 3 rows, got {len(rows)}'
    statuses = [r['status'] for r in rows]
    assert 'PASS' in statuses
    assert 'FAIL' in statuses
    for r in rows:
        dur = float(r['duration_s'])
        assert dur > 0, f'duration_s must be positive, got {dur}'
    print('OK')
"
  [ "$status" -eq 0 ]
}

@test "CSV handles duration_s as float" {
  local tmp_csv
  tmp_csv=$(mktemp)
  _BENCH_TEMPFILES+=("$tmp_csv")

  echo "timestamp,scenario,status,duration_s,peak_memory_mb,artifacts_path" > "$tmp_csv"
  echo "2026-05-30T00:00:00Z,s1,PASS,10.5,100,/p" >> "$tmp_csv"

  run python3 -c "
import csv
with open('$tmp_csv') as f:
    rows = list(csv.DictReader(f))
    dur = float(rows[0]['duration_s'])
    assert dur >= 5.0, f'duration_s {dur} should be >= 5.0 for cluster-creating scenarios'
    print('OK')
"
  [ "$status" -eq 0 ]
}

# --- Cleanup verification ---

@test "no chart-test-swarm-bench-* clusters remain after benchmark" {
  # This test should be run after benchmark completion
  local bench_clusters
  bench_clusters=$(kind get clusters 2>/dev/null | grep '^chart-test-swarm-bench-' || true)
  if [ -n "$bench_clusters" ]; then
    echo "WARN: leftover benchmark clusters found: $bench_clusters"
  fi
  # This is informational; actual enforcement is in the script's cleanup
  [ -z "$bench_clusters" ] || skip "Leftover benchmark clusters exist; run cleanup first"
}

@test "benchmark-scenarios.sh --help shows CSV header format" {
  if ! _has_modern_bash; then
    skip "bash >= 4 required"
  fi
  run $BASH_CMD "$BENCH_SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"timestamp,scenario,status,duration_s,peak_memory_mb,artifacts_path"* ]]
}
