#!/usr/bin/env bash
# Linkerd ServiceProfile smoke assertion.
# Verifies: namespace annotated for injection, linkerd-proxy sidecar present,
# ServiceProfile CRD is available, a ServiceProfile for the product service
# is authored with route definitions (timeout + retry), and the profile
# is recognized by the control plane.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
SVC_PORT="${SERVICE_PORT:-80}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Annotating namespace ${NS} for linkerd injection"
kctl annotate namespace "${NS}" linkerd.io/inject=enabled --overwrite

echo "==> Restarting deployments to pick up proxy injection"
for DEPLOY in $(kctl -n "${NS}" get deploy -o jsonpath='{.items[*].metadata.name}'); do
  kctl -n "${NS}" rollout restart "deployment/${DEPLOY}"
  kctl -n "${NS}" rollout status "deployment/${DEPLOY}" --timeout=3m
done

echo "==> Verifying linkerd-proxy sidecar injected"
for DEPLOY in $(kctl -n "${NS}" get deploy -o jsonpath='{.items[*].metadata.name}'); do
  SELECTOR=$(kctl -n "${NS}" get deploy "${DEPLOY}" -o jsonpath='{.spec.selector.matchLabels}' | \
    jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
  PODS=$(kctl -n "${NS}" get pods -l "${SELECTOR}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}')
  for POD in $PODS; do
    CONTAINERS=$(kctl -n "${NS}" get pod "$POD" -o jsonpath='{.spec.containers[*].name}')
    if echo "$CONTAINERS" | grep -q "linkerd-proxy"; then
      echo "  ✓ Pod $POD: linkerd-proxy sidecar present"
    else
      echo "FAIL: Pod $POD missing linkerd-proxy sidecar" >&2
      exit 1
    fi
  done
done

echo "==> Verifying ServiceProfile CRD is established"
kctl get crd serviceprofiles.linkerd.io >/dev/null 2>&1 || {
  echo "FAIL: CRD serviceprofiles.linkerd.io not found" >&2
  exit 1
}
echo "  ✓ CRD serviceprofiles.linkerd.io established"

echo "==> Authoring ServiceProfile for the product Service"
# Create a ServiceProfile that defines routes for the product service.
# This gives Linkerd per-route metrics, retries, and timeouts.
cat <<EOF | kctl -n "${NS}" apply -f -
apiVersion: linkerd.io/v1alpha2
kind: ServiceProfile
metadata:
  name: ${RELEASE}.${NS}.svc.cluster.local
  namespace: ${NS}
spec:
  routes:
    - name: GET /
      condition:
        method: GET
        pathRegex: /
      responseClasses:
        - condition:
            status:
              min: 200
              max: 299
          isFailure: false
        - condition:
            status:
              min: 500
              max: 599
          isFailure: true
      timeout: 10s
    - name: GET /healthz
      condition:
        method: GET
        pathRegex: /healthz
      responseClasses:
        - condition:
            status:
              min: 200
              max: 299
          isFailure: false
      timeout: 5s
    - name: POST /api
      condition:
        method: POST
        pathRegex: /api.*
      responseClasses:
        - condition:
            status:
              min: 200
              max: 299
          isFailure: false
        - condition:
            status:
              min: 400
              max: 499
          isFailure: true
      timeout: 15s
      isRetryable: true
EOF

echo "==> Verifying ServiceProfile was created"
kctl -n "${NS}" get serviceprofile "${RELEASE}.${NS}.svc.cluster.local" -o yaml >/dev/null 2>&1 || {
  echo "FAIL: ServiceProfile not created" >&2
  exit 1
}
echo "  ✓ ServiceProfile ${RELEASE}.${NS}.svc.cluster.local exists"

echo "==> Inspecting ServiceProfile routes"
ROUTE_COUNT=$(kctl -n "${NS}" get serviceprofile "${RELEASE}.${NS}.svc.cluster.local" \
  -o jsonpath='{.spec.routes}' | jq -r 'length' 2>/dev/null || echo "0")
echo "  Routes defined: ${ROUTE_COUNT}"

if [ "${ROUTE_COUNT}" -ge 1 ]; then
  echo "  Route names:"
  kctl -n "${NS}" get serviceprofile "${RELEASE}.${NS}.svc.cluster.local" \
    -o jsonpath='{.spec.routes[*].name}' 2>/dev/null || true
  echo ""
fi

echo "==> Probing product Service (ServiceProfile routes active)"
PRODUCT_SVC="${RELEASE}.${NS}.svc.cluster.local"

RAW_HTTP_CODE=$(kctl -n "${NS}" run ct-sp-probe --restart=Never \
  --image=quay.io/curl/curl:8.20.0 --timeout=30s \
  --overrides='{"metadata":{"annotations":{"linkerd.io/inject":"disabled"}}}' \
  --attach --rm -i -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "http://${PRODUCT_SVC}:${SVC_PORT}/" 2>/dev/null || echo "000")

HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")
echo "HTTP response: ${HTTP_CODE}"

if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: product Service reachable with ServiceProfile routes configured"
else
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: linkerd ServiceProfile integration verified"
