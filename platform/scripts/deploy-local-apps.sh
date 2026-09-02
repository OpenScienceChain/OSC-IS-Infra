#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NETWORK_DIR="${PLATFORM_DIR}/.generated/fabric-network"
SECRET_DIR="${PLATFORM_DIR}/.generated/runtime-secrets"
NAMESPACE=osc-apps

if ! kubectl config current-context | grep -Fxq kind-osc-usrse26-infra; then
  echo "Refusing to deploy outside kind-osc-usrse26-infra"
  exit 1
fi
if [[ ! -f "${NETWORK_DIR}/build/application/wallet/appuser_org1.id" ]]; then
  echo "Fabric application identities are absent; run fabric-up.sh first"
  exit 1
fi
if ! curl --fail --silent http://127.0.0.1:5017/v2/ >/dev/null; then
  echo "The isolated OSC local registry is unavailable"
  exit 1
fi

umask 077
mkdir -p "${SECRET_DIR}"

generate_secret() {
  local path=$1
  local value

  if [[ -s "${path}" ]]; then
    value=$(tr -d '\r\n' < "${path}")
  else
    value=$(openssl rand -hex 32)
  fi
  printf '%s' "${value}" > "${path}"
}

printf '%s' osc_app > "${SECRET_DIR}/postgres-username"
printf '%s' osc_is > "${SECRET_DIR}/postgres-database"
printf '%s' osc_user > "${SECRET_DIR}/rabbitmq-username"
generate_secret "${SECRET_DIR}/postgres-password"
generate_secret "${SECRET_DIR}/rabbitmq-password"
generate_secret "${SECRET_DIR}/jwt-secret"
generate_secret "${SECRET_DIR}/bootstrap-admin-password"
generate_secret "${SECRET_DIR}/listener-api-key"
generate_secret "${SECRET_DIR}/nsg-ledger-token"
generate_secret "${SECRET_DIR}/citizen-ledger-token"

jq -r '.credentials.certificate' \
  "${NETWORK_DIR}/build/application/wallet/appuser_org1.id" > "${SECRET_DIR}/nsg-certificate.pem"
jq -r '.credentials.privateKey' \
  "${NETWORK_DIR}/build/application/wallet/appuser_org1.id" > "${SECRET_DIR}/nsg-private-key.pem"
jq -r '.credentials.certificate' \
  "${NETWORK_DIR}/build/application/wallet/appuser_org2.id" > "${SECRET_DIR}/citizen-certificate.pem"
jq -r '.credentials.privateKey' \
  "${NETWORK_DIR}/build/application/wallet/appuser_org2.id" > "${SECRET_DIR}/citizen-private-key.pem"
kubectl -n osc-fabric get secret org1-peer1-tls-cert -o jsonpath='{.data.ca\.crt}' \
  | base64 -d > "${SECRET_DIR}/nsg-tls-ca.pem"
kubectl -n osc-fabric get secret org2-peer1-tls-cert -o jsonpath='{.data.ca\.crt}' \
  | base64 -d > "${SECRET_DIR}/citizen-tls-ca.pem"

kubectl apply -f "${PLATFORM_DIR}/gitops/local/namespace.yaml" >/dev/null

apply_secret() {
  kubectl -n "${NAMESPACE}" create secret generic "$1" "${@:2}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

apply_secret postgres-credentials \
  --from-file=username="${SECRET_DIR}/postgres-username" \
  --from-file=password="${SECRET_DIR}/postgres-password" \
  --from-file=database="${SECRET_DIR}/postgres-database"
apply_secret rabbitmq-credentials \
  --from-file=username="${SECRET_DIR}/rabbitmq-username" \
  --from-file=password="${SECRET_DIR}/rabbitmq-password"
apply_secret api-auth --from-file=jwt-secret="${SECRET_DIR}/jwt-secret"
apply_secret api-bootstrap-admin \
  --from-file=password="${SECRET_DIR}/bootstrap-admin-password"
apply_secret listener-api-auth --from-file=api-key="${SECRET_DIR}/listener-api-key"
apply_secret ledger-gateway-nsg-auth --from-file=token="${SECRET_DIR}/nsg-ledger-token"
apply_secret ledger-gateway-citizen-science-auth --from-file=token="${SECRET_DIR}/citizen-ledger-token"
apply_secret fabric-nsg-identity \
  --from-file=certificate.pem="${SECRET_DIR}/nsg-certificate.pem" \
  --from-file=private-key.pem="${SECRET_DIR}/nsg-private-key.pem" \
  --from-file=tls-ca.pem="${SECRET_DIR}/nsg-tls-ca.pem"
apply_secret fabric-citizen-science-identity \
  --from-file=certificate.pem="${SECRET_DIR}/citizen-certificate.pem" \
  --from-file=private-key.pem="${SECRET_DIR}/citizen-private-key.pem" \
  --from-file=tls-ca.pem="${SECRET_DIR}/citizen-tls-ca.pem"

# Upstream Fabric samples create this ConfigMap with private keys. The OSC
# deployment consumes namespace-scoped Secrets instead and removes the copy.
kubectl -n osc-fabric delete configmap app-fabric-ids-v1-map --ignore-not-found >/dev/null

kubectl apply -k "${PLATFORM_DIR}/gitops/local"
kubectl -n "${NAMESPACE}" wait --for=condition=Ready certificate/postgres-tls certificate/rabbitmq-tls --timeout=180s
kubectl -n "${NAMESPACE}" rollout status statefulset/postgres --timeout=300s
kubectl -n "${NAMESPACE}" rollout status statefulset/rabbitmq --timeout=300s
for deployment in api-gateway ledger-gateway-nsg ledger-gateway-citizen-science submission-worker submission-listener; do
  kubectl -n "${NAMESPACE}" rollout status "deployment/${deployment}" --timeout=300s
done

# A terminating worker may still consume queue messages after the new replica
# is ready. Wait for replaced pods to exit before declaring the stack stable.
while IFS= read -r terminating_pod; do
  [[ -z "${terminating_pod}" ]] || kubectl -n "${NAMESPACE}" wait \
    --for=delete "pod/${terminating_pod}" --timeout=90s
done < <(kubectl -n "${NAMESPACE}" get pods -o json \
  | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name')

if kubectl -n osc-fabric get configmap app-fabric-ids-v1-map >/dev/null 2>&1; then
  echo "Fabric identity ConfigMap removal failed"
  exit 1
fi
kubectl -n "${NAMESPACE}" get pods -o wide
echo "OSC application services are ready with TLS data services and Secret-backed identities."
