#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${PLATFORM_DIR}/.." && pwd)"
CACHE_DIR="${OSC_TOOL_CACHE:-${ROOT_DIR}/.osc-tools}"
export PATH="${CACHE_DIR}/bin:${PATH}"
CLUSTER_NAME=osc-usrse26-infra
REGISTRY_NAME=osc-usrse26-registry

if command -v kind >/dev/null && kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"; then
  kind delete cluster --name "${CLUSTER_NAME}"
fi

if docker container inspect "${REGISTRY_NAME}" >/dev/null 2>&1; then
  project_label=$(docker container inspect "${REGISTRY_NAME}" --format '{{index .Config.Labels "osc.open-science-chain.org/project"}}')
  purpose_label=$(docker container inspect "${REGISTRY_NAME}" --format '{{index .Config.Labels "osc.open-science-chain.org/purpose"}}')
  if [[ "${project_label}" != "OSC-IS" || "${purpose_label}" != "USRSE26-Evidence" ]]; then
    echo "Refusing to remove unrecognized container ${REGISTRY_NAME}"
    exit 1
  fi
  docker rm --force "${REGISTRY_NAME}" >/dev/null
fi

if command -v kind >/dev/null && kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"; then
  echo "Cluster teardown verification failed"
  exit 1
fi
if docker container inspect "${REGISTRY_NAME}" >/dev/null 2>&1; then
  echo "Registry teardown verification failed"
  exit 1
fi
echo "Local Fabric cluster and registry are absent."
