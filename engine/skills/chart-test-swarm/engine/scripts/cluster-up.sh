#!/usr/bin/env bash
# Bring up a local cluster. kind by default; k3d if PROVIDER=k3d.
# Idempotent — re-running with the same CLUSTER_NAME is a no-op.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-chart-test-swarm}"
PROVIDER="${PROVIDER:-kind}"
K8S_VERSION="${K8S_VERSION:-}"          # e.g. v1.30.0 — provider-specific node image is resolved below
KIND_CONFIG="${KIND_CONFIG:-}"          # optional path to a kind --config file (per-scenario)

# ---- Cilium CNI fast-fail for non-kind providers ----
if [ "${CTS_CNI:-}" = "cilium" ] && [ "$PROVIDER" != "kind" ]; then
  echo "ERROR: Cilium-as-CNI is only supported on kind (provider='$PROVIDER' requested)." >&2
  echo "       Cilium must be installed during cluster bring-up, BEFORE the node-ready wait," >&2
  echo "       which is only implemented for kind in this engine." >&2
  exit 1
fi

case "$PROVIDER" in
  kind)
    command -v kind >/dev/null 2>&1 || { echo "ERROR: kind not installed (brew install kind)" >&2; exit 1; }

    # ---- Cilium CNI support ----
    if [ "${CTS_CNI:-}" = "cilium" ]; then
      if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
        echo "==> kind cluster '$CLUSTER_NAME' already exists (CNI: Cilium)"
      else
        echo "==> Creating kind cluster '$CLUSTER_NAME' (provider=$PROVIDER, CNI=cilium, no --wait)"
        args=(--name "$CLUSTER_NAME")
        [ -n "$KIND_CONFIG" ] && args+=(--config "$KIND_CONFIG")
        [ -n "$K8S_VERSION" ] && args+=(--image "kindest/node:${K8S_VERSION}")
        kind create cluster "${args[@]}"

        _cp_ip=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${CLUSTER_NAME}-control-plane" 2>/dev/null || echo "")
        if [ -z "$_cp_ip" ]; then
          echo "ERROR: unable to resolve control-plane IP for cluster '$CLUSTER_NAME' via docker inspect." >&2
          exit 1
        fi
        export K8S_SERVICE_HOST="$_cp_ip"
        echo "==> Resolved control-plane IP for Cilium: $K8S_SERVICE_HOST"

        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        bash "$SCRIPT_DIR/lib/install-cilium.sh"

        echo "==> Waiting for Cilium daemonset rollout..."
        kubectl --context "kind-${CLUSTER_NAME}" -n kube-system rollout status ds/cilium --timeout=5m
        echo "==> Waiting for all nodes to become Ready..."
        kubectl --context "kind-${CLUSTER_NAME}" wait --for=condition=Ready nodes --all --timeout=5m
      fi
      CONTEXT="kind-${CLUSTER_NAME}"
      kubectl config use-context "$CONTEXT" >/dev/null
      echo "==> Cluster nodes:"
      kubectl get nodes
      echo "==> OK: $CONTEXT ready (CNI: Cilium)"
      exit 0
    fi
    # ---- End Cilium CNI support ----

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
