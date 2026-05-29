#!/usr/bin/env bash
# Bring up a local cluster. kind by default; minikube or k3d if PROVIDER is set.
# Idempotent — re-running with the same CLUSTER_NAME is a no-op.
# Does NOT mutate the user's global active kubeconfig context.
set -euo pipefail

# ---- Usage banner (checked before bash version preflight so --help always works) ----
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Bring up a local Kubernetes cluster (kind by default; minikube or k3d if PROVIDER is set).
Idempotent — re-running with the same CLUSTER_NAME is a no-op.
Does NOT mutate the user's global active kubeconfig context.

Options:
  --help    Show this usage banner and exit

Environment:
  CLUSTER_NAME  Cluster name (must match ^chart-test-swarm-[a-z0-9-]+\$; default: chart-test-swarm-default)
  PROVIDER       Cluster provider: kind|minikube|k3d (default: kind)
  K8S_VERSION    Kubernetes version, e.g. v1.30.0
  KIND_CONFIG    Path to kind --config file
EOF
  exit 0
}

case "${1:-}" in
  --help|-h) usage ;;
esac

# ---- Bash version preflight (VAL-ENGINE-039) ----
# Engine scripts use bash-4+ features (mapfile, associative arrays).
# On macOS default bash 3.2, fail preflight with a clear version error
# instead of the cryptic "mapfile: command not found".
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "ERROR: bash >= 4 required (running ${BASH_VERSION:-unknown})." >&2
  echo "       Install modern bash: brew install bash" >&2
  echo "       Then re-run with: /opt/homebrew/bin/bash $0 $*" >&2
  exit 1
fi

# Default cluster name satisfies ^chart-test-swarm-[a-z0-9-]+$
CLUSTER_NAME="${CLUSTER_NAME:-chart-test-swarm-default}"
PROVIDER="${PROVIDER:-kind}"
K8S_VERSION="${K8S_VERSION:-}"          # e.g. v1.30.0 — provider-specific node image is resolved below
KIND_CONFIG="${KIND_CONFIG:-}"          # optional path to a kind --config file (per-scenario)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source the shared prefix guard — exits 1 if CLUSTER_NAME doesn't match ^chart-test-swarm-[a-z0-9-]+$
. "$SCRIPT_DIR/lib/prefix-check.sh"

# ---- Save the caller's current kubeconfig context so we can restore it ----
SAVED_CONTEXT=""
if command -v kubectl >/dev/null 2>&1; then
  SAVED_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
fi

# CTS_NO_CONTEXT_RESTORE=1 defers context restore to the parent (e.g. run-scenario.sh).
# When set, cluster-up.sh does NOT restore the original context on exit so the
# scenario workflow (apply-scenario.sh, run-asserts.sh) runs against the cluster
# without a race window where the global context flips back to the caller's.
CTS_NO_CONTEXT_RESTORE="${CTS_NO_CONTEXT_RESTORE:-0}"

# Cleanup: restore the original kubeconfig context on exit (only when not deferred).
restore_context() {
  if [ "$CTS_NO_CONTEXT_RESTORE" = "1" ]; then
    return 0
  fi
  if [ -n "${SAVED_CONTEXT:-}" ] && command -v kubectl >/dev/null 2>&1; then
    # Only restore if the current context isn't already what we want
    current=$(kubectl config current-context 2>/dev/null || echo "")
    if [ "$current" != "$SAVED_CONTEXT" ]; then
      kubectl config use-context "$SAVED_CONTEXT" >/dev/null 2>&1 || true
    fi
  fi
}
trap 'restore_context' EXIT

case "$PROVIDER" in
  kind)
    command -v kind >/dev/null 2>&1 || { echo "ERROR: kind not installed (brew install kind)" >&2; exit 1; }

    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
      echo "==> kind cluster '$CLUSTER_NAME' already exists"
    else
      echo "==> Creating kind cluster '$CLUSTER_NAME' (provider=$PROVIDER)"
      args=(--name "$CLUSTER_NAME" --wait 60s)
      [ -n "$KIND_CONFIG" ] && args+=(--config "$KIND_CONFIG")
      [ -n "$K8S_VERSION" ] && args+=(--image "kindest/node:${K8S_VERSION}")
      kind create cluster "${args[@]}"
    fi
    CONTEXT="kind-${CLUSTER_NAME}"
    ;;

  minikube)
    command -v minikube >/dev/null 2>&1 || { echo "ERROR: minikube not installed (brew install minikube)" >&2; exit 1; }

    # Check if profile already exists and is running
    existing_status=$(minikube status -p "$CLUSTER_NAME" -o json 2>/dev/null | jq -r '.Host // empty' 2>/dev/null || echo "")
    if [ "$existing_status" = "Running" ]; then
      echo "==> minikube profile '$CLUSTER_NAME' already running"
    else
      echo "==> Creating minikube profile '$CLUSTER_NAME' (provider=$PROVIDER)"
      mk_args=(-p "$CLUSTER_NAME" --wait=all --wait-timeout=180s)
      [ -n "$K8S_VERSION" ] && mk_args+=(--kubernetes-version="$K8S_VERSION")
      minikube start "${mk_args[@]}"
    fi
    CONTEXT="$CLUSTER_NAME"
    ;;

  k3d)
    command -v k3d >/dev/null 2>&1 || { echo "ERROR: k3d not installed (brew install k3d)" >&2; exit 1; }

    if k3d cluster list -o json 2>/dev/null | jq -e --arg n "$CLUSTER_NAME" '.[] | select(.name==$n)' >/dev/null; then
      echo "==> k3d cluster '$CLUSTER_NAME' already exists"
    else
      echo "==> Creating k3d cluster '$CLUSTER_NAME' (provider=$PROVIDER)"
      args=(cluster create "$CLUSTER_NAME" --wait)
      [ -n "$K8S_VERSION" ] && args+=(--image "rancher/k3s:${K8S_VERSION}-k3s1")
      k3d "${args[@]}"
    fi
    CONTEXT="k3d-${CLUSTER_NAME}"
    ;;

  *)
    echo "ERROR: unknown PROVIDER='$PROVIDER' (supported: kind, minikube, k3d)" >&2
    exit 1
    ;;
esac

# Set context for the duration of this script's execution (NOT the global default).
kubectl config use-context "$CONTEXT" >/dev/null
echo "==> Cluster nodes:"
kubectl get nodes
echo "==> OK: $CONTEXT ready"
if [ "$CTS_NO_CONTEXT_RESTORE" = "1" ]; then
  echo "==> Note: kubeconfig context set to '$CONTEXT' (context restore deferred to caller)."
else
  echo "==> Note: kubeconfig context was temporarily switched to '$CONTEXT' and will be restored on exit."
fi
