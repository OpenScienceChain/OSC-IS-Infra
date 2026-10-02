#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GENERATED_DIR="${PLATFORM_DIR}/.generated/gitops"
EVIDENCE_DIR="${EVIDENCE_DIR:-${PLATFORM_DIR}/.generated/evidence/local-gitops}"
APPLICATION="${APPLICATION:-osc-is-local}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-kind-osc-usrse26-infra}"
ROLLOUT_ANNOTATION="usrse26.osc.example/rollout-id"

if [[ -f "${GENERATED_DIR}/run.env" && -z "${BASELINE_REVISION:-}" ]]; then
  # shellcheck source=/dev/null
  source "${GENERATED_DIR}/run.env"
fi
: "${RUN_ID:?RUN_ID or local run.env is required}"
: "${BASELINE_REVISION:?BASELINE_REVISION or local run.env is required}"
: "${ROLLOUT_REVISION:?ROLLOUT_REVISION or local run.env is required}"
: "${REPOSITORY_IMAGE:?REPOSITORY_IMAGE or local run.env is required}"
if ! kubectl config current-context | grep -Fxq "${EXPECTED_CONTEXT}"; then
  echo "Refusing to validate outside ${EXPECTED_CONTEXT}" >&2
  exit 1
fi
mkdir -p "${EVIDENCE_DIR}"

wait_for_application() {
  local revision="$1"
  local deadline=$((SECONDS + 300))
  while (( SECONDS < deadline )); do
    local sync health observed
    sync="$(kubectl get application -n argocd "${APPLICATION}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl get application -n argocd "${APPLICATION}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    observed="$(kubectl get application -n argocd "${APPLICATION}" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
    if [[ "${sync}" == "Synced" && "${health}" == "Healthy" && "${observed}" == "${revision}" ]]; then
      return 0
    fi
    sleep 3
  done
  kubectl get application -n argocd "${APPLICATION}" -o yaml >&2 || true
  return 1
}

refresh_application() {
  kubectl annotate application -n argocd "${APPLICATION}" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
}

wait_for_annotation() {
  local expected="$1"
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    local actual
    actual="$(kubectl get deployment -n osc-apps api-gateway \
      -o jsonpath="{.spec.template.metadata.annotations.${ROLLOUT_ANNOTATION//./\\.}}" 2>/dev/null || true)"
    if [[ "${actual}" == "${expected}" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_annotation_absent() {
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    local actual
    actual="$(kubectl get deployment -n osc-apps api-gateway \
      -o jsonpath="{.spec.template.metadata.annotations.${ROLLOUT_ANNOTATION//./\\.}}" 2>/dev/null || true)"
    if [[ -z "${actual}" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
wait_for_application "${BASELINE_REVISION}"
BASELINE_IMAGE="$(kubectl get deployment -n osc-apps api-gateway -o jsonpath='{.spec.template.spec.containers[?(@.name=="api-gateway")].image}')"
if [[ "${BASELINE_IMAGE}" != *@sha256:* ]]; then
  echo "API Gateway is not deployed by immutable digest." >&2
  exit 1
fi
BASELINE_REPLICAS="$(kubectl get deployment -n osc-apps api-gateway -o jsonpath='{.spec.replicas}')"
if [[ ! "${BASELINE_REPLICAS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Could not determine the positive API Gateway baseline replica count." >&2
  exit 1
fi
DRIFT_REPLICAS=$((BASELINE_REPLICAS + 1))

DRIFT_STARTED="$(date +%s)"
kubectl scale deployment -n osc-apps api-gateway --replicas="${DRIFT_REPLICAS}" >/dev/null
refresh_application
while [[ "$(kubectl get deployment -n osc-apps api-gateway -o jsonpath='{.spec.replicas}' 2>/dev/null || true)" != "${BASELINE_REPLICAS}" ]]; do
  if (( $(date +%s) - DRIFT_STARTED > 180 )); then
    echo "Argo CD did not self-heal the injected drift." >&2
    exit 1
  fi
  sleep 2
done
DRIFT_SECONDS="$(( $(date +%s) - DRIFT_STARTED ))"
wait_for_application "${BASELINE_REVISION}"

ROLLOUT_STARTED="$(date +%s)"
kubectl patch application -n argocd "${APPLICATION}" --type=merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"${ROLLOUT_REVISION}\"}}}" >/dev/null
refresh_application
wait_for_application "${ROLLOUT_REVISION}"
wait_for_annotation "${RUN_ID}"
kubectl rollout status -n osc-apps deployment/api-gateway --timeout=3m >/dev/null
ROLLOUT_SECONDS="$(( $(date +%s) - ROLLOUT_STARTED ))"

ROLLBACK_STARTED="$(date +%s)"
kubectl patch application -n argocd "${APPLICATION}" --type=merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"${BASELINE_REVISION}\"}}}" >/dev/null
refresh_application
wait_for_application "${BASELINE_REVISION}"
wait_for_annotation_absent
kubectl rollout status -n osc-apps deployment/api-gateway --timeout=3m >/dev/null
ROLLBACK_SECONDS="$(( $(date +%s) - ROLLBACK_STARTED ))"

FINAL_IMAGE="$(kubectl get deployment -n osc-apps api-gateway -o jsonpath='{.spec.template.spec.containers[?(@.name=="api-gateway")].image}')"
if [[ "${FINAL_IMAGE}" != "${BASELINE_IMAGE}" ]]; then
  echo "Rollback did not restore the known-good immutable image reference." >&2
  exit 1
fi

FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg runId "${RUN_ID}" \
  --arg startedAt "${STARTED_AT}" \
  --arg finishedAt "${FINISHED_AT}" \
  --arg baselineRevision "${BASELINE_REVISION}" \
  --arg rolloutRevision "${ROLLOUT_REVISION}" \
  --arg repositoryImage "${REPOSITORY_IMAGE}" \
  --arg applicationImage "${FINAL_IMAGE}" \
  --argjson driftSeconds "${DRIFT_SECONDS}" \
  --argjson rolloutSeconds "${ROLLOUT_SECONDS}" \
  --argjson rollbackSeconds "${ROLLBACK_SECONDS}" \
  '{
    runId: $runId,
    startedAt: $startedAt,
    finishedAt: $finishedAt,
    source: {
      repositoryImage: $repositoryImage,
      baselineRevision: $baselineRevision,
      rolloutRevision: $rolloutRevision
    },
    deployment: {
      applicationImage: $applicationImage,
      immutableImage: ($applicationImage | contains("@sha256:"))
    },
    drift: {detectedAndSelfHealed: true, seconds: $driftSeconds},
    rollout: {succeeded: true, seconds: $rolloutSeconds},
    rollback: {knownGoodRevisionRestored: true, seconds: $rollbackSeconds},
    credentialsRetained: false
  }' | tee "${EVIDENCE_DIR}/summary.json"

kubectl get application -n argocd "${APPLICATION}" -o json \
  | jq '{metadata: {name: .metadata.name}, spec: {source: .spec.source, destination: .spec.destination, syncPolicy: .spec.syncPolicy}, status: {health: .status.health, sync: .status.sync, history: .status.history}}' \
  >"${EVIDENCE_DIR}/application.json"

echo "Local Argo CD drift, rollout, and rollback validation passed."
