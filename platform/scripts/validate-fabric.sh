#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NETWORK_DIR="${PLATFORM_DIR}/.generated/fabric-network"
EVIDENCE_DIR="${OSC_LOCAL_EVIDENCE_DIR:-${PLATFORM_DIR}/.generated/evidence/fabric}"
mkdir -p "${EVIDENCE_DIR}"

export PATH="${NETWORK_DIR}/bin:${PATH}"
export FABRIC_CFG_PATH="${NETWORK_DIR}/config/org1"
CHANNEL=osc-channel
CHAINCODE=osc-provenance
ORDERER=org0-orderer1.localho.st:18443
ORDERER_CA="${NETWORK_DIR}/build/channel-msp/ordererOrganizations/org0/orderers/org0-orderer1/tls/signcerts/tls-cert.pem"

use_org() {
  local org=$1
  export FABRIC_CFG_PATH="${NETWORK_DIR}/config/${org}"
  export CORE_PEER_ADDRESS="${org}-peer1.localho.st:18443"
  export CORE_PEER_MSPCONFIGPATH="${NETWORK_DIR}/build/enrollments/${org}/users/${org}admin/msp"
  export CORE_PEER_TLS_ROOTCERT_FILE="${NETWORK_DIR}/build/channel-msp/peerOrganizations/${org}/msp/tlscacerts/tlsca-signcert.pem"
}

invoke() {
  local org=$1
  local invocation=$2
  local output=$3
  use_org "${org}"
  peer chaincode invoke \
    --channelID "${CHANNEL}" \
    --name "${CHAINCODE}" \
    --ctor "${invocation}" \
    --orderer "${ORDERER}" \
    --connTimeout 10s \
    --tls --cafile "${ORDERER_CA}" \
    --waitForEvent --waitForEventTimeout 30s 2>&1 | tee "${output}"
}

query() {
  local org=$1
  local invocation=$2
  use_org "${org}"
  peer chaincode query --channelID "${CHANNEL}" --name "${CHAINCODE}" --ctor "${invocation}"
}

request() {
  local user=$1
  local organization=$2
  local correlation=$3
  local operation=$4
  jq -nc \
    --arg user "${user}" \
    --arg organization "${organization}" \
    --arg correlation "${correlation}" \
    --arg operation "${operation}" \
    '{authenticatedUserId:$user,organizationId:$organization,correlationId:$correlation,operation:$operation,requestedAt:"2026-09-01T23:00:00Z"}'
}

# Use jq directly for argument arrays; this avoids shell evaluation of JSON data.
make_ctor() {
  local function_name=$1
  shift
  printf '%s\n' "$@" | jq -Rsc --arg fn "${function_name}" '{Args:([$fn] + (split("\n") | .[:-1]))}'
}

ARTIFACT_ID=11111111-1111-4111-8111-111111111111
WORKFLOW_ID=22222222-2222-4222-8222-222222222222
NSG_CREATE_REQUEST=$(request nsg-pi-001 nsg local-nsg-create artifact.create)
NSG_UPDATE_REQUEST=$(request nsg-pi-001 nsg local-nsg-update artifact.update)
CITIZEN_REQUEST=$(request citizen-contributor-001 citizen-science local-citizen-create workflow.create)
ARTIFACT_PAYLOAD='{"title":"Deterministic microscopy dataset","visibility":"private","footprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
ARTIFACT_PATCH='{"keywords":["microscopy","provenance"]}'
WORKFLOW_PAYLOAD='{"title":"Citizen Science curation workflow","visibility":"private"}'

invoke org1 \
  "$(make_ctor ProvenanceContract:CreateArtifact "${ARTIFACT_ID}" "${ARTIFACT_PAYLOAD}" "${NSG_CREATE_REQUEST}")" \
  "${EVIDENCE_DIR}/nsg-artifact-create.txt"

NSG_READ=$(query org1 "$(make_ctor ProvenanceContract:ReadArtifact "${ARTIFACT_ID}")")
echo "${NSG_READ}" | jq -e \
  '.assetId == "11111111-1111-4111-8111-111111111111" and .organizationMsp == "NSGMSP" and .organizationId == "nsg" and .revision == 1 and .createdBy == "nsg-pi-001"' \
  >/dev/null
echo "${NSG_READ}" | jq . > "${EVIDENCE_DIR}/nsg-artifact-read.json"

invoke org1 \
  "$(make_ctor ProvenanceContract:UpdateArtifact "${ARTIFACT_ID}" "${ARTIFACT_PATCH}" "${NSG_UPDATE_REQUEST}")" \
  "${EVIDENCE_DIR}/nsg-artifact-update.txt"

NSG_UPDATED=$(query org1 "$(make_ctor ProvenanceContract:ReadArtifact "${ARTIFACT_ID}")")
echo "${NSG_UPDATED}" | jq -e \
  '.revision == 2 and .payload.title == "Deterministic microscopy dataset" and .payload.keywords == ["microscopy","provenance"]' \
  >/dev/null
echo "${NSG_UPDATED}" | jq . > "${EVIDENCE_DIR}/nsg-artifact-updated.json"

NSG_HISTORY=$(query org1 "$(make_ctor ProvenanceContract:GetArtifactHistory "${ARTIFACT_ID}")")
echo "${NSG_HISTORY}" | jq -e 'length == 2 and .[0].record.revision == 1 and .[1].record.revision == 2' >/dev/null
echo "${NSG_HISTORY}" | jq . > "${EVIDENCE_DIR}/nsg-artifact-history.json"

invoke org2 \
  "$(make_ctor ProvenanceContract:CreateWorkflow "${WORKFLOW_ID}" "${WORKFLOW_PAYLOAD}" "${CITIZEN_REQUEST}")" \
  "${EVIDENCE_DIR}/citizen-workflow-create.txt"

CITIZEN_READ=$(query org2 "$(make_ctor ProvenanceContract:ReadWorkflow "${WORKFLOW_ID}")")
echo "${CITIZEN_READ}" | jq -e \
  '.assetId == "22222222-2222-4222-8222-222222222222" and .organizationMsp == "CitizenScienceMSP" and .organizationId == "citizen-science"' \
  >/dev/null
echo "${CITIZEN_READ}" | jq . > "${EVIDENCE_DIR}/citizen-workflow-read.json"

set +e
CROSS_ORG_OUTPUT=$(query org2 "$(make_ctor ProvenanceContract:ReadArtifact "${ARTIFACT_ID}")" 2>&1)
CROSS_ORG_STATUS=$?
set -e
if [[ ${CROSS_ORG_STATUS} -eq 0 ]] || ! grep -q "belongs to a different organization" <<<"${CROSS_ORG_OUTPUT}"; then
  echo "Cross-organization denial did not behave as expected"
  echo "${CROSS_ORG_OUTPUT}"
  exit 1
fi
printf '%s\n' "${CROSS_ORG_OUTPUT}" > "${EVIDENCE_DIR}/cross-org-denial.txt"

query org1 "$(make_ctor ProvenanceContract:ContractVersion)" | tee "${EVIDENCE_DIR}/contract-version.txt" | grep -q '3.0.0-experimental'

echo "Fabric provenance, history, and organization-isolation checks passed."
