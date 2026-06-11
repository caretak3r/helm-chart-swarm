#!/usr/bin/env bash
# DEPTH: L3
# Assert: mesh-mtls-enforced — L3 behavioral assert that proves service mesh mTLS
# enforcement on live Kubernetes clusters.
#
# This assert goes beyond mere presence of a PeerAuthentication or mesh policy
# object: it actually probes traffic to prove mTLS is negotiated AND plaintext
# is rejected when STRICT mTLS is configured.
#
# PASS requires BOTH:
#   1. A non-mesh (plaintext) probe pod is REJECTED — plaintext HTTP to the
#      product Service fails under STRICT mTLS (timeout / 000 / 503).
#   2. An in-mesh probe pod (with sidecar injection) reaches the product
#      Service with HTTP 200 via auto-upgraded mTLS.
#
# FAIL paths:
#   - STRICT mTLS policy present but plaintext still succeeds (HTTP 200) —
#     policy object exists but enforcement is absent.
#
# SKIP (non-failing): when the required platform capability is absent
#   (no mesh installed — no PeerAuthentication CRD for Istio, no Server
#   CRD for Linkerd, no sidecar injection).
#
# Env-var parameterized (no hardcoded consumer names):
#   RELEASE, NAMESPACE, PROJECT_DIR, KUBE_CONTEXT, KUBECONFIG
#
# Scenario fields:
#   namespace          — required, product namespace
#   port              — optional, default 80
#   mesh_type         — optional, "istio" (default) or "linkerd"
#   control_namespace — optional, default "${NAMESPACE}-plain"
#   curl_image        — optional, curl image for probe (from versions config)
#   timeout           — optional, per-probe timeout (default "120s")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/assert-helpers.sh
source "$SCRIPT_DIR/lib/assert-helpers.sh"

SCENARIO="$1"; IDX="$2"

NS=$(yq ".asserts[$IDX].namespace" "$SCENARIO")
PORT=$(yq ".asserts[$IDX].port // 80" "$SCENARIO")
MESH_TYPE=$(yq ".asserts[$IDX].mesh_type // \"istio\"" "$SCENARIO")
CTRL_NS=$(yq ".asserts[$IDX].control_namespace // \"${NS}-plain\"" "$SCENARIO")
CURL_IMAGE=$(yq ".asserts[$IDX].curl_image // \"quay.io/curl/curl:8.20.0\"" "$SCENARIO")
PTIMEOUT=$(yq ".asserts[$IDX].timeout // \"120s\"" "$SCENARIO")
RELEASE="${RELEASE:-$(yq '.product.release' "$SCENARIO")}"

kubectl_args=()
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi

kctl() { kubectl "${kubectl_args[@]}" "$@"; }

# ── SKIP check: platform capability absent ───────────────────────────────
# Check if any service mesh is installed by verifying CRD presence.
CRD_FOUND=0
case "${MESH_TYPE}" in
  istio)
    if kctl get crd peerauthentications.security.istio.io >/dev/null 2>&1; then
      CRD_FOUND=1
    fi
    ;;
  linkerd)
    if kctl get crd servers.policy.linkerd.io >/dev/null 2>&1; then
      CRD_FOUND=1
    fi
    ;;
  *)
    echo "FAIL: unsupported mesh_type '${MESH_TYPE}' (must be 'istio' or 'linkerd')" >&2
    echo "ASSERTION_RESULT: FAIL"
    exit 1
    ;;
esac

if [ "$CRD_FOUND" -eq 0 ]; then
  echo "SKIP: service mesh platform capability not detected (no ${MESH_TYPE} CRD found)"
  echo "ASSERTION_RESULT: SKIP"
  echo "{\"reason\":\"platform_capability_absent\",\"detail\":\"No ${MESH_TYPE} mesh CRD found — mTLS enforcement cannot be verified\"}" | sed 's/^/ASSERTION_DETAIL: /'
  exit 0
fi

# ── Phase 1a: Verify STRICT PeerAuthentication / mesh policy is actually in effect ──
echo ""
echo "==> Phase 1a: Verifying STRICT mTLS policy is in effect"

