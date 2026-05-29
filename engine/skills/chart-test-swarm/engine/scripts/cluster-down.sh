#!/usr/bin/env bash
# Tear down the local cluster. Idempotent.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-chart-test-swarm}"
PROVIDER="${PROVIDER:-kind}"

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

  *)
    echo "ERROR: unknown PROVIDER='$PROVIDER' (supported: kind, k3d)" >&2
    exit 1
    ;;
esac
