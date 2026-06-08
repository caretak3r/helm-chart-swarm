#!/usr/bin/env bash
# orphan-audit.sh — Orphan-cleanup audit for chart-test-swarm infrastructure.
#
# Confirms zero chart-test-swarm-* kind/minikube clusters (VAL-CROSS-016)
# and zero chart-test-swarm-* docker containers (VAL-CROSS-017) after
# scenario runs. Also serves as the enforcement mechanism for the
# cluster/container orphan invariant (VAL-ENGINE-023, VAL-ENGINE-024).
#
# Usage:   orphan-audit.sh [OPTIONS]
# Options: --fix    Attempt to tear down any orphans found (default: report only)
#          --help   Show usage banner and exit
# Exits:   0 if no orphans; 1 if orphans found (unless --fix succeeds)
set -euo pipefail

# ---- Usage banner ----
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Orphan-cleanup audit: confirm zero chart-test-swarm-* kind/minikube
clusters and zero chart-test-swarm-* docker containers.

Options:
  --fix    Attempt to tear down any orphans found (default: report only)
  --help   Show this usage banner and exit

Exits 0 if no orphans remain; exits 1 if orphans found (unless --fix
succeeds in removing them all).
EOF
  exit 0
}

FIX_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --fix)  FIX_MODE=1; shift ;;
    --help|-h) usage ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
  esac
done

ORPHANS_FOUND=0

# ---- Kind clusters (VAL-CROSS-016, VAL-ENGINE-023) ----
echo "==> Auditing kind clusters..."
ORPHAN_KIND_CLUSTERS=()
if command -v kind >/dev/null 2>&1; then
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    ORPHAN_KIND_CLUSTERS+=("$name")
  done < <(kind get clusters 2>/dev/null | grep '^chart-test-swarm-' || true)
fi

if [ ${#ORPHAN_KIND_CLUSTERS[@]} -gt 0 ]; then
  echo "  ORPHAN: ${#ORPHAN_KIND_CLUSTERS[@]} chart-test-swarm-* kind cluster(s) found:" >&2
  for c in "${ORPHAN_KIND_CLUSTERS[@]}"; do
    echo "    - $c" >&2
  done
  ORPHANS_FOUND=1

  if [ $FIX_MODE -eq 1 ]; then
    echo "  ==> Fixing: deleting orphan kind clusters..." >&2
    for c in "${ORPHAN_KIND_CLUSTERS[@]}"; do
      kind delete cluster --name "$c" && echo "    deleted: $c" || echo "    FAILED to delete: $c" >&2
    done
  fi
else
  echo "  OK: zero chart-test-swarm-* kind clusters"
fi

# ---- Minikube profiles (VAL-CROSS-016, VAL-ENGINE-023) ----
echo "==> Auditing minikube profiles..."
ORPHAN_MINIKUBE_PROFILES=()
if command -v minikube >/dev/null 2>&1; then
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    ORPHAN_MINIKUBE_PROFILES+=("$name")
  done < <(minikube profile list -o json 2>/dev/null | jq -r '.valid[]?.Name // empty' 2>/dev/null | grep '^chart-test-swarm-' || true)
fi

if [ ${#ORPHAN_MINIKUBE_PROFILES[@]} -gt 0 ]; then
  echo "  ORPHAN: ${#ORPHAN_MINIKUBE_PROFILES[@]} chart-test-swarm-* minikube profile(s) found:" >&2
  for p in "${ORPHAN_MINIKUBE_PROFILES[@]}"; do
    echo "    - $p" >&2
  done
  ORPHANS_FOUND=1

  if [ $FIX_MODE -eq 1 ]; then
    echo "  ==> Fixing: deleting orphan minikube profiles..." >&2
    for p in "${ORPHAN_MINIKUBE_PROFILES[@]}"; do
      minikube delete -p "$p" 2>/dev/null && echo "    deleted: $p" || echo "    FAILED to delete: $p" >&2
    done
  fi
else
  echo "  OK: zero chart-test-swarm-* minikube profiles"
fi

# ---- Docker containers (VAL-CROSS-017, VAL-ENGINE-024) ----
echo "==> Auditing docker containers..."
ORPHAN_CONTAINERS=()
if command -v docker >/dev/null 2>&1; then
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    ORPHAN_CONTAINERS+=("$name")
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^chart-test-swarm-' || true)
fi

if [ ${#ORPHAN_CONTAINERS[@]} -gt 0 ]; then
  echo "  ORPHAN: ${#ORPHAN_CONTAINERS[@]} chart-test-swarm-* docker container(s) found:" >&2
  for c in "${ORPHAN_CONTAINERS[@]}"; do
    echo "    - $c" >&2
  done
  ORPHANS_FOUND=1

  if [ $FIX_MODE -eq 1 ]; then
    echo "  ==> Fixing: removing orphan docker containers..." >&2
    for c in "${ORPHAN_CONTAINERS[@]}"; do
      docker rm -f "$c" 2>/dev/null && echo "    removed: $c" || echo "    FAILED to remove: $c" >&2
    done
  fi
else
  echo "  OK: zero chart-test-swarm-* docker containers"
fi

# ---- Summary ----
echo ""
if [ $ORPHANS_FOUND -eq 0 ]; then
  echo "==> Orphan audit PASSED: no chart-test-swarm-* orphans found"
  exit 0
else
  if [ $FIX_MODE -eq 1 ]; then
    echo "==> Orphan audit: fix attempted — re-audit recommended" >&2
    # Re-check after fix attempts
    exec "$0"  # Re-run without --fix to verify
  fi
  echo "==> Orphan audit FAILED: chart-test-swarm-* orphans found (use --fix to clean up)" >&2
  exit 1
fi
