#!/usr/bin/env bash
# Idempotent scaffold of chart-test/ inside a consumer chart project dir.
# Usage: scaffold-chart-test.sh <project_dir>
set -euo pipefail

PROJECT_DIR="${1:?usage: scaffold-chart-test.sh <project_dir>}"
[ -d "$PROJECT_DIR" ] || { echo "ERROR: not a dir: $PROJECT_DIR" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMPL="$SKILL_DIR/assets/chart-test-swarm.yaml.tmpl"

# Get chart name from Chart.yaml for project.name in the suite config.
chart_name="unknown"
if [ -f "$PROJECT_DIR/Chart.yaml" ]; then
  chart_dir="$PROJECT_DIR"
elif [ -f "$PROJECT_DIR/chart/Chart.yaml" ]; then
  chart_dir="$PROJECT_DIR/chart"
else
  chart_dir=""
fi
if [ -n "$chart_dir" ]; then
  if command -v yq >/dev/null 2>&1; then
    chart_name=$(yq '.name' "$chart_dir/Chart.yaml")
  else
    chart_name=$(grep -E '^name:' "$chart_dir/Chart.yaml" | head -1 | awk '{print $2}' | tr -d '"')
  fi
fi

created=()
for sub in chart-test chart-test/scenarios chart-test/fixtures chart-test/assertions chart-test/reports; do
  if [ ! -d "$PROJECT_DIR/$sub" ]; then
    mkdir -p "$PROJECT_DIR/$sub"
    created+=("$sub/")
  fi
done

CFG="$PROJECT_DIR/chart-test-swarm.yaml"
if [ ! -f "$CFG" ]; then
  if [ -f "$TMPL" ]; then
    PROJECT_NAME="$chart_name" envsubst < "$TMPL" > "$CFG"
  else
    cat > "$CFG" <<EOF
schema_version: 1
project: { name: $chart_name }
scenarios_dir: chart-test/scenarios
suites:
  pr-subset:        { tag_filter: [pr-subset],        max_minutes: 15 }
  nightly-full:     { tag_filter: [nightly] }
  customer-replica: { tag_filter: [customer-replica] }
EOF
  fi
  created+=("chart-test-swarm.yaml")
fi

# .gitignore for reports
GI="$PROJECT_DIR/chart-test/.gitignore"
if [ ! -f "$GI" ]; then
  echo "reports/" > "$GI"
  created+=("chart-test/.gitignore")
fi

if [ ${#created[@]} -gt 0 ]; then
  echo "Scaffolded in $PROJECT_DIR:"
  for c in "${created[@]}"; do echo "  + $c"; done
else
  echo "chart-test/ scaffold already complete in $PROJECT_DIR (no-op)"
fi
