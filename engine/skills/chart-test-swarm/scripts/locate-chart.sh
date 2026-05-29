#!/usr/bin/env bash
# Walk up from CWD (or $1) until we find a Helm Chart.yaml.
# Emit JSON to stdout: {chart_dir, name, version, project_dir, has_chart_test}.
# Exit 1 if no Chart.yaml found.
set -euo pipefail

START="${1:-$PWD}"
[ -d "$START" ] || { echo "ERROR: not a dir: $START" >&2; exit 1; }

d="$(cd "$START" && pwd)"
chart_dir=""
while [ "$d" != "/" ]; do
  if [ -f "$d/Chart.yaml" ]; then
    chart_dir="$d"
    break
  fi
  d="$(dirname "$d")"
done

if [ -z "$chart_dir" ]; then
  echo "ERROR: no Chart.yaml found at or above $START" >&2
  exit 1
fi

# project_dir = parent of chart_dir IF chart_dir is named "chart" or similar,
# otherwise project_dir = chart_dir itself. We're permissive: prefer the
# parent if a chart-test/ already exists there or a chart-test-swarm.yaml.
project_dir="$chart_dir"
parent="$(dirname "$chart_dir")"
if [ -d "$parent/chart-test" ] || [ -f "$parent/chart-test-swarm.yaml" ]; then
  project_dir="$parent"
elif [ "$(basename "$chart_dir")" = "chart" ]; then
  # Convention from our example layout: chart/ lives under project_dir/
  project_dir="$parent"
fi

# Parse name/version. Prefer yq if available; fall back to grep.
if command -v yq >/dev/null 2>&1; then
  name=$(yq '.name'    "$chart_dir/Chart.yaml")
  ver=$(yq  '.version' "$chart_dir/Chart.yaml")
else
  name=$(grep -E '^name:'    "$chart_dir/Chart.yaml" | head -1 | awk '{print $2}' | tr -d '"')
  ver=$(grep  -E '^version:' "$chart_dir/Chart.yaml" | head -1 | awk '{print $2}' | tr -d '"')
fi

has_chart_test=false
[ -d "$project_dir/chart-test" ] && has_chart_test=true

# Emit JSON manually (avoid jq dep for this small one)
cat <<EOF
{
  "chart_dir": "$chart_dir",
  "name": "$name",
  "version": "$ver",
  "project_dir": "$project_dir",
  "has_chart_test": $has_chart_test
}
EOF
