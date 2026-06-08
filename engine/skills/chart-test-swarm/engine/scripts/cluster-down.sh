#!/usr/bin/env bash
# Tear down the local cluster. Idempotent — re-running exits 0.
set -euo pipefail

# ---- Usage banner (checked before bash version preflight so --help always works) ----
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Tear down a local Kubernetes cluster. Idempotent — re-running exits 0.

Options:
  --help    Show this usage banner and exit

Environment:
  CLUSTER_NAME  Cluster name (must match ^chart-test-swarm-[a-z0-9-]+\$; default: chart-test-swarm-default)
  PROVIDER       Cluster provider: kind|minikube|k3d (default: kind)
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

# Default cluster name satisfies ^chart-test-swarm-[a-z0-9-]+$
CLUSTER_NAME="${CLUSTER_NAME:-chart-test-swarm-default}"
PROVIDER="${PROVIDER:-kind}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source the shared prefix guard — exits 1 if CLUSTER_NAME doesn't match ^chart-test-swarm-[a-z0-9-]+$
. "$SCRIPT_DIR/lib/prefix-check.sh"

case "$PROVIDER" in
  kind)
    if ! command -v kind >/dev/null 2>&1; then
      echo "kind not installed; nothing to do"; exit 0
    fi
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
      echo "==> Deleting kind cluster '$CLUSTER_NAME'"
      kind delete cluster --name "$CLUSTER_NAME"
    else
      echo "==> No kind cluster named '$CLUSTER_NAME' to delete"
    fi
    ;;

  minikube)
    if ! command -v minikube >/dev/null 2>&1; then
      echo "minikube not installed; nothing to do"; exit 0
    fi
    # minikube delete is idempotent — it succeeds even if the profile doesn't exist.
    # But check first to avoid unnecessary output.
    profile_exists=$(minikube profile list -o json 2>/dev/null \
      | jq -r --arg n "$CLUSTER_NAME" '.valid[]? | select(.Name==$n) | .Name' 2>/dev/null || echo "")
    if [ "$profile_exists" = "$CLUSTER_NAME" ]; then
      echo "==> Deleting minikube profile '$CLUSTER_NAME'"
      minikube delete -p "$CLUSTER_NAME" 2>/dev/null || true
    else
      echo "==> No minikube profile named '$CLUSTER_NAME' to delete"
    fi
    # Re-running after successful delete should also exit 0 (idempotent)
    ;;

  k3d)
    if ! command -v k3d >/dev/null 2>&1; then
      echo "k3d not installed; nothing to do"; exit 0
    fi
    if k3d cluster list -o json 2>/dev/null | jq -e --arg n "$CLUSTER_NAME" '.[] | select(.name==$n)' >/dev/null; then
      echo "==> Deleting k3d cluster '$CLUSTER_NAME'"
      k3d cluster delete "$CLUSTER_NAME"
    else
      echo "==> No k3d cluster named '$CLUSTER_NAME' to delete"
    fi
    ;;

  gke|eks|aks)
    echo "==> Cloud-native provider '$PROVIDER' — authored only; skipping cluster teardown (no local cluster to remove)." >&2
    exit 0
    ;;

  *)
    echo "ERROR: unknown PROVIDER='$PROVIDER' (supported: kind, minikube, k3d)" >&2
    exit 1
    ;;
esac
