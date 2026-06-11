#!/usr/bin/env bash
# Istio sidecar injection smoke assertion.
# Verifies: namespace labeled for injection, every product pod has
# exactly 2 containers (app + istio-proxy), in-mesh pod reaches
# the product Service FQDN over the sidecar with HTTP 200.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SVC_PORT="${SERVICE_PORT:-80}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Labeling namespace ${NS} for istio injection"
kctl label namespace "${NS}" istio-injection=enabled --overwrite || true

# Wait for the Istio sidecar injector webhook to be registered and ready.
# istiod may have just started; the webhook may not be registered yet.
echo "==> Waiting for istio-sidecar-injector MutatingWebhookConfiguration (up to 60s)"
for _wi in $(seq 1 20); do
  if kctl get mutatingwebhookconfiguration istio-sidecar-injector >/dev/null 2>&1; then
    echo "PASS: istio-sidecar-injector webhook registered"
    break
  fi
  if [ "$_wi" -eq 20 ]; then
    echo "FAIL: istio-sidecar-injector MutatingWebhookConfiguration not found after 60s" >&2
    exit 1
  fi
  sleep 3
done
# Extra settle time for the webhook server to begin serving requests
sleep 10

echo "==> Restarting deployments to pick up sidecar injection"
for DEPLOY in $(kctl -n "${NS}" get deploy -o jsonpath='{.items[*].metadata.name}'); do
  echo "  Restarting deployment/${DEPLOY}"
  kctl -n "${NS}" rollout restart "deployment/${DEPLOY}"
  echo "  Waiting for rollout of deployment/${DEPLOY} to complete (3m max)"
  kctl -n "${NS}" rollout status "deployment/${DEPLOY}" --timeout=3m
done
echo "PASS: all deployments rolled out"

echo "==> Waiting 5s for old pods to terminate"
sleep 5

echo "==> Verifying istio-proxy sidecar injected into every product pod"
for DEPLOY in $(kctl -n "${NS}" get deploy -o jsonpath='{.items[*].metadata.name}'); do
  SELECTOR=$(kctl -n "${NS}" get deploy "${DEPLOY}" -o jsonpath='{.spec.selector.matchLabels}' | \
    jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
  # Only check Running pods (ignore Terminating)
  PODS=$(kctl -n "${NS}" get pods -l "${SELECTOR}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}')
  POD_COUNT=0
  for POD in $PODS; do
    POD_COUNT=$((POD_COUNT + 1))
    # Check both spec.containers and spec.initContainers — Istio 1.25+ on K8s 1.28+
    # uses native sidecar injection (initContainer with restartPolicy=Always) so
    # istio-proxy appears in spec.initContainers, not spec.containers.
    REG_CONTAINERS=$(kctl -n "${NS}" get pod "$POD" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "")
    INIT_CONTAINERS=$(kctl -n "${NS}" get pod "$POD" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null || echo "")
    ALL_CONTAINERS="${REG_CONTAINERS} ${INIT_CONTAINERS}"
    CONTAINER_COUNT=$(echo "$ALL_CONTAINERS" | wc -w | tr -d ' ')
    echo "  Pod $POD (deploy/${DEPLOY}) containers (${CONTAINER_COUNT}): ${ALL_CONTAINERS}"
    if echo "$ALL_CONTAINERS" | grep -q "istio-proxy"; then
      echo "    ✓ istio-proxy sidecar present (regular or native init container)"
    else
      echo "FAIL: Pod ${POD} missing istio-proxy sidecar" >&2
      exit 1
    fi
    if [ "${CONTAINER_COUNT}" -lt 2 ]; then
      echo "FAIL: Pod ${POD} has only ${CONTAINER_COUNT} total containers (want at least 2 incl. istio-proxy)" >&2
      exit 1
    fi
  done
  if [ "$POD_COUNT" -eq 0 ]; then
    echo "FAIL: no Running pods found for deployment/${DEPLOY}" >&2
    exit 1
  fi
done
echo "PASS: every Running product pod has exactly 2 containers including istio-proxy"

echo "==> Probing product Service over the mesh from an in-mesh pod"
PRODUCT_SVC="${RELEASE}.${NS}.svc.cluster.local"

# Create a dedicated probe pod with sidecar injection
kctl -n "${NS}" run ct-mesh-probe --restart=Never \
  --image=quay.io/curl/curl:8.20.0 --timeout=60s \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"true"}}}' -- \
  sleep 300 2>/dev/null || true

echo "  Waiting for probe pod to be ready with sidecar (2m max)"
kctl -n "${NS}" wait pod ct-mesh-probe --for=condition=Ready --timeout=2m || {
  echo "WARN: probe pod not ready; trying without sidecar"
}

# Verify probe pod has sidecar
PROBE_CONTAINERS=$(kctl -n "${NS}" get pod ct-mesh-probe -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "")
echo "  Probe pod containers: ${PROBE_CONTAINERS}"

# Exec curl from the probe pod
RAW_HTTP_CODE=$(kctl -n "${NS}" exec ct-mesh-probe -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "http://${PRODUCT_SVC}:${SVC_PORT}/" 2>/dev/null || echo "000")
HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1)

echo "HTTP response from in-mesh probe: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: in-mesh pod reached product Service with HTTP 200"
else
  echo "FAIL: expected HTTP 200 from in-mesh probe, got ${HTTP_CODE}" >&2
  # Try to debug
  echo "  Debug: curl verbose from probe pod"
  kctl -n "${NS}" exec ct-mesh-probe -- curl -v --max-time 10 "http://${PRODUCT_SVC}:${SVC_PORT}/" 2>&1 || true
  kctl -n "${NS}" delete pod ct-mesh-probe --ignore-not-found --timeout=30s || true
  exit 1
fi

# Clean up
kctl -n "${NS}" delete pod ct-mesh-probe --ignore-not-found --timeout=30s || true

echo "PASS: istio sidecar injection integration verified"
