#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="/Users/rohit/Documents/chart-test-swarm"
TESTGRID_DIR="$REPO_ROOT/engine/testgrid"

log() { printf '[init] %s\n' "$*"; }
fail() { printf '[init][ERROR] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "required tool not found on PATH: $cmd"
}

log "checking required tools..."
for cmd in docker kubectl helm kind minikube uv ruff mypy pytest bats shellcheck yamllint jq yq curl make openssl jsonschema; do
  require_cmd "$cmd"
done
log "all 16 required tools present"

log "checking Docker Desktop is running..."
docker info >/dev/null 2>&1 || fail "docker is installed but daemon not reachable (start Docker Desktop)"

log "checking Docker available memory >= 12 GiB..."
docker_mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
min_mem=$((12 * 1024 * 1024 * 1024))
if [ "$docker_mem_bytes" -lt "$min_mem" ]; then
  log "WARN: Docker memory reports $((docker_mem_bytes / 1024 / 1024 / 1024)) GiB; mission assumes >= 12 GiB. Concurrency may be unstable."
else
  log "Docker memory: $((docker_mem_bytes / 1024 / 1024 / 1024)) GiB OK"
fi

log "syncing Python deps in $TESTGRID_DIR..."
if [ -f "$TESTGRID_DIR/pyproject.toml" ]; then
  uv sync --directory "$TESTGRID_DIR"
else
  log "WARN: $TESTGRID_DIR/pyproject.toml not yet present (F1.5 will create it)"
fi

log "ensuring chart-test-swarm- residue is clean before mission start..."
residual_kind=$(kind get clusters 2>/dev/null | grep '^chart-test-swarm-' || true)
if [ -n "$residual_kind" ]; then
  log "WARN: residual kind clusters found:\n$residual_kind"
  log "  tear down manually with: kind delete cluster --name <name>"
fi
residual_mk=$(minikube profile list -o json 2>/dev/null | jq -r '.valid[]?.Name' | grep '^chart-test-swarm-' || true)
if [ -n "$residual_mk" ]; then
  log "WARN: residual minikube profiles found:\n$residual_mk"
  log "  tear down manually with: minikube delete -p <name>"
fi

log "checking beads (bd) is available..."
if command -v bd >/dev/null 2>&1; then
  log "bd present; mission can open per-feature issues"
else
  log "WARN: bd not on PATH; mission workers will be unable to use bd. Install via 'cargo install beads' or equivalent."
fi

log "init complete"
