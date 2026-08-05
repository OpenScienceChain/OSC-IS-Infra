#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="${FABRIC_TEST_WORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.fabric-test-work}"
NETWORK_DIR="$WORK_DIR/fabric-samples/test-network-k8s"

if [[ -x "$NETWORK_DIR/network" ]]; then
  (cd "$NETWORK_DIR" && ./network down) || true
fi
helm uninstall ingress-nginx --namespace ingress-nginx || true
helm uninstall cert-manager --namespace cert-manager || true
kubectl delete namespace test-network ingress-nginx cert-manager --ignore-not-found --wait=false