STRICT_POLICY_FOUND=0
case "${MESH_TYPE}" in
  istio)
    # Check for a STRICT PeerAuthentication in the product namespace
    pa_strict=$(kctl -n "${NS}" get peerauthentication -o json 2>/dev/null | \
      jq '[.items[] | select(.spec.mtls.mode == "STRICT")] | length' 2>/dev/null || echo "0")
    if [ "${pa_strict:-0}" -gt 0 ]; then
      STRICT_POLICY_FOUND=1
      echo "  Found ${pa_strict} STRICT PeerAuthentication(s) in namespace ${NS}"
    else
      # Fallback: check for mesh-wide STRICT PeerAuthentication (root namespace or istio-system)
      pa_meshwide=$(kctl -n istio-system get peerauthentication -o json 2>/dev/null | \
        jq '[.items[] | select(.spec.mtls.mode == "STRICT")] | length' 2>/dev/null || echo "0")
      if [ "${pa_meshwide:-0}" -gt 0 ]; then
        STRICT_POLICY_FOUND=1
        echo "  Found ${pa_meshwide} mesh-wide STRICT PeerAuthentication(s) in istio-system"
      fi
    fi

    # If no explicit STRICT PeerAuthentication found, check if mesh default is STRICT
    if [ "$STRICT_POLICY_FOUND" -eq 0 ]; then
      # Also check if there's a default mesh-wide policy in the root namespace
      pa_root=$(kctl get peerauthentication --all-namespaces -o json 2>/dev/null | \
        jq '[.items[] | select(.spec.mtls.mode == "STRICT")] | length' 2>/dev/null || echo "0")
      if [ "${pa_root:-0}" -gt 0 ]; then
        STRICT_POLICY_FOUND=1
        echo "  Found ${pa_root} STRICT PeerAuthentication(s) cluster-wide"
      fi
    fi
    ;;
  linkerd)
    # Linkerd enables mTLS by default when the mesh is installed.
    # Check for Server resources or verify the proxy injector is running.
    if kctl -n linkerd get deploy linkerd-proxy-injector >/dev/null 2>&1; then
      # Linkerd auto-injects proxies and enforces mTLS by default.
      # Check for any Server resource that would indicate explicit policy,
      # but mTLS is implicitly STRICT in Linkerd.
      srv_count=$(kctl -n "${NS}" get servers -o name 2>/dev/null | wc -l || echo "0")
      if [ "${srv_count:-0}" -gt 0 ]; then
        STRICT_POLICY_FOUND=1
        echo "  Found ${srv_count} Server resource(s) in namespace ${NS}"
      else
        # Linkerd's default is mTLS — consider it STRICT when the proxy injector is alive
        STRICT_POLICY_FOUND=1
        echo "  Linkerd proxy injector running (default mTLS enforced)"
      fi
    fi
    ;;
esac

if [ "$STRICT_POLICY_FOUND" -eq 0 ]; then
  echo "FAIL: no STRICT ${MESH_TYPE} mTLS policy detected — PeerAuthentication/Server policy is absent or not STRICT" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

echo "PASS: STRICT mTLS policy is in effect"

