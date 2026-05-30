#!/usr/bin/env bash
# mounted-tls-certs projected-volume smoke assertion.
# Verifies: product pod has a projected volume with at least one secret source,
# mount path reachable from inside pod, cert files are present.
# Receives: RELEASE, NAMESPACE, KUBECONFIG, KUBE_CONTEXT, PROJECT_DIR
set -euo pipefail

NS="${NAMESPACE:-sample}"
RELEASE="${RELEASE:-sample}"
MOUNT_PATH="${TLS_MOUNT_PATH:-/etc/tls}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

echo "==> Verifying projected volume TLS Secret exists"
kctl -n "${NS}" get secret mounted-tls-projected -o jsonpath='{.type}' | grep -q 'kubernetes.io/tls' || {
  echo "FAIL: TLS Secret mounted-tls-projected not found" >&2; exit 1
}
echo "OK: TLS Secret exists"

echo "==> Verifying pod has a projected volume named 'tls'"
POD_NAME=$(kctl -n "${NS}" get pod -l "app=${RELEASE}" -o jsonpath='{.items[0].metadata.name}')

# Check the 'tls' volume specifically (Kubernetes auto-injects a kube-api-access projected volume)
TLS_VOL_PROJ=$(kctl -n "${NS}" get pod "${POD_NAME}" -o jsonpath='{.spec.volumes[?(@.name=="tls")].projected}')
[ -n "${TLS_VOL_PROJ}" ] || { echo "FAIL: no projected volume named 'tls' found" >&2; exit 1; }
echo "PASS: projected volume 'tls' found"

echo "==> Verifying tls projected volume has secret source"
SECRET_SRC=$(kctl -n "${NS}" get pod "${POD_NAME}" -o jsonpath='{.spec.volumes[?(@.name=="tls")].projected.sources[?(@.secret)].secret.name}')
[ -n "${SECRET_SRC}" ] || { echo "FAIL: tls projected volume has no secret source" >&2; exit 1; }
echo "PASS: projected volume sources include secret '${SECRET_SRC}'"

echo "==> Verifying mountPath matches tls.mountPath"
MOUNTED_PATH=$(kctl -n "${NS}" get pod "${POD_NAME}" -o jsonpath="{.spec.containers[?(@.name=='app')].volumeMounts[?(@.name=='tls')].mountPath}")
[ "${MOUNTED_PATH}" = "${MOUNT_PATH}" ] || { echo "FAIL: expected mountPath ${MOUNT_PATH}, got ${MOUNTED_PATH}" >&2; exit 1; }
echo "PASS: mountPath=${MOUNTED_PATH}"

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

echo "PASS: mounted-tls-certs projected-volume scenario verified"
