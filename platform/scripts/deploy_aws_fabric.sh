#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NETWORK_DIR="${PLATFORM_DIR}/.generated/fabric-network-eks"
CHAINCODE_DIR="${CHAINCODE_DIR:-$(cd "${PLATFORM_DIR}/../../OSC-Chaincode/chaincode-go" && pwd)}"

: "${RUN_ID:?RUN_ID is required}"
: "${CHAINCODE_IMAGE:?CHAINCODE_IMAGE is required}"

EXPECTED_CONTEXT="osc-usrse26-${RUN_ID}"
if [[ "$(kubectl config current-context)" != "${EXPECTED_CONTEXT}" ]]; then
  echo "Refusing to deploy Fabric outside ${EXPECTED_CONTEXT}" >&2
  exit 1
fi
if [[ "${CHAINCODE_IMAGE}" != *@sha256:* ]]; then
  echo "CHAINCODE_IMAGE must be immutable" >&2
  exit 1
fi
if [[ ! -x "${NETWORK_DIR}/network" ]]; then
  echo "Prepared EKS Fabric network is absent" >&2
  exit 1
fi

source "${PLATFORM_DIR}/versions.env"
export TEST_NETWORK_CLUSTER_RUNTIME=eks
export TEST_NETWORK_CLUSTER_NAME="osc-usrse26-${RUN_ID}-eks"
export TEST_NETWORK_NETWORK_NAME=osc-fabric
export TEST_NETWORK_KUBE_NAMESPACE=osc-fabric
export TEST_NETWORK_DOMAIN=localho.st
export TEST_NETWORK_CHANNEL_NAME=osc-channel
export TEST_NETWORK_NGINX_HTTP_PORT=18080
export TEST_NETWORK_NGINX_HTTPS_PORT=18443
export TEST_NETWORK_FABRIC_VERSION="${FABRIC_VERSION}"
export TEST_NETWORK_FABRIC_CA_VERSION="${FABRIC_CA_VERSION}"
export TEST_NETWORK_FABRIC_PEER_IMAGE="${FABRIC_PEER_IMAGE}"
export TEST_NETWORK_ORDERER_TYPE=raft
export TEST_NETWORK_CHAINCODE_BUILDER=ccaas
export EXTERNAL_CHAINCODE_IMAGE="${CHAINCODE_IMAGE}"
export CHAINCODE_NAME=osc-provenance

pushd "${NETWORK_DIR}" >/dev/null
bash ./network up
bash ./network channel create
bash ./network chaincode deploy "${CHAINCODE_NAME}" "${CHAINCODE_DIR}"
bash ./network application
popd >/dev/null

kubectl -n osc-fabric get deployments,pods,pvc
