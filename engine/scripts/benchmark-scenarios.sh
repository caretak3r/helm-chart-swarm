#!/usr/bin/env bash
# Benchmark all completed scenario YAMLs sequentially on fresh kind clusters.
# Captures wall-clock time, peak memory, status (PASS/FAIL), and artifacts path.
# Appends one row per scenario to reports/benchmarks/results.csv.
#
# Usage:
#   benchmark-scenarios.sh [OPTIONS]
#
# Options:
#   --help             Show usage banner and exit
#   --scenarios-dir    Override scenario discovery directory
#                      (default: examples/sample-product-chart/chart-test/scenarios/)
#   --output-csv       Override output CSV path
#                      (default: reports/benchmarks/results.csv)
#   --limit N          Only benchmark the first N scenarios (for testing)
#
# Environment:
#   SCENARIOS_DIR      Override scenario discovery directory
#   OUTPUT_CSV         Override output CSV path
#   LIMIT              Only benchmark the first N scenarios
#
# CSV headers: timestamp,scenario,status,duration_s,peak_memory_mb,artifacts_path
set -euo pipefail

# ---- Usage banner ----
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Benchmark all scenario YAMLs sequentially on fresh kind clusters.
Captures wall-clock time, peak memory, status, and artifacts path.
Appends one row per scenario to reports/benchmarks/results.csv.

Options:
  --help             Show this usage banner and exit
  --scenarios-dir    Override scenario discovery directory
  --output-csv       Override output CSV path
  --limit N          Only benchmark the first N scenarios (for testing)

CSV headers: timestamp,scenario,status,duration_s,peak_memory_mb,artifacts_path
EOF
  exit 0
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
fi

# ---- Bash version preflight ----
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "ERROR: bash >= 4 required (running ${BASH_VERSION:-unknown})." >&2
  echo "       Install modern bash: brew install bash" >&2
  echo "       Then re-run with: /opt/homebrew/bin/bash $0 $*" >&2
  exit 1
fi

# ---- Resolve paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"

DEFAULT_SCENARIOS_DIR="$ROOT_DIR/examples/sample-product-chart/chart-test/scenarios"
DEFAULT_OUTPUT_CSV="$ROOT_DIR/reports/benchmarks/results.csv"

SCENARIOS_DIR="${SCENARIOS_DIR:-$DEFAULT_SCENARIOS_DIR}"
OUTPUT_CSV="${OUTPUT_CSV:-$DEFAULT_OUTPUT_CSV}"
LIMIT="${LIMIT:-0}"  # 0 = no limit

# Parse optional flags (override env vars)
while [ $# -gt 0 ]; do
  case "$1" in
    --scenarios-dir) SCENARIOS_DIR="$2"; shift 2 ;;
    --output-csv)    OUTPUT_CSV="$2"; shift 2 ;;
    --limit)         LIMIT="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage ;;
  esac
done

# ---- Validate required tools ----
for cmd in yq jq kubectl helm kind docker date; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required tool not found: $cmd" >&2; exit 1; }
done

# Check for /usr/bin/time (BSD time on macOS)
if ! command -v /usr/bin/time >/dev/null 2>&1; then
  echo "ERROR: /usr/bin/time not found" >&2
  exit 1
fi

# ---- Validate scenario directory ----
if [ ! -d "$SCENARIOS_DIR" ]; then
  echo "ERROR: scenarios directory not found: $SCENARIOS_DIR" >&2
  exit 1
fi

# ---- Discover scenario YAMLs ----
mapfile -t SCENARIO_FILES < <(find "$SCENARIOS_DIR" -maxdepth 1 -name '*.yaml' -type f | sort)
SCENARIO_COUNT="${#SCENARIO_FILES[@]}"

if [ "$SCENARIO_COUNT" -eq 0 ]; then
  echo "ERROR: no scenario YAML files found in $SCENARIOS_DIR" >&2
  exit 1
fi

