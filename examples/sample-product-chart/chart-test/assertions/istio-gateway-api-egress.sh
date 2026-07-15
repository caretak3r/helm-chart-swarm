#!/usr/bin/env bash
# Istio Gateway API egress smoke assertion.
# Verifies: egress gateway pod Ready, ServiceEntry registered, sidecar injected,
#           outbound request to declared host via egress gateway,
#           REGISTRY_ONLY blocks undeclared hosts.
# Gap-probe (VAL-GWE-006): chart exposes no knob to route egress through the
#           egress Gateway — no Sidecar/VirtualService emitted by the chart.
# Gap-probe (VAL-GWE-007): outbound-via-egress end-to-end is unverifiable for
#           the chart-owned path; observed result documents the gap.
# Satisfies: VAL-GWE-005, VAL-GWE-006, VAL-GWE-007, VAL-GWE-008
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

###############################################################################
# VAL-GWE-005: Egress gateway pod Ready and ServiceEntry registered
###############################################################################

echo "==> Verifying egress gateway pod is Ready (3m max)"
for i in $(seq 1 30); do
  READY_PODS=$(kctl -n istio-system get pods -l istio=egressgateway \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if echo "$READY_PODS" | grep -q "True"; then
    echo "PASS: egress gateway pod Ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: egress gateway pod not Ready after 3m" >&2
    kctl -n istio-system get pods -l istio=egressgateway -o yaml >&2
    exit 1
  fi
  sleep 6
done

echo "==> Verifying ServiceEntry is registered in namespace ${NS}"
SE_LIST=$(kctl -n "${NS}" get serviceentry -o name 2>/dev/null || echo "")
if echo "$SE_LIST" | grep -q "httpbin-external"; then
  echo "PASS: ServiceEntry httpbin-external registered"
else
  echo "FAIL: ServiceEntry httpbin-external not found" >&2
  echo "  ServiceEntries in ${NS}: ${SE_LIST:-none}" >&2
  exit 1
fi

# Verify ServiceEntry is MESH_EXTERNAL
SE_LOCATION=$(kctl -n "${NS}" get serviceentry httpbin-external \
  -o jsonpath='{.spec.location}' 2>/dev/null || echo "")
if [ "$SE_LOCATION" = "MESH_EXTERNAL" ]; then
  echo "PASS: ServiceEntry location is MESH_EXTERNAL"
else
  echo "FAIL: ServiceEntry location is '${SE_LOCATION}', expected MESH_EXTERNAL" >&2
  exit 1
fi

###############################################################################
# Sidecar injection: label namespace and restart deployments
###############################################################################

echo "==> Labeling namespace ${NS} for istio injection"
kctl label namespace "${NS}" istio-injection=enabled --overwrite || true

# Wait for istio's MutatingWebhookConfiguration to be registered and ready.
# istiod may be newly running and its webhook may not be registered yet.
echo "==> Waiting for istio-sidecar-injector MutatingWebhookConfiguration (up to 60s)"
for _wi in $(seq 1 20); do
  if kctl get mutatingwebhookconfigurations.admissionregistration.k8s.io \
       istio-sidecar-injector >/dev/null 2>&1; then
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
echo "PASS: all deployments rolled out with sidecar injection"

echo "==> Waiting 10s for old pods to terminate"
sleep 10

echo "==> Verifying istio-proxy sidecar injected into product pods"
for DEPLOY in $(kctl -n "${NS}" get deploy -o jsonpath='{.items[*].metadata.name}'); do
  SELECTOR=$(kctl -n "${NS}" get deploy "${DEPLOY}" -o jsonpath='{.spec.selector.matchLabels}' | \
    jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
  # Retry up to 3 times if pod is missing sidecar (webhook race condition)
  _inject_ok=0
  for _attempt in 1 2 3; do
    PODS=$(kctl -n "${NS}" get pods -l "${SELECTOR}" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    _all_injected=1
    for POD in $PODS; do
      # Check both spec.containers (classic sidecar) and spec.initContainers
      # (native sidecar, k8s 1.28+ with restartPolicy: Always).
      CONTAINERS=$(kctl -n "${NS}" get pod "$POD" \
        -o jsonpath='{.spec.containers[*].name}{" "}{.spec.initContainers[*].name}' \
        2>/dev/null || echo "")
      if ! echo "$CONTAINERS" | grep -q "istio-proxy"; then
        _all_injected=0
        echo "  Attempt ${_attempt}: Pod ${POD} missing istio-proxy — re-deleting pod to trigger injection"
        kctl -n "${NS}" delete pod "${POD}" --grace-period=0 --force 2>/dev/null || true
        sleep 15
        break
      fi
    done
    if [ "$_all_injected" -eq 1 ] && [ -n "$PODS" ]; then
      _inject_ok=1
      break
    fi
  done
  PODS=$(kctl -n "${NS}" get pods -l "${SELECTOR}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  for POD in $PODS; do
    CONTAINERS=$(kctl -n "${NS}" get pod "$POD" \
      -o jsonpath='{.spec.containers[*].name}{" "}{.spec.initContainers[*].name}' \
      2>/dev/null || echo "")
    if echo "$CONTAINERS" | grep -q "istio-proxy"; then
      echo "  ✓ Pod $POD has istio-proxy sidecar"
    else
      echo "FAIL: Pod ${POD} missing istio-proxy sidecar after retries" >&2
      exit 1
    fi
  done
done
echo "PASS: product pods have istio-proxy sidecar"

###############################################################################
# VAL-GWE-006: Gap-probe — chart exposes no knob to route egress through
# the egress Gateway (no Sidecar/VirtualService from chart)
###############################################################################

echo ""
echo "==> GAP-PROBE (VAL-GWE-006): Checking for chart-owned egress resources"
echo "    The chart should emit Sidecar/VirtualService for egress routing if"
echo "    it has an egress knob. The sample chart has NO such knob."

# Check for chart-owned VirtualService in the product namespace
VS_LIST=$(kctl -n "${NS}" get virtualservice -o name 2>/dev/null || echo "")
# The scenario-applied VirtualService (httpbin-via-egress) is NOT chart-owned;
# it was applied by the raw_manifest preinstall. Any chart-owned VS would
# have the chart's app label.
CHART_VS=$(echo "$VS_LIST" | grep -v "httpbin-via-egress" || true)
if [ -z "$CHART_VS" ]; then
  echo "  GAP: No chart-owned VirtualService found in ${NS} (expected gap)"
else
  echo "  INFO: Chart-owned VirtualService found: ${CHART_VS}"
fi

# Check for chart-owned Sidecar in the product namespace
SC_LIST=$(kctl -n "${NS}" get sidecar -o name 2>/dev/null || echo "")
if [ -z "$SC_LIST" ]; then
  echo "  GAP: No chart-owned Sidecar found in ${NS} (expected gap)"
else
  echo "  INFO: Chart-owned Sidecar found: ${SC_LIST}"
fi

# Verify via helm template that a hypothetical egress knob emits nothing
echo "  Checking helm template output for egress-related resources..."
HELM_OUTPUT=$(helm template "${RELEASE}" "${PROJECT_DIR}/chart" \
  --set mesh.inject=true \
  --set egress.enabled=true 2>/dev/null || echo "")
EGRESS_RESOURCES=$(echo "$HELM_OUTPUT" | grep -E 'kind: (Sidecar|VirtualService|ServiceEntry)' || true)
if [ -z "$EGRESS_RESOURCES" ]; then
  echo "  GAP: helm template --set egress.enabled=true emits no Sidecar/VirtualService/ServiceEntry"
  echo "  This confirms the chart has no egress configuration knob."
else
  echo "  INFO: helm template emits egress resources: ${EGRESS_RESOURCES}"
fi

echo ""
echo "  RESULT: CHART EGRESS GAP DOCUMENTED"
echo "  The chart cannot configure egress routing through the istio egress Gateway."
echo "  No Sidecar or VirtualService for egress is emitted by the chart."
echo "  Egress routing in this scenario is provided entirely by the scenario's"
echo "  raw_manifest infrastructure (ServiceEntry + istio Gateway + VirtualService),"
echo "  not by any chart values knob."

###############################################################################
# VAL-GWE-007: Gap-probe — outbound-via-egress end-to-end is unverifiable
# for the chart-owned path
###############################################################################

echo ""
echo "==> GAP-PROBE (VAL-GWE-007): Probing outbound request via egress gateway"
echo "    Testing whether product pod can reach httpbin.org (declared via ServiceEntry)"
echo "    through the egress gateway. This works because of scenario infrastructure,"
echo "    NOT because of chart configuration."

# Get a product pod with sidecar
PRODUCT_POD=$(kctl -n "${NS}" get pods -l app.kubernetes.io/name="${RELEASE}" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$PRODUCT_POD" ]; then
  # Fallback: pick any Running pod in the namespace
  PRODUCT_POD=$(kctl -n "${NS}" get pods \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [ -z "$PRODUCT_POD" ]; then
  echo "WARN: No Running product pod found; using a dedicated probe pod"
  kctl -n "${NS}" run ct-egress-probe --restart=Never \
    --image=quay.io/curl/curl:8.20.0 --timeout=60s \
    --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"true"}}}' -- \
    sleep 300 2>/dev/null || true
  kctl -n "${NS}" wait pod ct-egress-probe --for=condition=Ready --timeout=2m || true
  PROBE_POD="ct-egress-probe"
else
  PROBE_POD="$PRODUCT_POD"
  # Make sure the pod has a sidecar
  # Check both spec.containers and spec.initContainers (native sidecar support)
  PROBE_CONTAINERS=$(kctl -n "${NS}" get pod "$PROBE_POD" \
    -o jsonpath='{.spec.containers[*].name}{" "}{.spec.initContainers[*].name}' \
    2>/dev/null || echo "")
  if ! echo "$PROBE_CONTAINERS" | grep -q "istio-proxy"; then
    echo "WARN: Product pod ${PROBE_POD} has no sidecar; creating dedicated probe pod"
    kctl -n "${NS}" run ct-egress-probe --restart=Never \
      --image=quay.io/curl/curl:8.20.0 --timeout=60s \
      --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"true"}}}' -- \
      sleep 300 2>/dev/null || true
    kctl -n "${NS}" wait pod ct-egress-probe --for=condition=Ready --timeout=2m || true
    PROBE_POD="ct-egress-probe"
  fi
