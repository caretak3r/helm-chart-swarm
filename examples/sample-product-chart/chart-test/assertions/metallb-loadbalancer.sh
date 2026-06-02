#!/usr/bin/env bash
# MetalLB LoadBalancer smoke assertion.
# Verifies: MetalLB controller+speaker pods Running, IPAddressPool and
#           L2Advertisement present, Service has type=LoadBalancer,
#           MetalLB assigns external IP from pool, in-cluster curl to
#           LB IP returns HTTP 200.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
METALLB_NS="metallb"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Detecting kind Docker bridge subnet for IP pool"
# The kind Docker network is typically 172.18.0.0/16 but can vary.
# We need the IP pool to be within this subnet for routability.
KIND_SUBNET=""
if docker network inspect kind >/dev/null 2>&1; then
  KIND_SUBNET=$(docker network inspect kind 2>/dev/null \
    | jq -r '.[0].IPAM.Config[] | select(.Subnet | test("^[0-9]+\\.")) | .Subnet' 2>/dev/null | head -1)
fi

if [ -z "${KIND_SUBNET}" ]; then
  echo "WARN: Could not detect kind bridge subnet; using default 172.18.0.0/16"
  KIND_SUBNET="172.18.0.0/16"
fi
echo "Kind bridge subnet: ${KIND_SUBNET}"

# Extract the /16 prefix (e.g. 172.18 from 172.18.0.0/16)
SUBNET_PREFIX=$(echo "${KIND_SUBNET}" | sed 's|^\([0-9]*\.[0-9]*\)\..*/.*$|\1|')
echo "Subnet prefix: ${SUBNET_PREFIX}"

# Determine if the fixture's default IP range matches the actual subnet
DEFAULT_PREFIX="172.18"
POOL_RANGE="${SUBNET_PREFIX}.255.200-${SUBNET_PREFIX}.255.250"

if [ "${SUBNET_PREFIX}" != "${DEFAULT_PREFIX}" ]; then
  echo "==> Patching IPAddressPool to match actual kind subnet"
  kctl apply -f - <<EOF
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: chart-test-pool
  namespace: ${METALLB_NS}
spec:
  addresses:
    - "${POOL_RANGE}"
  autoAssign: true
EOF
  echo "Patched IPAddressPool with range: ${POOL_RANGE}"
else
  echo "Default IP range matches kind subnet (172.18.x.x)"
fi

echo "==> Waiting for MetalLB controller pod Ready (5m max)"
kctl -n "${METALLB_NS}" wait pod -l app.kubernetes.io/component=controller,app.kubernetes.io/instance=metallb --for=condition=Ready --timeout=5m
echo "PASS: MetalLB controller pod Ready"

echo "==> Waiting for MetalLB speaker pods Ready (5m max)"
kctl -n "${METALLB_NS}" wait pod -l app.kubernetes.io/component=speaker,app.kubernetes.io/instance=metallb --for=condition=Ready --timeout=5m
echo "PASS: MetalLB speaker pods Ready"

echo "==> Verifying IPAddressPool exists"
IP_POOL=$(kctl -n "${METALLB_NS}" get ipaddresspool chart-test-pool -o name 2>/dev/null || echo "")
if [ -n "${IP_POOL}" ]; then
  echo "PASS: IPAddressPool chart-test-pool found"
else
  echo "FAIL: IPAddressPool chart-test-pool not found" >&2
  exit 1
fi

echo "==> Verifying L2Advertisement exists"
L2ADV=$(kctl -n "${METALLB_NS}" get l2advertisement chart-test-l2 -o name 2>/dev/null || echo "")
if [ -n "${L2ADV}" ]; then
  echo "PASS: L2Advertisement chart-test-l2 found"
else
  echo "FAIL: L2Advertisement chart-test-l2 not found" >&2
  exit 1
fi

echo "==> Waiting for product pod Ready (5m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=5m
echo "PASS: product pods Ready"

echo "==> Verifying Service has spec.type=LoadBalancer"
SVC_TYPE=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
if [ "${SVC_TYPE}" = "LoadBalancer" ]; then
  echo "PASS: Service type=LoadBalancer"
else
  echo "FAIL: Expected Service type=LoadBalancer, got '${SVC_TYPE}'" >&2
  exit 1
fi

echo "==> Waiting for MetalLB to assign external IP (60s max)"
LB_IP=""
for i in $(seq 1 30); do
  LB_IP=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [ -n "${LB_IP}" ]; then
    echo "MetalLB assigned external IP: ${LB_IP}"
    break
  fi
  echo "  Waiting for external IP... ($i/30)"
  sleep 2
done

if [ -z "${LB_IP}" ]; then
  echo "FAIL: MetalLB did not assign an external IP within 60s" >&2
  echo "Service status:" >&2
  kctl -n "${NS}" get svc "${RELEASE}" -o yaml >&2 || true
  exit 1
fi
echo "PASS: MetalLB assigned external IP ${LB_IP}"

echo "==> Verifying assigned IP is within the configured pool"
if [[ "${LB_IP}" == "${SUBNET_PREFIX}.255."* ]]; then
  echo "PASS: Assigned IP ${LB_IP} is within pool range ${POOL_RANGE}"
else
  echo "WARN: Assigned IP ${LB_IP} may not be in expected pool range ${POOL_RANGE} (could still be routable)"
fi

echo "==> Probing LB endpoint via in-cluster curl (expect 200)"
# Use a temporary curl pod in the product namespace
HTTP_CODE=$(kctl -n "${NS}" run ct-metallb-lb --rm -i --restart=Never --quiet \
  --image=quay.io/curl/curl:8.6.0 --timeout=30s -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "http://${LB_IP}:80/" 2>/dev/null || echo "000")

echo "HTTP response from LB IP: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTP 200 from LB endpoint ${LB_IP}"
else
  echo "FAIL: expected HTTP 200 from LB endpoint, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: MetalLB LoadBalancer integration verified end-to-end"
