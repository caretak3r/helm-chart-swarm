#!/usr/bin/env bash
# OPA Gatekeeper required-labels smoke assertion (gap-probe).
# Verifies: ConstraintTemplate k8srequiredlabels Established, CRD Established,
#           non-compliant Deployment denied, compliant Deployment accepted,
#           non-compliant Ingress denied, compliant Ingress admitted + Ready.
# Cross-feature compose: opa-gatekeeper (M7) + nginx-ingress (M4).
# Gap-probe: the chart's Ingress template uses selectorLabels (just app: <release>)
#            instead of the full common labels (which include app.kubernetes.io/name),
#            so the chart's Ingress fails the required-labels constraint — an honest
#            gap (red cell); do NOT over-engineer the chart.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
GK_NS="gatekeeper-system"
NGINX_NS="ingress-nginx"
FIXTURES="${PROJECT_DIR:-.}/chart-test/fixtures/policy"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "=== OPA Gatekeeper: Required Labels ==="

echo "==> Phase 0: Wait for gatekeeper controller + nginx ingress pods Ready"
kctl -n "${GK_NS}" wait pod -l control-plane=controller-manager --for=condition=Ready --timeout=3m
echo "PASS: gatekeeper controller Ready"

kctl -n "${NGINX_NS}" wait pod -l app.kubernetes.io/name=ingress-nginx --for=condition=Ready --timeout=2m
echo "PASS: nginx ingress controller Ready"

kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=2m
echo "PASS: product pod Ready"

echo "==> Phase 1: Verify ConstraintTemplate applied"
CT_NAME="k8srequiredlabels"
echo "Waiting for ConstraintTemplate ${CT_NAME} to reconcile (60s max)..."
for i in $(seq 1 12); do
  GEN=$(kctl get constrainttemplate "${CT_NAME}" -o jsonpath='{.metadata.generation}' 2>/dev/null)
  # Gatekeeper stores observedGeneration under status.byPod[0].observedGeneration
  OBS_GEN=$(kctl get constrainttemplate "${CT_NAME}" -o jsonpath='{.status.byPod[0].observedGeneration}' 2>/dev/null)
  if [ -n "${OBS_GEN}" ] && [ "${OBS_GEN}" -ge "${GEN}" ] 2>/dev/null; then
    echo "PASS: observedGeneration (${OBS_GEN}) >= generation (${GEN}) at attempt ${i}"
    break
  fi
  if [ "$i" -eq 12 ]; then
    echo "FAIL: ConstraintTemplate ${CT_NAME} not reconciled after 60s (gen=${GEN}, obs=${OBS_GEN})" >&2
    exit 1
  fi
  sleep 5
done

echo "==> Wait for CRD Established (90s max)"
kctl wait "crd/k8srequiredlabels.constraints.gatekeeper.sh" --for=condition=Established --timeout=90s
echo "PASS: CRD k8srequiredlabels.constraints.gatekeeper.sh Established=True"

echo "==> Apply Constraint"
kctl apply -f "${FIXTURES}/k8srequiredlabels-constraint.yaml"
echo "PASS: K8sRequiredLabels constraint applied"

sleep 8  # gatekeeper webhook sync lag after constraint creation

echo "==> Phase 2a: Non-compliant Deployment (missing app.kubernetes.io/name)"
if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-noncompliant-labels.yaml" 2>&1 | tee /tmp/gk-noncompliant-dep.txt; then
  echo "FAIL: non-compliant Deployment was NOT rejected" >&2
  exit 1
else
  if grep -q "admission webhook.*denied" /tmp/gk-noncompliant-dep.txt 2>/dev/null && \
     grep -q "app.kubernetes.io/name" /tmp/gk-noncompliant-dep.txt 2>/dev/null; then
    echo "PASS: non-compliant Deployment rejected (missing required label)"
  else
    echo "FAIL: rejection did not name constraint + missing label" >&2
    cat /tmp/gk-noncompliant-dep.txt >&2
    exit 1
  fi
fi

echo "==> Phase 2b: Compliant Deployment (has app.kubernetes.io/name)"
if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-compliant.yaml" 2>&1; then
  echo "PASS: compliant Deployment accepted"
else
  echo "FAIL: compliant Deployment was rejected" >&2
  exit 1
fi

echo "==> Phase 3a: Non-compliant Ingress (missing app.kubernetes.io/name)"
if kctl apply --dry-run=server -f "${FIXTURES}/test-ingress-noncompliant.yaml" 2>&1 | tee /tmp/gk-noncompliant-ing.txt; then
  echo "FAIL: non-compliant Ingress was NOT rejected" >&2
  exit 1