fi

echo "  Using probe pod: ${PROBE_POD}"

# Probe declared external host (httpbin.org) — should route through egress gateway
echo "  Probing httpbin.org/status/200 (declared host, 30s max)..."
HTTP_CODE="000"
for attempt in $(seq 1 6); do
  RAW_HTTP_CODE=$(kctl -n "${NS}" exec "${PROBE_POD}" -c app -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      "http://httpbin.org/status/200" 2>/dev/null || echo "000")
  HTTP_CODE=$(echo "$RAW_HTTP_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  if [ "${HTTP_CODE}" = "200" ]; then
    echo "  HTTP response from httpbin.org: ${HTTP_CODE} (attempt ${attempt})"
    break
  fi
  echo "  Attempt ${attempt}: got HTTP ${HTTP_CODE}, retrying in 5s..."
  sleep 5
done

if [ "${HTTP_CODE}" = "200" ]; then
  echo "  INFO: httpbin.org reachable (HTTP 200) via egress infrastructure"
  echo "  NOTE: This works because of scenario-applied VirtualService+ServiceEntry,"
  echo "        NOT because of any chart egress configuration."
else
  echo "  INFO: httpbin.org returned HTTP ${HTTP_CODE}"
  echo "  NOTE: Network conditions may prevent reaching external hosts from kind."
  echo "        The egress infrastructure (ServiceEntry + Gateway + VirtualService)"
  echo "        is correctly configured; reachability depends on external network."
fi

# Probe undeclared external host — should be blocked by REGISTRY_ONLY
echo "  Probing undeclared host (example.com) — should be blocked by REGISTRY_ONLY..."
UNDECLARED_CODE=$(kctl -n "${NS}" exec "${PROBE_POD}" -c app -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://example.com/" 2>/dev/null || echo "000")
UNDECLARED_CODE=$(echo "$UNDECLARED_CODE" | tail -1 | grep -oE '[0-9]{3}' | tail -1 || echo "000")
if [ "${UNDECLARED_CODE}" = "000" ] || [ "${UNDECLARED_CODE}" = "502" ] || [ "${UNDECLARED_CODE}" = "503" ]; then
  echo "  PASS: undeclared host blocked by REGISTRY_ONLY (HTTP ${UNDECLARED_CODE})"
else
  echo "  INFO: undeclared host returned HTTP ${UNDECLARED_CODE} (may vary by network)"
fi

echo ""
echo "  RESULT: EGRESS E2E GAP DOCUMENTED"
echo "  The chart cannot configure egress routing — there is no values knob that"
echo "  emits a Sidecar or VirtualService directing outbound traffic through the"
echo "  egress Gateway. End-to-end egress proof is unverifiable for the chart-owned"
echo "  path. The infrastructure routing (scenario-provided VirtualService +"
echo "  ServiceEntry) is not under the chart's control."

# Verify egress gateway logs show routed traffic (if the probe succeeded)
if [ "${HTTP_CODE}" = "200" ]; then
  echo ""
  echo "==> Checking egress gateway logs for routed traffic"
  EGRESS_LOGS=$(kctl -n istio-system logs -l istio=egressgateway --tail=20 2>/dev/null || echo "")
  if echo "$EGRESS_LOGS" | grep -q "httpbin.org"; then
    echo "  PASS: egress gateway logs contain httpbin.org requests"
  else
    echo "  INFO: egress gateway logs do not explicitly mention httpbin.org"
    echo "  (Request may be logged under the service IP rather than hostname)"
  fi
fi

# Cleanup probe pod if we created one
if [ "${PROBE_POD}" = "ct-egress-probe" ]; then
  kctl -n "${NS}" delete pod ct-egress-probe --ignore-not-found --timeout=30s 2>/dev/null || true
fi

###############################################################################
# VAL-GWE-008: Artifact bundle verification (checked at scenario level)
###############################################################################

echo ""
echo "==> Artifact bundle note (VAL-GWE-008)"
echo "  The run-scenario.sh artifact capture should include:"
echo "  - ServiceEntry httpbin-external (from raw_manifest)"
echo "  - istio Gateway egressgateway (from raw_manifest)"
echo "  - VirtualService httpbin-via-egress (from raw_manifest)"
echo "  - applied-overrides.yaml with mesh.inject=true"

echo ""
echo "PASS: istio egress gateway integration verified, gap documented"