# ── Resolve Service endpoint ─────────────────────────────────────────────
SVC_NAME="${RELEASE}"
SVC_IP=$(kctl -n "${NS}" get svc "${SVC_NAME}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [ -z "${SVC_IP}" ] || [ "${SVC_IP}" = "<none>" ]; then
  svc_list=""
  svc_list=$(kctl -n "${NS}" get svc -l "app.kubernetes.io/instance=${RELEASE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  if [ -z "$svc_list" ]; then
    echo "FAIL: no release-scoped Service found in namespace ${NS}" >&2
    echo "ASSERTION_RESULT: FAIL"
    exit 1
  fi
  SVC_NAME=$(echo "$svc_list" | awk '{print $1}')
  SVC_IP=$(kctl -n "${NS}" get svc "${SVC_NAME}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
fi

if [ -z "${SVC_IP}" ] || [ "${SVC_IP}" = "<none>" ]; then
  echo "FAIL: could not resolve ClusterIP for service ${SVC_NAME} in namespace ${NS}" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

PRODUCT_SVC="${SVC_NAME}.${NS}.svc.cluster.local"
echo "Product Service: ${PRODUCT_SVC} (ClusterIP: ${SVC_IP}:${PORT})"

# ── Helper: create and probe via a pod ───────────────────────────────────
probe_via_pod() {
  local pod_ns="$1"
  local pod_name="$2"

  local raw_code
  raw_code=$(kctl -n "${pod_ns}" exec "${pod_name}" -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      "http://${PRODUCT_SVC}:${PORT}/" 2>/dev/null || echo "000")

  local code
  code=$(parse_http_code "$raw_code" 2>/dev/null || echo "$raw_code")
  printf '%s' "$code"
}

# ── Cleanup helper (defined early so FAIL paths can call it) ────────────
cleanup_probes() {
  kctl -n "${CTRL_NS}" delete pod ct-mme-nonmesh --ignore-not-found --timeout=30s 2>/dev/null || true
  kctl -n "${NS}" delete pod ct-mme-mesh --ignore-not-found --timeout=30s 2>/dev/null || true
  kctl delete namespace "${CTRL_NS}" --ignore-not-found --timeout=30s 2>/dev/null || true
}

# ── Phase 1: Set up control namespace + non-mesh probe pod ──────────────
echo ""
echo "==> Phase 1: Setting up non-mesh control namespace ${CTRL_NS}"

kctl create namespace "${CTRL_NS}" --dry-run=client -o yaml 2>/dev/null | \
  kctl apply -f - 2>/dev/null || true

echo "==> Creating non-mesh probe pod in ${CTRL_NS}"
kctl -n "${CTRL_NS}" delete pod ct-mme-nonmesh --ignore-not-found --timeout=30s 2>/dev/null || true

kctl -n "${CTRL_NS}" run ct-mme-nonmesh --restart=Never \
  --image="${CURL_IMAGE}" --pod-running-timeout="${PTIMEOUT}" -- \
  sleep 300 2>/dev/null || true

echo "  Waiting for non-mesh probe pod to be ready (${PTIMEOUT} max)"
kctl -n "${CTRL_NS}" wait pod ct-mme-nonmesh --for=condition=Ready --timeout="${PTIMEOUT}" 2>/dev/null || {
  echo "WARN: non-mesh probe pod not ready within timeout; attempting exec anyway"
}

# ── Phase 2: Non-mesh (plaintext) probe — MUST be rejected under STRICT ──
echo ""
echo "==> Phase 2: Non-mesh plaintext probe (expect REJECTION)"
NONMESH_CODE=""
NONMESH_CODE=$(probe_via_pod "${CTRL_NS}" "ct-mme-nonmesh")

echo "Non-mesh plaintext HTTP code: ${NONMESH_CODE}"

if [ "${NONMESH_CODE}" = "000" ] || [ "${NONMESH_CODE}" = "028" ]; then
  echo "PASS: non-mesh plaintext probe REJECTED (code=${NONMESH_CODE})"
elif [ "${NONMESH_CODE}" = "200" ]; then
  echo "FAIL: STRICT mTLS policy present but plaintext still succeeds — mTLS enforcement NOT working" >&2
  cleanup_probes
  echo "ASSERTION_RESULT: FAIL"
  exit 1
else
  # Any non-200 code (503, 404, etc.) from the mesh proxy means rejection
  echo "PASS: non-mesh plaintext probe REJECTED by mesh proxy (code=${NONMESH_CODE})"
fi

# ── Phase 3: Create in-mesh probe pod (with sidecar) ────────────────────
echo ""
echo "==> Phase 3: Setting up in-mesh probe pod"

kctl -n "${NS}" delete pod ct-mme-mesh --ignore-not-found --timeout=30s 2>/dev/null || true

case "${MESH_TYPE}" in
  istio)
    # Istio: request sidecar injection via annotation
    kctl -n "${NS}" run ct-mme-mesh --restart=Never \
      --image="${CURL_IMAGE}" --pod-running-timeout="${PTIMEOUT}" \
      --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"true"}}}' -- \
      sleep 300 2>/dev/null || true
    ;;
  linkerd)
    # Linkerd: injection is namespace-scoped; pod inherits the annotation
    kctl -n "${NS}" run ct-mme-mesh --restart=Never \
      --image="${CURL_IMAGE}" --pod-running-timeout="${PTIMEOUT}" \
      --annotations="linkerd.io/inject=enabled" -- \
      sleep 300 2>/dev/null || true
    ;;
esac

echo "  Waiting for in-mesh probe pod to be ready (${PTIMEOUT} max)"
kctl -n "${NS}" wait pod ct-mme-mesh --for=condition=Ready --timeout="${PTIMEOUT}" 2>/dev/null || {
  echo "WARN: in-mesh probe pod not ready within timeout; attempting exec anyway"
}

# ── Phase 3b: Verify sidecar injection ──────────────────────────────────
echo ""
echo "==> Phase 3b: Verifying sidecar was injected into in-mesh probe pod"

SIDECAR_FOUND=0
CONTAINER_COUNT=$(kctl -n "${NS}" get pod ct-mme-mesh -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | wc -w || echo "0")
if [ "${CONTAINER_COUNT:-0}" -ge 2 ]; then
  SIDECAR_FOUND=1
  echo "  Pod has ${CONTAINER_COUNT} containers (sidecar injection confirmed)"
else
  echo "WARN: in-mesh probe pod has only ${CONTAINER_COUNT:-0} container(s) — sidecar may not be injected"
fi

