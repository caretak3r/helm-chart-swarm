#!/usr/bin/env bash
# prefix-check.sh — shared cluster-name prefix guard.
# Source this from every cluster-touching script BEFORE any kind/minikube/kubectl/helm operation.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/lib/prefix-check.sh"
#
# Requires: CLUSTER_NAME must be set (with a default in the caller if desired).
# Exits 1 with a stderr message if CLUSTER_NAME does not match
# ^chart-test-swarm-[a-z0-9-]+$ (i.e., must start with the prefix and have a
# non-empty suffix after the dash).

cts_check_cluster_name() {
  local name="${1:?cts_check_cluster_name: CLUSTER_NAME argument required}"
  # The name must match: chart-test-swarm-<suffix> where <suffix> is [a-z0-9-]+
  # and the suffix must be non-empty (bare "chart-test-swarm" is rejected).
  if ! printf '%s' "$name" | grep -qE '^chart-test-swarm-[a-z0-9-]+$'; then
    echo "ERROR: CLUSTER_NAME='$name' does not match required pattern ^chart-test-swarm-[a-z0-9-]+\$" >&2
    echo "       All cluster names must carry the chart-test-swarm- prefix with a non-empty suffix." >&2
    echo "       Example valid names: chart-test-swarm-test1, chart-test-swarm-pr-42, chart-test-swarm-mk-nightly" >&2
    return 1
  fi
  return 0
}

# cts_run_id_slug — sanitize a RUN_ID into a cluster-name-safe slug.
# Lowercases, maps every char outside [a-z0-9] to '-', collapses hyphen runs,
# trims leading/trailing hyphens, strips a leading "run-" (constant noise in
# default RUN_IDs like run-20260601-070133-7511), and truncates to the LAST
# 24 characters (the tail carries the timestamp+PID uniqueness). Falls back
# to the current PID if the result is empty, so the composed cluster name
# always satisfies ^chart-test-swarm-[a-z0-9-]+$.
cts_run_id_slug() {
  local raw="${1:-}"
  local slug
  slug=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-')
  slug="${slug#-}"
  slug="${slug%-}"
  slug="${slug#run-}"
  if [ "${#slug}" -gt 24 ]; then
    slug="${slug: -24}"
    slug="${slug#-}"
  fi
  if [ -z "$slug" ]; then
    slug="$$"
  fi
  printf '%s\n' "$slug"
}

# Validate immediately on source if CLUSTER_NAME is already set.
# (Callers that set CLUSTER_NAME later should call cts_check_cluster_name explicitly.)
if [ -n "${CLUSTER_NAME:-}" ]; then
  cts_check_cluster_name "$CLUSTER_NAME" || exit 1
fi
