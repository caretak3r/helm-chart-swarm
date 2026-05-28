#!/usr/bin/env bash
# Preflight: every command + file the engine needs. Exit 1 with a punch list.
set -euo pipefail

# ---- Usage banner (checked before bash version preflight so --help always works) ----
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Preflight check: verify every command and file the engine needs.
Exits 0 if all checks pass; exits 1 with a punch list of missing items.

Options:
  --help    Show this usage banner and exit
EOF
  exit 0
}

case "${1:-}" in
  --help|-h) usage ;;
esac

# ---- Bash version preflight (VAL-ENGINE-039) ----
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "ERROR: bash >= 4 required (running ${BASH_VERSION:-unknown})." >&2
  echo "       Install modern bash: brew install bash" >&2
  echo "       Then re-run with: /opt/homebrew/bin/bash $0 $*" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"

REQUIRED_SCRIPTS=(verify.sh cluster-up.sh cluster-down.sh)

# Phase 1 only checks scripts that exist now. Later phases append theirs.
[ -f "$SCRIPT_DIR/run-scenario.sh"  ] && REQUIRED_SCRIPTS+=(run-scenario.sh apply-scenario.sh)
[ -f "$SCRIPT_DIR/dispatch-swarm.sh" ] && REQUIRED_SCRIPTS+=(dispatch-swarm.sh aggregate.sh build-dashboard.sh)

missing=0

note_missing() { echo "MISSING: $*" >&2; missing=1; }

for s in "${REQUIRED_SCRIPTS[@]}"; do
  if [ ! -x "$SCRIPT_DIR/$s" ]; then
    note_missing "$SCRIPT_DIR/$s (not executable or absent)"
  fi
done

# Tooling — at least one of kind/k3d, plus the rest are non-negotiable.
have_kind=0; have_k3d=0
command -v kind >/dev/null 2>&1 && have_kind=1
command -v k3d  >/dev/null 2>&1 && have_k3d=1
if [ $have_kind -eq 0 ] && [ $have_k3d -eq 0 ]; then
  note_missing "kind OR k3d (brew install kind | brew install k3d)"
fi

command -v kubectl >/dev/null 2>&1 || note_missing "kubectl"
command -v helm    >/dev/null 2>&1 || note_missing "helm"
command -v yq      >/dev/null 2>&1 || note_missing "yq (brew install yq)"
command -v jq      >/dev/null 2>&1 || note_missing "jq"

# uv is needed for the dashboard. Treat as a warning in Phase 1.
if ! command -v uv >/dev/null 2>&1; then
  echo "WARN: uv missing — dashboard build will be skipped (brew install uv)" >&2
fi

if [ $missing -ne 0 ]; then
  echo "" >&2
  echo "Preflight failed. ROOT=$ROOT_DIR" >&2
  exit 1
fi

echo "OK: engine scripts present at $SCRIPT_DIR/"
echo "OK: kind=$have_kind k3d=$have_k3d kubectl=yes helm=yes yq=yes jq=yes"
