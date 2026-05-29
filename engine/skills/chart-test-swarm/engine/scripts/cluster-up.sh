#!/usr/bin/env bash
# Bring up a local cluster. kind by default; k3d if PROVIDER=k3d.
# Idempotent — re-running with the same CLUSTER_NAME is a no-op.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-chart-test-swarm}"
PROVIDER="${PROVIDER:-kind}"
K8S_VERSION="${K8S_VERSION:-}"          # e.g. v1.30.0 — provider-specific node image is resolved below
KIND_CONFIG="${KIND_CONFIG:-}"          # optional path to a kind --config file (per-scenario)

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
    echo "ERROR: unknown PROVIDER='$PROVIDER' (supported: kind, k3d)" >&2
    exit 1
    ;;
esac

kubectl config use-context "$CONTEXT" >/dev/null
echo "==> Cluster nodes:"
kubectl get nodes
echo "==> OK: $CONTEXT ready"