# Apply limit if set
if [ "$LIMIT" -gt 0 ] && [ "$LIMIT" -lt "$SCENARIO_COUNT" ]; then
  SCENARIO_FILES=("${SCENARIO_FILES[@]:0:$LIMIT}")
  SCENARIO_COUNT="$LIMIT"
fi

echo "==> Discovered $SCENARIO_COUNT scenario(s) in $SCENARIOS_DIR"

# ---- Ensure output directory exists ----
OUTPUT_DIR="$(dirname "$OUTPUT_CSV")"
mkdir -p "$OUTPUT_DIR"

# ---- Write CSV header if file is empty or does not exist ----
if [ ! -s "$OUTPUT_CSV" ]; then
  echo "timestamp,scenario,status,duration_s,peak_memory_mb,artifacts_path" > "$OUTPUT_CSV"
fi

# ---- Benchmark each scenario ----
PASS_COUNT=0
FAIL_COUNT=0
INDEX=0

# Trap for cleanup on interrupt
_bench_interrupted=0
# shellcheck disable=SC2329  # invoked via trap below
cleanup_on_interrupt() {
  echo "" >&2
  echo "==> SIGINT/SIGTERM received — cleaning up benchmark clusters" >&2
  _bench_interrupted=1
  for leftover in $(kind get clusters 2>/dev/null | grep '^chart-test-swarm-bench-' || true); do
    echo "==> Removing leftover cluster: $leftover" >&2
    kind delete cluster --name "$leftover" 2>/dev/null || true
  done
  exit 1
}
trap cleanup_on_interrupt INT TERM

cleanup_bench_cluster() {
  local cluster_name="$1"
  echo "==> Ensuring cluster $cluster_name is cleaned up..."
  # Force teardown regardless of KEEP_CLUSTER state.  cluster-down.sh is idempotent.
  PROVIDER=kind CLUSTER_NAME="$cluster_name" bash "$SCRIPT_DIR/cluster-down.sh" 2>/dev/null || true
  # Double-check: if kind still lists it, force delete
  if kind get clusters 2>/dev/null | grep -qx "$cluster_name"; then
    echo "==> Force-deleting stuck cluster: $cluster_name"
    kind delete cluster --name "$cluster_name" 2>/dev/null || true
  fi
}

# Parse peak memory (bytes) from /usr/bin/time -l output
parse_peak_memory_bytes() {
  local time_log="$1"
  local bytes
  bytes=$(grep 'maximum resident set size' "$time_log" 2>/dev/null | awk '{print $1}' || echo "0")
  # Strip any non-digit characters and convert to number
  bytes=$(echo "$bytes" | tr -cd '0-9')
  if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
    echo "0"
  else
    echo "$bytes"
  fi
}

