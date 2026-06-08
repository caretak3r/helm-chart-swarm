#!/usr/bin/env bash
# Cilium eBPF kube-proxy replacement smoke assertion.
# Verifies: KubeProxyReplacement: True, no kube-proxy daemonset,
#   product ClusterIP reachable through eBPF datapath (no kube-proxy).
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
CILIUM_NS="kube-system"
SVC_PORT=80

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Waiting for Cilium daemonset rollout (5m max)"
kctl -n "${CILIUM_NS}" rollout status ds/cilium --timeout=5m
echo "PASS: Cilium daemonset rolled out"

echo "==> Getting Cilium agent pod name"
CILIUM_POD=$(kctl -n "${CILIUM_NS}" get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
if [ -z "${CILIUM_POD}" ]; then
  echo "FAIL: No Cilium agent pod found in ${CILIUM_NS}" >&2
  exit 1
fi
echo "Cilium pod: ${CILIUM_POD}"

echo "==> Reading cilium status via kubectl exec"
CILIUM_STATUS=$(kctl -n "${CILIUM_NS}" exec "${CILIUM_POD}" -c cilium-agent -- cilium status 2>/dev/null || echo "")
if [ -z "${CILIUM_STATUS}" ]; then
  echo "FAIL: Could not read cilium status from ${CILIUM_POD}" >&2
  exit 1
fi

echo "==> Asserting KubeProxyReplacement: True"
# KubeProxyReplacement line looks like:
# KubeProxyReplacement:    True   [eth0 192.168.x.x (Direct Routing)]
KPR_LINE=$(echo "${CILIUM_STATUS}" | grep "KubeProxyReplacement" || true)
echo "KubeProxyReplacement line: ${KPR_LINE}"
if echo "${KPR_LINE}" | grep -q "True"; then
  echo "PASS: KubeProxyReplacement is True"
else
  echo "FAIL: KubeProxyReplacement is NOT True" >&2
  exit 1
fi

echo "==> Asserting no kube-proxy daemonset in kube-system"
if kctl -n "${CILIUM_NS}" get ds kube-proxy >/dev/null 2>&1; then
  echo "FAIL: kube-proxy daemonset still present in ${CILIUM_NS}" >&2
  exit 1
else
  echo "PASS: kube-proxy daemonset NOT found (fully replaced by Cilium eBPF)"
fi

echo "==> Getting product Service ClusterIP"
SVC_IP=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.clusterIP}')
if [ -z "${SVC_IP}" ]; then
  echo "FAIL: Could not get ClusterIP for Service ${RELEASE}.${NS}" >&2
  exit 1
fi
echo "Product Service ClusterIP: ${SVC_IP}:${SVC_PORT}"

echo "==> Probing product ClusterIP from in-cluster curl pod (proves eBPF datapath)"
RAW=$(kctl -n "${NS}" run ct-cilium-ebpf --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "http://${SVC_IP}:${SVC_PORT}/" 2>/dev/null || echo "000")
HTTP_CODE=$(echo "${RAW}" | grep -oE '[0-9]{3}' | tail -1)

echo "ClusterIP probe HTTP code: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: Product ClusterIP reachable through Cilium eBPF datapath"
else
  echo "FAIL: expected HTTP 200 from product ClusterIP, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: Cilium eBPF kube-proxy replacement verified"
