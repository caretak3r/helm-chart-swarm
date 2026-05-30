#!/usr/bin/env bash
# mounted-tls-certs pvc-mount smoke assertion.
# Verifies: product pod has a volumeMount whose mountPath matches tls.mountPath,
# the volume source is persistentVolumeClaim, and stat on the cert succeeds.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
MOUNT_PATH="${TLS_MOUNT_PATH:-/etc/tls}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Checking PVC 'mounted-tls-pvc' exists"
kctl -n "${NS}" get pvc mounted-tls-pvc -o jsonpath='{.status.phase}' | grep -q 'Bound' || {
  echo "FAIL: PVC mounted-tls-pvc not Bound" >&2; exit 1
}
echo "OK: PVC is Bound"

echo "==> Verifying pod has PVC-backed tls volume"
POD_NAME=$(kctl -n "${NS}" get pod -l "app=${RELEASE}" -o jsonpath='{.items[0].metadata.name}')
PVC_VOL_NAME=$(kctl -n "${NS}" get pod "${POD_NAME}" -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].name}')
[ -n "${PVC_VOL_NAME}" ] || { echo "FAIL: no persistentVolumeClaim volume found" >&2; exit 1; }
echo "PASS: PVC volume '${PVC_VOL_NAME}' found"

echo "==> Verifying mountPath matches tls.mountPath"
MOUNTED_PATH=$(kctl -n "${NS}" get pod "${POD_NAME}" -o jsonpath="{.spec.containers[?(@.name=='app')].volumeMounts[?(@.name=='${PVC_VOL_NAME}')].mountPath}")
[ "${MOUNTED_PATH}" = "${MOUNT_PATH}" ] || { echo "FAIL: expected mountPath ${MOUNT_PATH}, got ${MOUNTED_PATH}" >&2; exit 1; }
echo "PASS: mountPath=${MOUNTED_PATH}"

echo "==> Verifying volume source is persistentVolumeClaim"
PVC_CLAIM=$(kctl -n "${NS}" get pod "${POD_NAME}" -o jsonpath="{.spec.volumes[?(@.name=='${PVC_VOL_NAME}')].persistentVolumeClaim.claimName}")
[ -n "${PVC_CLAIM}" ] || { echo "FAIL: volume source is not persistentVolumeClaim" >&2; exit 1; }
echo "PASS: volume source is persistentVolumeClaim (claim=${PVC_CLAIM})"

echo "==> Waiting for pod Ready (3m max)"
kctl -n "${NS}" wait pod -l "app=${RELEASE}" --for=condition=Ready --timeout=3m
echo "PASS: chart pods Ready"

echo "==> Exec stat ${MOUNT_PATH}/tls.crt in pod"
kctl -n "${NS}" exec "${POD_NAME}" -- stat "${MOUNT_PATH}/tls.crt" || {
  echo "FAIL: tls.crt not found at ${MOUNT_PATH}" >&2; exit 1
}
echo "PASS: tls.crt accessible at ${MOUNT_PATH}"

echo "==> Verifying HTTPS reachable from in-cluster curl"
SVC_IP=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.clusterIP}')
TLS_PORT=$(kctl -n "${NS}" get svc "${RELEASE}" -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
DOMAIN="${RELEASE}.${NS}.svc"

HTTP_CODE=$(kctl -n "${NS}" run ct-curl --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.6.0 --timeout=30s -- \
  sh -c "curl -s -o /dev/null -w '%{http_code}' -k \
    --resolve '${DOMAIN}:${TLS_PORT}:${SVC_IP}' \
    'https://${DOMAIN}:${TLS_PORT}/'" 2>/dev/null || echo "000")

echo "HTTPS response: ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "PASS: HTTPS 200"
else
  echo "FAIL: expected HTTP 200, got ${HTTP_CODE}" >&2
  exit 1
fi

echo "PASS: mounted-tls-certs pvc-mount scenario verified"