for SCENARIO_FILE in "${SCENARIO_FILES[@]}"; do
  INDEX=$((INDEX + 1))
  SCENARIO_FILENAME="$(basename "$SCENARIO_FILE")"

  # Read scenario ID from YAML
  SCEN_ID=$(yq '.id' "$SCENARIO_FILE" 2>/dev/null || echo "unknown-${INDEX}")
  if [ -z "$SCEN_ID" ] || [ "$SCEN_ID" = "null" ]; then
    SCEN_ID="unknown-${INDEX}"
  fi

  # Generate a unique cluster name with the benchmark prefix
  CLUSTER_NAME="chart-test-swarm-bench-${INDEX}"

  echo ""
  echo "============================================================"
  echo "==> Benchmark [$INDEX/$SCENARIO_COUNT]: $SCEN_ID ($SCENARIO_FILENAME)"
  echo "==> Cluster: $CLUSTER_NAME"
  echo "============================================================"

  # Record start timestamp (ISO 8601 UTC)
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  START_SEC=$(date +%s)

  # Run the scenario using /usr/bin/time -l for memory capture.
  # -o writes resource usage to TIME_LOG; child stdout+stderr go to SCENARIO_LOG.
  TIME_LOG=$(mktemp)
  SCENARIO_LOG=$(mktemp)

  RUN_EXIT=0
  /usr/bin/time -l -o "$TIME_LOG" \
    env CLUSTER_NAME="$CLUSTER_NAME" \
        PROVIDER=kind \
        KEEP_CLUSTER=0 \
        KEEP_ON_FAILURE=0 \
        bash "$SCRIPT_DIR/run-scenario.sh" "$SCENARIO_FILE" \
    > "$SCENARIO_LOG" 2>&1 || RUN_EXIT=$?

  END_SEC=$(date +%s)
  DURATION=$((END_SEC - START_SEC))

  # Parse peak memory from /usr/bin/time -l output
  PEAK_MEMORY_BYTES=$(parse_peak_memory_bytes "$TIME_LOG")
  if [ "$PEAK_MEMORY_BYTES" -gt 0 ]; then
    PEAK_MEMORY_MB=$((PEAK_MEMORY_BYTES / 1024 / 1024))
  else
    PEAK_MEMORY_MB=0
  fi

  # Find report directory from scenario log
  ARTIFACTS_PATH=""
  if [ -f "$SCENARIO_LOG" ]; then
    ARTIFACTS_PATH=$(grep -E '^==> Report dir:' "$SCENARIO_LOG" 2>/dev/null | head -1 | sed 's/^==> Report dir: //' || echo "")
  fi

  # Determine status from result.yaml
  STATUS="FAIL"
  if [ -n "$ARTIFACTS_PATH" ] && [ -f "$ARTIFACTS_PATH/result.yaml" ]; then
    RESULT_STATUS=$(yq '.status' "$ARTIFACTS_PATH/result.yaml" 2>/dev/null || echo "FAIL")
    if [ -n "$RESULT_STATUS" ] && [ "$RESULT_STATUS" != "null" ]; then
      STATUS="$RESULT_STATUS"
    fi
  elif [ "$RUN_EXIT" -eq 0 ]; then
    # run-scenario.sh exits 0 on PASS
    STATUS="PASS"
  fi

  # Fallback: if we couldn't determine artifacts path
  if [ -z "$ARTIFACTS_PATH" ]; then
    ARTIFACTS_PATH="N/A"
  fi

  # Append row to CSV
  echo "${TIMESTAMP},${SCEN_ID},${STATUS},${DURATION},${PEAK_MEMORY_MB},${ARTIFACTS_PATH}" >> "$OUTPUT_CSV"

  # Track counts
  if [ "$STATUS" = "PASS" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  echo "==> RESULT: $STATUS | duration=${DURATION}s | memory=${PEAK_MEMORY_MB}MB | artifacts=${ARTIFACTS_PATH}"

  # Ensure cluster is cleaned up before next scenario
  cleanup_bench_cluster "$CLUSTER_NAME"

  # Clean up temp files
  rm -f "$TIME_LOG" "$SCENARIO_LOG"

  # Safety check: if interrupted during this iteration, stop
  if [ "${_bench_interrupted:-0}" = "1" ]; then
    break
  fi
done

# ---- Summary ----
echo ""
echo "============================================================"
echo "==> Benchmark complete: $SCENARIO_COUNT scenario(s)"
echo "==>   PASS: $PASS_COUNT"
echo "==>   FAIL: $FAIL_COUNT"
echo "==>   CSV:  $OUTPUT_CSV"
echo "============================================================"

# ---- Final cleanup: ensure no benchmark clusters remain ----
echo "==> Final cluster cleanup..."
for leftover in $(kind get clusters 2>/dev/null | grep '^chart-test-swarm-bench-' || true); do
  echo "==> Removing leftover cluster: $leftover"
  kind delete cluster --name "$leftover" 2>/dev/null || true
done

# Verify no chart-test-swarm-* containers remain (warn but don't fail)
BENCH_CONTAINERS=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^chart-test-swarm-' || true)
if [ -n "$BENCH_CONTAINERS" ]; then
  echo "WARN: leftover chart-test-swarm-* containers found:" >&2
  echo "$BENCH_CONTAINERS" >&2
fi

exit 0
