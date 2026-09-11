#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_ROOT="$(cd "${PLATFORM_DIR}/.." && pwd)"
WORKTREE_ROOT="$(cd "${INFRA_ROOT}/.." && pwd)"
OUTPUT_DIR="${PLATFORM_DIR}/.generated/local-images"
REGISTRY=localhost:5017
TAG=usrse26-local

if ! kubectl config current-context | grep -Fxq kind-osc-usrse26-infra; then
  echo "Refusing to build for a context other than kind-osc-usrse26-infra" >&2
  exit 1
fi
if ! curl --fail --silent "http://${REGISTRY}/v2/" >/dev/null; then
  echo "The isolated OSC local registry is unavailable" >&2
  exit 1
fi

git_revision() {
  local repository=$1
  local revision
  if command -v git.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    revision=$(git.exe -C "$(wslpath -w "${repository}")" rev-parse HEAD 2>/dev/null | tr -d '\r')
  else
    revision=$(git -C "${repository}" rev-parse HEAD)
  fi
  if [[ ! "${revision}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Could not resolve a complete source revision for ${repository}" >&2
    return 1
  fi
  printf '%s' "${revision}"
}

declare -A contexts=(
  [osc-api-gateway]="${WORKTREE_ROOT}/OSC-APIGateway"
  [osc-ledger-gateway]="${WORKTREE_ROOT}/OSC-Artifact-Submission/fabric-bridge"
  [osc-submission-worker]="${WORKTREE_ROOT}/OSC-Artifact-Submission/submission_worker"
  [osc-submission-listener]="${WORKTREE_ROOT}/OSC-Artifact-Submission/submission_listener"
  [osc-history-worker]="${WORKTREE_ROOT}/OSC-Artifact-Submission/get_history_worker"
  [osc-webapp]="${WORKTREE_ROOT}/OSC-WebApp"
)
ordered_names=(
  osc-api-gateway
  osc-ledger-gateway
  osc-submission-worker
  osc-submission-listener
  osc-history-worker
  osc-webapp
)

mkdir -p "${OUTPUT_DIR}"
declare -A digests=()
for name in "${ordered_names[@]}"; do
  reference="${REGISTRY}/${name}:${TAG}"
  docker build --pull=false --provenance=false --platform linux/amd64 \
    --tag "${reference}" "${contexts[$name]}"
  docker push "${reference}"
  repo_digest=$(docker image inspect "${reference}" --format '{{json .RepoDigests}}' \
    | jq -er --arg prefix "${REGISTRY}/${name}@sha256:" \
      '.[] | select(startswith($prefix))')
  digests["${name}"]="${repo_digest#*@}"
done

chaincode_digest=$(docker image inspect localhost:5017/osc-provenance:latest --format '{{json .RepoDigests}}' \
  | jq -er '.[] | select(startswith("localhost:5017/osc-provenance@sha256:"))')
infra_revision=$(git_revision "${INFRA_ROOT}")
webapp_revision=$(git_revision "${WORKTREE_ROOT}/OSC-WebApp")
api_revision=$(git_revision "${WORKTREE_ROOT}/OSC-APIGateway")
artifact_revision=$(git_revision "${WORKTREE_ROOT}/OSC-Artifact-Submission")
chaincode_revision=$(git_revision "${WORKTREE_ROOT}/OSC-Chaincode")

{
  printf '%s\n' 'apiVersion: kustomize.config.k8s.io/v1beta1'
  printf '%s\n' 'kind: Kustomization'
  printf '%s\n' 'resources:'
  printf '%s\n' '  - ../../gitops/local'
  printf '%s\n' 'images:'
  for name in "${ordered_names[@]}"; do
    printf '  - name: %s/%s\n' "${REGISTRY}" "${name}"
    printf '    newName: %s/%s\n' "${REGISTRY}" "${name}"
    printf '    digest: %s\n' "${digests[$name]}"
  done
} > "${OUTPUT_DIR}/kustomization.yaml"

jq -n \
  --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg infra "${infra_revision}" \
  --arg webApp "${webapp_revision}" \
  --arg apiGateway "${api_revision}" \
  --arg artifactSubmission "${artifact_revision}" \
  --arg chaincode "${chaincode_revision}" \
  --arg apiGatewayImage "${REGISTRY}/osc-api-gateway@${digests[osc-api-gateway]}" \
  --arg ledgerGatewayImage "${REGISTRY}/osc-ledger-gateway@${digests[osc-ledger-gateway]}" \
  --arg submissionWorkerImage "${REGISTRY}/osc-submission-worker@${digests[osc-submission-worker]}" \
  --arg submissionListenerImage "${REGISTRY}/osc-submission-listener@${digests[osc-submission-listener]}" \
  --arg historyWorkerImage "${REGISTRY}/osc-history-worker@${digests[osc-history-worker]}" \
  --arg webAppImage "${REGISTRY}/osc-webapp@${digests[osc-webapp]}" \
  --arg chaincodeImage "${chaincode_digest}" \
  '{
    schemaVersion: 1,
    createdAt: $createdAt,
    sourceCommits: {
      infra: $infra,
      webApp: $webApp,
      apiGateway: $apiGateway,
      artifactSubmission: $artifactSubmission,
      chaincode: $chaincode
    },
    images: {
      apiGateway: $apiGatewayImage,
      ledgerGateway: $ledgerGatewayImage,
      submissionWorker: $submissionWorkerImage,
      submissionListener: $submissionListenerImage,
      historyWorker: $historyWorkerImage,
      webApp: $webAppImage,
      chaincode: $chaincodeImage
    }
  }' > "${OUTPUT_DIR}/manifest.json"

kubectl kustomize "${OUTPUT_DIR}" >/dev/null
echo "Built and rendered six digest-addressed local images in ${OUTPUT_DIR}."
