#!/usr/bin/env bash
# Invoke testgrid to build the static HTML dashboard.
# Best-effort: tolerates missing uv (warns + exits 0 — swarm not affected).
#
# Usage:  build-dashboard.sh [run-id]
# Env:    REPORTS_DIR   reports root (default: $PROJECT_DIR/chart-test/reports
#                       if discoverable, else $ROOT_DIR/reports)
#         DASHBOARD_OUT dashboard dist root (default: $REPORTS_DIR/dist)
#         PROJECT_DIR   consumer chart repo (used to compute default REPORTS_DIR)
set -euo pipefail

# ---- Usage banner ----
usage() {
  cat <<EOF
Usage: $(basename "$0") [run-id] [OPTIONS]

Invoke testgrid to build the static HTML dashboard from scenario run results.
Best-effort: tolerates missing uv (warns + exits 0 — swarm not affected).

Options:
  --help    Show this usage banner and exit

Arguments:
  run-id    Optional specific run id to render (default: render all runs)

Environment:
  REPORTS_DIR    Reports root (default: auto-detected from PROJECT_DIR or ROOT_DIR)
  DASHBOARD_OUT  Dashboard dist root (default: \$REPORTS_DIR/dist)
  PROJECT_DIR    Consumer chart repo (for computing default REPORTS_DIR)
EOF
  exit 0
}

case "${1:-}" in
  --help|-h) usage ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
TESTGRID_DIR="$(cd "$ENGINE_DIR/testgrid" && pwd)"
RUN="${1:-}"

if ! command -v uv >/dev/null 2>&1; then
  echo "WARN: uv missing — skipping dashboard build (brew install uv)" >&2
  exit 0
fi

if [ ! -f "$TESTGRID_DIR/pyproject.toml" ]; then
  echo "WARN: testgrid not found at $TESTGRID_DIR — skipping" >&2
  exit 0
fi

# Reports root: explicit env > project's chart-test/reports > engine root reports
if [ -n "${REPORTS_DIR:-}" ]; then
  _REPORTS_ROOT="$REPORTS_DIR"
elif [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR/chart-test" ]; then
  _REPORTS_ROOT="$PROJECT_DIR/chart-test/reports"
else
  _REPORTS_ROOT="$ROOT_DIR/reports"
fi

DASHBOARD_OUT="${DASHBOARD_OUT:-$_REPORTS_ROOT/dist}"

args=(run testgrid build --reports "$_REPORTS_ROOT" --out "$DASHBOARD_OUT")
[ -n "$RUN" ] && args+=(--run "$RUN")

cd "$TESTGRID_DIR"
uv "${args[@]}"
