#!/usr/bin/env bash
set -euo pipefail

FABRIC_SAMPLES_COMMIT="05edea01d4cf24dd4087bd3750c36e690dc4d6ff"
FABRIC_VERSION="2.5.15"
CERT_MANAGER_VERSION="v1.18.5"
INGRESS_NGINX_CHART_VERSION="4.15.1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${FABRIC_TEST_WORK_DIR:-$ROOT_DIR/.fabric-test-work}"
SAMPLES_DIR="$WORK_DIR/fabric-samples"
CHAINCODE_DIR="${OSC_CHAINCODE_DIR:-$ROOT_DIR/../OSC-Chaincode/chaincode-go}"
EVIDENCE_DIR="${FABRIC_TEST_EVIDENCE_DIR:-$ROOT_DIR/fabric-test/evidence}"

for command in git kubectl helm jq envsubst curl; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }
done

mkdir -p "$WORK_DIR" "$EVIDENCE_DIR"
if [[ ! -d "$SAMPLES_DIR/.git" ]]; then
  git clone --filter=blob:none --no-checkout https://github.com/hyperledger/fabric-samples.git "$SAMPLES_DIR"
fi
git -C "$SAMPLES_DIR" fetch --depth 1 origin "$FABRIC_SAMPLES_COMMIT"
git -C "$SAMPLES_DIR" checkout --detach "$FABRIC_SAMPLES_COMMIT"
git -C "$SAMPLES_DIR" sparse-checkout init --cone
git -C "$SAMPLES_DIR" sparse-checkout set test-network-k8s

helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "$CERT_MANAGER_VERSION" --set crds.enabled=true --wait --timeout 5m
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version "$INGRESS_NGINX_CHART_VERSION" \
  --set controller.service.type=ClusterIP \
  --set controller.extraArgs.enable-ssl-passthrough=true --wait --timeout 5m

kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80 8443:443 \
  >"$EVIDENCE_DIR/ingress-port-forward.log" 2>&1 &
PORT_FORWARD_PID=$!
trap 'kill "$PORT_FORWARD_PID" 2>/dev/null || true' EXIT
sleep 5

cd "$SAMPLES_DIR/test-network-k8s"
export TEST_NETWORK_FABRIC_VERSION="$FABRIC_VERSION"
export TEST_NETWORK_CHAINCODE_BUILDER="k8s"
export TEST_NETWORK_ORDERER_TYPE="raft"
export TEST_NETWORK_NGINX_HTTP_PORT="8080"
export TEST_NETWORK_NGINX_HTTPS_PORT="8443"
export TEST_NETWORK_DOMAIN="localho.st"

./network up
./network channel create
./network chaincode deploy osc-chaincode "$CHAINCODE_DIR"

kubectl get nodes -o wide >"$EVIDENCE_DIR/nodes.txt"
kubectl get pods -A -o wide >"$EVIDENCE_DIR/pods.txt"
kubectl get deployments,statefulsets,services,pvc -A >"$EVIDENCE_DIR/workloads.txt"
./network chaincode query osc-chaincode \
  '{"Args":["org.hyperledger.fabric:GetMetadata"]}' \
  >"$EVIDENCE_DIR/chaincode-metadata.json"

echo "Fabric ${FABRIC_VERSION} with OSC chaincode is ready on the EKS test cluster."
