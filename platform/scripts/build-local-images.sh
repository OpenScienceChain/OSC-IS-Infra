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
  --arg infra "$(git -C "${INFRA_ROOT}" rev-parse HEAD)" \
  --arg webApp "$(git -C "${WORKTREE_ROOT}/OSC-WebApp" rev-parse HEAD)" \
  --arg apiGateway "$(git -C "${WORKTREE_ROOT}/OSC-APIGateway" rev-parse HEAD)" \
  --arg artifactSubmission "$(git -C "${WORKTREE_ROOT}/OSC-Artifact-Submission" rev-parse HEAD)" \
  --arg chaincode "$(git -C "${WORKTREE_ROOT}/OSC-Chaincode" rev-parse HEAD)" \
  --arg apiGatewayImage "${REGISTRY}/osc-api-gateway@${digests[osc-api-gateway]}" \
  --arg ledgerGatewayImage "${REGISTRY}/osc-ledger-gateway@${digests[osc-ledger-gateway]}" \
  --arg submissionWorkerImage "${REGISTRY}/osc-submission-worker@${digests[osc-submission-worker]}" \
  --arg submissionListenerImage "${REGISTRY}/osc-submission-listener@${digests[osc-submission-listener]}" \
  --arg historyWorkerImage "${REGISTRY}/osc-history-worker@${digests[osc-history-worker]}" \
  --arg webAppImage "${REGISTRY}/osc-webapp@${digests[osc-webapp]}" \
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
      webApp: $webAppImage
    }
  }' > "${OUTPUT_DIR}/manifest.json"

kubectl kustomize "${OUTPUT_DIR}" >/dev/null
echo "Built and rendered six digest-addressed local images in ${OUTPUT_DIR}."
