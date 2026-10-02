#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${PLATFORM_DIR}/.." && pwd)"
source "${PLATFORM_DIR}/versions.env"

CACHE_DIR="${OSC_TOOL_CACHE:-${ROOT_DIR}/.osc-tools}"
export PATH="${CACHE_DIR}/bin:${PATH}"
CLUSTER_NAME=osc-usrse26-infra
REGISTRY_NAME=osc-usrse26-registry
REGISTRY_PORT=5017
NETWORK_DIR="${PLATFORM_DIR}/.generated/fabric-network"
CHAINCODE_DIR="$(cd "${ROOT_DIR}/../OSC-Chaincode/chaincode-go" && pwd)"

"${SCRIPT_DIR}/prepare-local.sh"

if kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"; then
  echo "Kind cluster ${CLUSTER_NAME} already exists; run fabric-down.sh first"
  exit 1
fi
if docker container inspect "${REGISTRY_NAME}" >/dev/null 2>&1; then
  echo "Registry container ${REGISTRY_NAME} already exists; run fabric-down.sh first"
  exit 1
fi

docker run --detach --restart=no \
  --name "${REGISTRY_NAME}" \
  --label osc.open-science-chain.org/project=OSC-IS \
  --label osc.open-science-chain.org/purpose=USRSE26-Evidence \
  --publish "127.0.0.1:${REGISTRY_PORT}:5000" \
  "${REGISTRY_IMAGE}" >/dev/null

kind create cluster --name "${CLUSTER_NAME}" --config "${PLATFORM_DIR}/kind/cluster.yaml"
docker network connect kind "${REGISTRY_NAME}"

for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
  docker exec "${node}" sh -c "cat > /etc/containerd/certs.d/localhost:${REGISTRY_PORT}/hosts.toml <<EOF
server = \"http://localhost:${REGISTRY_PORT}\"

[host.\"http://${REGISTRY_NAME}:5000\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
EOF"
done

kubectl create configmap local-registry-hosting \
  --namespace kube-public \
  --from-literal="localRegistryHosting.v1=host: \"localhost:${REGISTRY_PORT}\"" \
  --dry-run=client -o yaml | kubectl apply -f -

export TEST_NETWORK_CLUSTER_RUNTIME=kind
export TEST_NETWORK_CLUSTER_NAME="${CLUSTER_NAME}"
export TEST_NETWORK_NETWORK_NAME=osc-fabric
export TEST_NETWORK_KUBE_NAMESPACE=osc-fabric
export TEST_NETWORK_DOMAIN=localho.st
export TEST_NETWORK_CHANNEL_NAME=osc-channel
export TEST_NETWORK_LOCAL_REGISTRY_NAME="${REGISTRY_NAME}"
export TEST_NETWORK_LOCAL_REGISTRY_PORT="${REGISTRY_PORT}"
export TEST_NETWORK_NGINX_HTTP_PORT=18080
export TEST_NETWORK_NGINX_HTTPS_PORT=18443
export TEST_NETWORK_FABRIC_VERSION="${FABRIC_VERSION}"
export TEST_NETWORK_FABRIC_CA_VERSION="${FABRIC_CA_VERSION}"
export TEST_NETWORK_FABRIC_PEER_IMAGE="${FABRIC_PEER_IMAGE}"
export CHAINCODE_NAME=osc-provenance

pushd "${NETWORK_DIR}" >/dev/null
bash ./network cluster init
bash ./network up
bash ./network channel create
bash ./network chaincode deploy "${CHAINCODE_NAME}" "${CHAINCODE_DIR}"
bash ./network application
popd >/dev/null

kubectl get nodes -o wide
kubectl get pods --all-namespaces -o wide
echo "Fabric network and ${CHAINCODE_NAME} are ready in ${CLUSTER_NAME}."
