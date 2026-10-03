#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${PLATFORM_DIR}/.." && pwd)"
source "${PLATFORM_DIR}/versions.env"

CACHE_DIR="${OSC_TOOL_CACHE:-${ROOT_DIR}/.osc-tools}"
DOWNLOAD_DIR="${CACHE_DIR}/downloads"
BIN_DIR="${CACHE_DIR}/bin"
FABRIC_DIR="${CACHE_DIR}/fabric-${FABRIC_VERSION}-${FABRIC_CA_VERSION}"
GENERATED_DIR="${PLATFORM_DIR}/.generated"
SAMPLES_DIR="${GENERATED_DIR}/fabric-samples"
NETWORK_DIR="${GENERATED_DIR}/fabric-network"
mkdir -p "${DOWNLOAD_DIR}" "${BIN_DIR}" "${GENERATED_DIR}"

download_verified() {
  local url=$1
  local destination=$2
  local expected=$3
  if [[ ! -f "${destination}" ]] || ! echo "${expected}  ${destination}" | sha256sum --check --status; then
    rm -f "${destination}"
    curl --proto '=https' --tlsv1.2 --fail --location --output "${destination}" "${url}"
  fi
  echo "${expected}  ${destination}" | sha256sum --check --status
}

download_verified \
  "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" \
  "${DOWNLOAD_DIR}/kind-${KIND_VERSION}-linux-amd64" \
  "${KIND_LINUX_AMD64_SHA256}"
install -m 0755 "${DOWNLOAD_DIR}/kind-${KIND_VERSION}-linux-amd64" "${BIN_DIR}/kind"

FABRIC_ARCHIVE="${DOWNLOAD_DIR}/hyperledger-fabric-linux-amd64-${FABRIC_VERSION}.tar.gz"
FABRIC_CA_ARCHIVE="${DOWNLOAD_DIR}/hyperledger-fabric-ca-linux-amd64-${FABRIC_CA_VERSION}.tar.gz"
download_verified \
  "https://github.com/hyperledger/fabric/releases/download/v${FABRIC_VERSION}/hyperledger-fabric-linux-amd64-${FABRIC_VERSION}.tar.gz" \
  "${FABRIC_ARCHIVE}" \
  "${FABRIC_LINUX_AMD64_SHA256}"
download_verified \
  "https://github.com/hyperledger/fabric-ca/releases/download/v${FABRIC_CA_VERSION}/hyperledger-fabric-ca-linux-amd64-${FABRIC_CA_VERSION}.tar.gz" \
  "${FABRIC_CA_ARCHIVE}" \
  "${FABRIC_CA_LINUX_AMD64_SHA256}"

if [[ ! -x "${FABRIC_DIR}/bin/peer" || ! -x "${FABRIC_DIR}/bin/fabric-ca-client" ]]; then
  rm -rf "${FABRIC_DIR}"
  mkdir -p "${FABRIC_DIR}"
  tar -xzf "${FABRIC_ARCHIVE}" -C "${FABRIC_DIR}"
  tar -xzf "${FABRIC_CA_ARCHIVE}" -C "${FABRIC_DIR}"
fi

if [[ ! -d "${SAMPLES_DIR}/.git" ]]; then
  rm -rf "${SAMPLES_DIR}"
  git init -q "${SAMPLES_DIR}"
  git -C "${SAMPLES_DIR}" remote add origin https://github.com/hyperledger/fabric-samples.git
fi
if [[ "$(git -C "${SAMPLES_DIR}" rev-parse HEAD 2>/dev/null || true)" != "${FABRIC_SAMPLES_COMMIT}" ]]; then
  git -C "${SAMPLES_DIR}" fetch --depth=1 origin "${FABRIC_SAMPLES_COMMIT}"
  git -C "${SAMPLES_DIR}" checkout --detach --force FETCH_HEAD
fi
[[ "$(git -C "${SAMPLES_DIR}" rev-parse HEAD)" == "${FABRIC_SAMPLES_COMMIT}" ]]

python3 "${SCRIPT_DIR}/patch_fabric_network.py" \
  --source-root "${SAMPLES_DIR}" \
  --destination "${NETWORK_DIR}" \
  --fabric-bin "${FABRIC_DIR}/bin" \
  --vendor "${PLATFORM_DIR}/vendor" \
  --versions "${PLATFORM_DIR}/versions.env"

echo "Local prerequisites prepared in ${CACHE_DIR}"
