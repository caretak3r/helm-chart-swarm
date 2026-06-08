#!/usr/bin/env bash
# Install Cilium as the cluster CNI in kube-proxy replacement mode.
# Invoked by cluster-up.sh when CTS_CNI=cilium (kind only).
#
# Expects: CTS_CNI_VERSION, CTS_CNI_KPR, CTS_CNI_VALUES, K8S_SERVICE_HOST
#   CTS_CNI_VERSION  — explicit Cilium chart version (takes precedence)
#   CTS_CNI_KPR      — kube-proxy replacement flag (default: true)
#   CTS_CNI_VALUES   — optional path to Cilium helm values file
#   K8S_SERVICE_HOST — control-plane IP on the kind docker network
#
# Version resolution: CTS_CNI_VERSION → merged versions.yaml cni.cilium.version → fallback 1.19.4
set -euo pipefail

# ---- Resolve script/engine dirs ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---- Fallback version (no-config case) ----
FALLBACK_CILIUM_VERSION="1.19.4"

# ---- _read_cni_version: read cni.cilium.version from merged versions config ----
# Mirrors _read_k8s_version_from_config in cluster-up.sh.
# Usage: _read_cni_version
# Outputs the raw version string from config, or empty if not found / yq unavailable.
_read_cni_version() {
  local engine_defaults="$ENGINE_DIR/defaults/versions.yaml"
  command -v yq >/dev/null 2>&1 || { echo ""; return; }
  [ -f "$engine_defaults" ] || { echo ""; return; }

  local project_versions="${PROJECT_DIR:-}/chart-test/versions.yaml"
  local merged=""

  if [ -n "${PROJECT_DIR:-}" ] && [ -f "$project_versions" ]; then
    # shellcheck disable=SC2016  # single quotes intentional: $item is a yq variable
    merged=$(yq eval-all '. as $item ireduce ({}; . * $item)' \
      "$engine_defaults" "$project_versions" 2>/dev/null)
  else
    merged=$(yq '.' "$engine_defaults" 2>/dev/null)
  fi

  if [ -n "$merged" ]; then
    echo "$merged" | yq '.cni.cilium.version // ""' 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# ---- Resolve cilium version ----
CILIUM_VERSION="${CTS_CNI_VERSION:-}"
if [ -z "$CILIUM_VERSION" ] || [ "$CILIUM_VERSION" = "null" ]; then
  _cfg_cilium_ver="$(_read_cni_version)"
  if [ -n "$_cfg_cilium_ver" ] && [ "$_cfg_cilium_ver" != "null" ] && [ "$_cfg_cilium_ver" != "" ]; then
    CILIUM_VERSION="$_cfg_cilium_ver"
    echo "==> cilium version from config: $CILIUM_VERSION"
  else
    CILIUM_VERSION="$FALLBACK_CILIUM_VERSION"
    echo "==> cilium version from fallback: $CILIUM_VERSION"
  fi
fi

# ---- Resolve kube-proxy replacement flag ----
CILIUM_KPR="${CTS_CNI_KPR:-true}"

# ---- Ensure helm repo is present ----
helm repo add cilium https://helm.cilium.io 2>/dev/null || true
helm repo update 2>/dev/null || true

# ---- Build and execute helm install/upgrade command ----
echo "==> Installing Cilium CNI (version=$CILIUM_VERSION, kubeProxyReplacement=$CILIUM_KPR)"
# K8S_SERVICE_HOST is expected to be set by the caller (cluster-up.sh)
# after resolving the control-plane IP via docker inspect.
SVC_HOST="${K8S_SERVICE_HOST:-}"
if [ -z "$SVC_HOST" ]; then
  echo "ERROR: K8S_SERVICE_HOST is not set — cannot install Cilium without the API server host IP." >&2
  echo "       cluster-up.sh must resolve the control-plane IP via docker inspect and export K8S_SERVICE_HOST." >&2
  exit 1
fi

helm_args=(
  upgrade --install cilium cilium/cilium
  --version "$CILIUM_VERSION"
  --namespace kube-system
  --set "kubeProxyReplacement=$CILIUM_KPR"
  --set "k8sServiceHost=$SVC_HOST"
  --set k8sServicePort=6443
  --set operator.replicas=1
  --set ipam.mode=kubernetes
)

# Include optional values file
if [ -n "${CTS_CNI_VALUES:-}" ] && [ -f "$CTS_CNI_VALUES" ]; then
  echo "==> Using Cilium values file: $CTS_CNI_VALUES"
  helm_args+=(-f "$CTS_CNI_VALUES")
fi

# The actual helm command — stubbed in bats via PATH override
if ! helm "${helm_args[@]}" 2>&1; then
  echo "ERROR: helm install/upgrade cilium failed" >&2
  exit 1
fi

echo "==> Cilium CNI installed successfully"
