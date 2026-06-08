#!/usr/bin/env bash
# Stub for chart-test-swarm run during generate explore tests.
#
# Usage:
#   CTS_RUN_CMD="bash tests/stubs/run-stub.sh" \
#     chart-test-swarm generate explore ...
#
# Simulates a successful or failed scenario run by creating a minimal
# reports/run-* directory with a result.yaml and artifacts/.
#
# Modes (via RUN_STUB_STATUS):
#   PASS (default) — emit a PASS result
#   FAIL          — emit a FAIL result
#
# Logs the scenario file path to stderr for test assertions.

set -euo pipefail

RUN_ID="run-test-$(date +%Y%m%d-%H%M%S)-$$"
STATUS="${RUN_STUB_STATUS:-PASS}"

echo "$RUN_ID"

# Parse --scenario flag if present
SCENARIO_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario|-s) SCENARIO_PATH="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "RUN_STUB scenario_path=$SCENARIO_PATH" >&2
echo "RUN_STUB run_id=$RUN_ID" >&2
echo "RUN_STUB status=$STATUS" >&2

# Determine reports directory: explicit REPORTS_DIR env var, or a temp dir.
# This prevents test artifacts from polluting engine/testgrid/reports/.
_REPORTS_DIR="${REPORTS_DIR:-}"
if [[ -z "$_REPORTS_DIR" ]]; then
  _REPORTS_DIR="$(mktemp -d)"
  echo "RUN_STUB reports_dir=$_REPORTS_DIR (auto-temp)" >&2
else
  echo "RUN_STUB reports_dir=$_REPORTS_DIR (from REPORTS_DIR)" >&2
fi

# Create minimal reports directory
mkdir -p "$_REPORTS_DIR/$RUN_ID/artifacts"

# Write result.yaml
cat > "$_REPORTS_DIR/$RUN_ID/result.yaml" <<YAMLEOF
run_id: "$RUN_ID"
status: $STATUS
scenarios:
  - id: llm-generated-scenario
    status: $STATUS
    assertions_pass: $([ "$STATUS" = "PASS" ] && echo "2" || echo "0")
    assertions_fail: $([ "$STATUS" = "PASS" ] && echo "0" || echo "2")
YAMLEOF

# Write minimal artifact files
if [[ -n "$SCENARIO_PATH" && -f "$SCENARIO_PATH" ]]; then
  cp "$SCENARIO_PATH" "$_REPORTS_DIR/$RUN_ID/artifacts/scenario.yaml" 2>/dev/null || true
fi

touch "$_REPORTS_DIR/$RUN_ID/artifacts/applied-overrides.yaml"
echo '{"helm":"v3.16.0","kubectl":"v1.30.0","kind":"v0.24.0","minikube":"v1.34.0","k8s_server":"v1.30.0"}' > "$_REPORTS_DIR/$RUN_ID/artifacts/versions.json"