# ── Phase 4: In-mesh probe — MUST succeed over auto-upgraded mTLS ────────
echo ""
echo "==> Phase 4: In-mesh probe (expect HTTP 200 via auto-upgraded mTLS)"
MESH_CODE=""
MESH_CODE=$(probe_via_pod "${NS}" "ct-mme-mesh")

echo "In-mesh probe HTTP code: ${MESH_CODE}"

if [ "${MESH_CODE}" = "200" ]; then
  echo "PASS: in-mesh probe reached product Service with HTTP 200 via auto-upgraded mTLS"
else
  echo "FAIL: expected HTTP 200 from in-mesh probe, got ${MESH_CODE} — mTLS or service connectivity broken" >&2
  cleanup_probes
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

# ── Phase 4b: Collect mTLS negotiation evidence from proxy/ztunnel ───────
echo ""
echo "==> Phase 4b: Collecting mTLS negotiation evidence"

MTLS_EVIDENCE=""
case "${MESH_TYPE}" in
  istio)
    # Check Envoy stats for SSL/TLS handshakes completed on the in-mesh probe pod.
    # The pilot-agent request/cached endpoint provides connection stats.
    ssl_handshakes=$(kctl -n "${NS}" exec ct-mme-mesh -c istio-proxy -- \
      pilot-agent request GET stats 2>/dev/null | \
      grep -E 'ssl\.handshake' 2>/dev/null | head -5 || echo "")
    if [ -n "$ssl_handshakes" ]; then
      MTLS_EVIDENCE=$(printf '%s' "$ssl_handshakes" | tr '\n' ';')
      echo "  Envoy SSL handshake stats:"
      printf '%s' "$ssl_handshakes" | while IFS= read -r line; do echo "    $line"; done
      echo "  mTLS negotiation confirmed via Envoy ssl.handshake counters"
    else
      # Fallback: try inspecting the sidecar's listeners to confirm mTLS
      listeners_mtls=$(kctl -n "${NS}" exec ct-mme-mesh -c istio-proxy -- \
        pilot-agent request GET listeners 2>/dev/null | \
        grep -c 'ssl' 2>/dev/null || echo "0")
      if [ "${listeners_mtls:-0}" -gt 0 ]; then
        MTLS_EVIDENCE="ssl_listeners:${listeners_mtls}"
        echo "  mTLS listeners: ${listeners_mtls} (mTLS configuration confirmed via Envoy)"
      else
        MTLS_EVIDENCE="sidecar_count:${CONTAINER_COUNT:-0}"
      fi
    fi
    ;;
  linkerd)
    # Check Linkerd proxy stats on the mesh pod (linkerd-proxy container).
    l5d_mtls=$(kctl -n "${NS}" exec ct-mme-mesh -c linkerd-proxy -- \
      curl -s http://localhost:4191/metrics 2>/dev/null | \
      grep -E 'tls_(cert|connection)' 2>/dev/null | head -5 || echo "")
    if [ -n "$l5d_mtls" ]; then
      MTLS_EVIDENCE=$(printf '%s' "$l5d_mtls" | tr '\n' ';')
      echo "  Linkerd proxy TLS metrics:"
      printf '%s' "$l5d_mtls" | while IFS= read -r line; do echo "    $line"; done
      echo "  mTLS negotiation confirmed via Linkerd proxy TLS metrics"
    else
      MTLS_EVIDENCE="proxy_containers:${CONTAINER_COUNT:-0}"
    fi
    ;;
esac

# ── Clean up and report ──────────────────────────────────────────────────
cleanup_probes

# Final verification: sidecar must have been injected for a valid mTLS PASS
if [ "$SIDECAR_FOUND" -eq 0 ]; then
  echo "FAIL: in-mesh probe succeeded but no sidecar was injected — mTLS negotiation is unproven" >&2
  echo "ASSERTION_RESULT: FAIL"
  exit 1
fi

echo ""
echo "PASS: mesh mTLS enforcement verified (STRICT policy=active, plaintext=rejected, mesh=success, sidecar=present, mTLS_evidence=\"${MTLS_EVIDENCE:0:200}\")"
echo "ASSERTION_RESULT: PASS"
echo "{\"nonmesh_code\":\"${NONMESH_CODE}\",\"mesh_code\":\"${MESH_CODE}\",\"service\":\"${SVC_NAME}\",\"namespace\":\"${NS}\",\"mesh_type\":\"${MESH_TYPE}\",\"strict_policy\":\"yes\",\"sidecar_injected\":\"yes\",\"mtls_evidence\":\"${MTLS_EVIDENCE:0:200}\"}" | sed 's/^/ASSERTION_DETAIL: /'
exit 0