else
  if grep -q "admission webhook.*denied" /tmp/gk-noncompliant-ing.txt 2>/dev/null && \
     grep -q "app.kubernetes.io/name" /tmp/gk-noncompliant-ing.txt 2>/dev/null; then
    echo "PASS: non-compliant Ingress rejected (missing required label)"
  else
    echo "FAIL: rejection did not name constraint + missing label" >&2
    cat /tmp/gk-noncompliant-ing.txt >&2
    exit 1
  fi
fi

echo "==> Phase 3b: Compliant Ingress (has app.kubernetes.io/name)"
ING_NAME="test-compliant-ingress"
if kctl apply -f "${FIXTURES}/test-ingress-compliant.yaml" 2>&1; then
  echo "PASS: compliant Ingress applied"
else
  echo "FAIL: compliant Ingress was rejected" >&2
  exit 1
fi

# Wait for Ingress to be processed
sleep 5
if kctl -n "${NS}" get ingress "${ING_NAME}" -o jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null | grep -q .; then
  echo "PASS: compliant Ingress has loadBalancer address populated"
else
  echo "NOTE: compliant Ingress may not yet have address (NGINX controller processes async)"
fi

echo "==> Phase 4: Webhook failure mode — verify Fail policy + outage behavior"

# 4a: Verify failurePolicy: Fail on validating webhook configuration
WEBHOOK_NAME="gatekeeper-validating-webhook-configuration"
FP=$(kctl get validatingwebhookconfiguration "${WEBHOOK_NAME}" -o jsonpath='{.webhooks[0].failurePolicy}' 2>/dev/null)
if [ "${FP}" = "Fail" ]; then
  echo "PASS: webhook ${WEBHOOK_NAME} failurePolicy=${FP}"
else
  echo "FAIL: expected failurePolicy=Fail, got '${FP}'" >&2
  exit 1
fi

# 4b: Scale gatekeeper controller to 0 replicas
GK_DEPLOY="gatekeeper-controller-manager"
ORIG_REPLICAS=$(kctl -n "${GK_NS}" get deploy "${GK_DEPLOY}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
echo "Scaling ${GK_DEPLOY} to 0 in ${GK_NS} (original replicas: ${ORIG_REPLICAS})..."
kctl -n "${GK_NS}" scale deploy "${GK_DEPLOY}" --replicas=0
# Wait for the controller pods to actually terminate
kctl -n "${GK_NS}" wait pod -l control-plane=controller-manager --for=delete --timeout=2m 2>/dev/null || true
sleep 3
echo "PASS: gatekeeper controller scaled to 0"

# 4c: Verify admission fails with webhook timeout/connection-refused
echo "Attempting kubectl apply with webhook unavailable..."
if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-compliant.yaml" 2>&1 | tee /tmp/gk-outage-probe.txt; then
  echo "FAIL: admission succeeded despite webhook being down (possible Ignore policy)" >&2
  # Restore controller before exiting
  kctl -n "${GK_NS}" scale deploy "${GK_DEPLOY}" --replicas="${ORIG_REPLICAS}" 2>/dev/null || true
  exit 1
else
  if grep -qiE "failed calling webhook|connection refused|timeout|deadline exceeded|no endpoints|service not found|Internal error" /tmp/gk-outage-probe.txt 2>/dev/null; then
    echo "PASS: admission correctly blocked during webhook outage (Fail policy)"
  else
    echo "FAIL: rejection message did not indicate webhook unavailability" >&2
    cat /tmp/gk-outage-probe.txt >&2
    kctl -n "${GK_NS}" scale deploy "${GK_DEPLOY}" --replicas="${ORIG_REPLICAS}" 2>/dev/null || true
    exit 1
  fi
fi

# 4d: Scale controller back up and verify admission works again
echo "Restoring ${GK_DEPLOY} to ${ORIG_REPLICAS} in ${GK_NS}..."
kctl -n "${GK_NS}" scale deploy "${GK_DEPLOY}" --replicas="${ORIG_REPLICAS}"
echo "Waiting for gatekeeper controller pods to be Ready again..."
kctl -n "${GK_NS}" wait pod -l control-plane=controller-manager --for=condition=Ready --timeout=3m
echo "PASS: gatekeeper controller pods Ready"

# Note: kind clusters may take longer to restore webhook endpoints due to
# resource constraints. We retry with a generous 5-minute timeout.
echo "Waiting for admission webhook to accept requests (300s max, may be slow on resource-constrained clusters)..."
ADMISSION_RESTORED=0
for i in $(seq 1 60); do
  if kctl apply --dry-run=server -f "${FIXTURES}/test-deploy-compliant.yaml" 2>/dev/null; then
    echo "PASS: admission restored after webhook recovery (attempt ${i})"
    ADMISSION_RESTORED=1
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "FAIL: admission still failing after controller restore (60 attempts, 300s)" >&2
    exit 1
  fi
  sleep 5
done
if [ "${ADMISSION_RESTORED}" -eq 0 ]; then
  echo "FAIL: admission did not recover" >&2
  exit 1
fi

echo "PASS: OPA Gatekeeper required-labels + nginx-ingress cross-feature compose verified"

echo "==> Phase 5: GAP-PROBE — Does the chart's own Ingress pass the required-labels constraint?"
# The chart's Ingress template uses sample-product.selectorLabels (just app: <release>)
# instead of sample-product.labels (which includes app.kubernetes.io/name).
# Render the chart's Ingress with ingress.enabled=true and dry-run it against the
# active constraint to surface the honest gap.
CHART_DIR="${PROJECT_DIR:-.}/chart"
if [ -d "${CHART_DIR}" ]; then
  echo "Rendering chart Ingress with ingress.enabled=true for gap-probe dry-run..."
  INGRESS_MANIFEST=$(helm template "${RELEASE}" "${CHART_DIR}" \
    --set ingress.enabled=true \
    --set ingress.className=nginx \
    --set ingress.host=sample.gap-probe.local \
    2>/dev/null | yq 'select(.kind == "Ingress")' 2>/dev/null || echo "")

  if [ -z "${INGRESS_MANIFEST}" ]; then
    echo "NOTE: Could not render chart Ingress template for gap-probe (template may be missing)"
    echo "GAP-PROBE: Chart has no Ingress template that can be rendered — honest gap"
    echo "FAIL: Chart does not emit Ingress with app.kubernetes.io/name label — honest gap"
    exit 1
  fi

  # Check if the rendered Ingress has the required label
  HAS_LABEL=$(echo "${INGRESS_MANIFEST}" | yq '.metadata.labels["app.kubernetes.io/name"] // empty' 2>/dev/null || echo "")
  if [ -n "${HAS_LABEL}" ]; then
    echo "INFO: Chart Ingress has app.kubernetes.io/name label: ${HAS_LABEL}"
    # Dry-run against the active constraint to confirm
    if echo "${INGRESS_MANIFEST}" | kctl apply --dry-run=server -f - 2>/dev/null; then
      echo "PASS: Chart's own Ingress passes the required-labels constraint"
    else
      echo "GAP-PROBE: Chart Ingress was denied by the constraint despite having the label"
      echo "FAIL: Chart Ingress fails required-labels constraint — honest gap"
      exit 1
    fi
  else
    echo "GAP-PROBE: Chart Ingress does NOT have app.kubernetes.io/name label"
    echo "  The chart's Ingress template uses selectorLabels (just 'app: <release>')"
    echo "  instead of the full common labels (which include 'app.kubernetes.io/name')."
    echo "  This is an honest gap — the Ingress would be denied in a cluster with"
    echo "  the K8sRequiredLabels constraint active before chart installation."
    # Verify by dry-running the rendered Ingress against the constraint
    if echo "${INGRESS_MANIFEST}" | kctl apply --dry-run=server -f - 2>&1 | tee /tmp/gk-chart-ingress-gap.txt; then
      echo "UNEXPECTED: Chart Ingress was accepted despite missing label (constraint may not target Ingress)"
    else
      if grep -q "admission webhook.*denied\|Missing required label" /tmp/gk-chart-ingress-gap.txt 2>/dev/null; then
        echo "GAP-PROBE confirmed: Chart Ingress denied by required-labels constraint (honest gap, red cell)"
      else
        echo "GAP-PROBE: Chart Ingress was denied (likely by constraint) — honest gap"
      fi
    fi
    echo "FAIL: Chart Ingress does not carry app.kubernetes.io/name label — honest gap (red cell)"
    exit 1
  fi
else
  echo "NOTE: Chart directory not found at ${CHART_DIR}; skipping Ingress gap-probe render"
  echo "GAP-PROBE: Cannot render chart for Ingress gap-probe — honest gap assumed"
  echo "FAIL: Chart Ingress gap-probe cannot be verified — honest gap (red cell)"
  exit 1
fi
