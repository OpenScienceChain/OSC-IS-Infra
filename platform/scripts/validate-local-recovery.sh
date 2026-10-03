#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
EVIDENCE_DIR="${EVIDENCE_DIR:-${PLATFORM_DIR}/.generated/evidence/local-recovery}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-kind-osc-usrse26-infra}"
RECOVERY_MODE="${RECOVERY_MODE:-local}"
APPLICATION="${APPLICATION:-osc-is-local}"
API_URL=http://127.0.0.1:13000/api/v1
LEDGER_URL=http://127.0.0.1:14001
NSG_ID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
TMP_DIR=$(mktemp -d)
PORT_FORWARD_PIDS=()
ORIGINAL_RABBIT_EGRESS=''

restore_rabbitmq_egress() {
  [[ -z "${ORIGINAL_RABBIT_EGRESS}" ]] && return 0
  kubectl -n osc-apps patch networkpolicy rabbitmq-amqps --type=merge \
    -p "$(jq -nc --argjson egress "${ORIGINAL_RABBIT_EGRESS}" '{spec: {egress: $egress}}')" >/dev/null
}

restore_stack() {
  kubectl -n osc-apps scale deployment/ledger-gateway-nsg --replicas=1 >/dev/null 2>&1 || true
  kubectl -n osc-fabric scale deployment/org1-peer1 --replicas=1 >/dev/null 2>&1 || true
  if [[ "${RECOVERY_MODE}" == "aws" ]]; then
    restore_rabbitmq_egress >/dev/null 2>&1 || true
    kubectl -n argocd patch application "${APPLICATION}" --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}}}' >/dev/null 2>&1 || true
  else
    kubectl -n osc-apps scale statefulset/rabbitmq --replicas=1 >/dev/null 2>&1 || true
  fi
}

cleanup() {
  local pid
  restore_stack
  for pid in "${PORT_FORWARD_PIDS[@]:-}"; do
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

if ! kubectl config current-context | grep -Fxq "${EXPECTED_CONTEXT}"; then
  echo "Refusing to validate outside ${EXPECTED_CONTEXT}"
  exit 1
fi
if [[ "${RECOVERY_MODE}" == "aws" && ! -f "${AWS_NETWORK_POLICIES:-}" ]]; then
  echo "AWS_NETWORK_POLICIES is required for the controlled Amazon MQ outage" >&2
  exit 1
fi
if [[ "${RECOVERY_MODE}" == "aws" ]]; then
  ORIGINAL_RABBIT_EGRESS=$(kubectl -n osc-apps get networkpolicy rabbitmq-amqps -o json | jq -c '.spec.egress')
  [[ "${ORIGINAL_RABBIT_EGRESS}" != "null" ]]
fi
mkdir -p "${EVIDENCE_DIR}"

PASSWORD=$(kubectl -n osc-apps get secret e2e-user-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
LEDGER_TOKEN=$(kubectl -n osc-apps get secret ledger-gateway-nsg-auth \
  -o jsonpath='{.data.token}' | base64 -d)

kubectl -n osc-apps port-forward service/api-gateway 13000:3000 \
  --address 127.0.0.1 >"${TMP_DIR}/api-forward.log" 2>&1 &
PORT_FORWARD_PIDS+=("$!")
for _ in $(seq 1 30); do
  curl --fail --silent "${API_URL}/health" >/dev/null && break
  sleep 1
done
curl --fail --silent "${API_URL}/health" >/dev/null

LOGIN=$(curl --fail-with-body --silent --show-error \
  -X POST "${API_URL}/users/login" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg username nsg-pi --arg password "${PASSWORD}" \
    --arg organizationId "${NSG_ID}" \
    '{username: $username, password: $password, organizationId: $organizationId}')")
TOKEN=$(jq -er '.token' <<<"${LOGIN}")

create_artifact() {
  local scenario=$1 run_id=$2 body response
  body=$(jq -nc --arg scenario "${scenario}" --arg run "${run_id}" '{
    title: ("Recovery " + $scenario + " " + $run),
    description: ("A deterministic recovery experiment proving durable acceptance and exactly-once ledger state after " + $scenario + " becomes temporarily unavailable."),
    visibility: "private", keywords: ["usrse26", "recovery", $scenario],
    links: [], dois: [], fundingAgencies: [], acknowledgements: "Disposable recovery evidence.",
    manifest: [{filename: ($scenario + ".json"), hash: ("c" * 64), algorithm: "sha256"}],
    footprint: ("d" * 64), submission_comment: "Accepted while a dependency is unavailable and recovered without a duplicate revision."
  }')
  response=$(curl --fail-with-body --silent --show-error \
    -X POST "${API_URL}/artifacts" \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -H "X-Correlation-Id: recovery-${scenario}-${run_id}" --data "${body}")
  jq -er '.id' <<<"${response}"
}

artifact_state() {
  curl --fail-with-body --silent --show-error \
    -H "Authorization: Bearer ${TOKEN}" "${API_URL}/artifacts/$1"
}

wait_for_success() {
  local id=$1 response state
  for _ in $(seq 1 75); do
    response=$(artifact_state "${id}")
    state=$(jq -r '.submissionState' <<<"${response}")
    if [[ "${state}" == SUCCESS ]]; then
      jq -er '.blockchainTxId' <<<"${response}"
      return 0
    fi
    if [[ "${state}" == FAILED ]]; then
      echo "Artifact ${id} reached FAILED during recovery"
      jq . <<<"${response}"
      return 1
    fi
    sleep 2
  done
  echo "Timed out waiting for recovered artifact ${id}"
  return 1
}

outbox_status() {
  kubectl -n osc-apps exec statefulset/postgres -- \
    psql -U osc_app -d osc_is -Atc \
      "SELECT status FROM message_outbox WHERE \"aggregateId\" = '$1' ORDER BY \"createdAt\" DESC LIMIT 1" \
    2>/dev/null | tail -n 1
}

RUN_ID=$(date -u +%Y%m%d%H%M%S)

# Scenario 1: the organization gateway disappears after the API accepts work.
gateway_started=$(date +%s)
if [[ "${RECOVERY_MODE}" == "aws" ]]; then
  # Keep Argo from immediately undoing the deliberate outage under test.
  kubectl -n argocd patch application "${APPLICATION}" --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}' >/dev/null
fi
kubectl -n osc-apps scale deployment/ledger-gateway-nsg --replicas=0 >/dev/null
kubectl -n osc-apps wait --for=delete pod \
  -l app.kubernetes.io/name=ledger-gateway-nsg --timeout=90s >/dev/null
GATEWAY_ARTIFACT_ID=$(create_artifact gateway "${RUN_ID}")
sleep 2
gateway_pending_state=$(artifact_state "${GATEWAY_ARTIFACT_ID}" | jq -r '.submissionState')
[[ "${gateway_pending_state}" == PENDING ]]
kubectl -n osc-apps scale deployment/ledger-gateway-nsg --replicas=1 >/dev/null
kubectl -n osc-apps rollout status deployment/ledger-gateway-nsg --timeout=180s >/dev/null
GATEWAY_TX=$(wait_for_success "${GATEWAY_ARTIFACT_ID}")
gateway_recovery_seconds=$(( $(date +%s) - gateway_started ))

kubectl -n osc-apps port-forward service/ledger-gateway-nsg 14001:4000 \
  --address 127.0.0.1 >"${TMP_DIR}/ledger-forward.log" 2>&1 &
PORT_FORWARD_PIDS+=("$!")
for _ in $(seq 1 30); do
  curl --fail --silent "${LEDGER_URL}/health" >/dev/null && break
  sleep 1
done
GATEWAY_HISTORY=$(curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer ${LEDGER_TOKEN}" \
  "${LEDGER_URL}/history/${GATEWAY_ARTIFACT_ID}")
gateway_revision_count=$(jq -er 'length' <<<"${GATEWAY_HISTORY}")
[[ "${gateway_revision_count}" == 1 ]]

# Scenario 2: RabbitMQ becomes unreachable after the API transaction is committed.
rabbit_started=$(date +%s)
worker_restarted=false
if [[ "${RECOVERY_MODE}" == "aws" ]]; then
  kubectl -n osc-apps patch networkpolicy rabbitmq-amqps --type=merge \
    -p '{"spec":{"egress":[]}}' >/dev/null
  # Restart to discard the established AMQP connection. The API must complete
  # its bounded connection attempt, start in degraded mode, and retain work in
  # the transactional outbox until RabbitMQ becomes reachable again.
  kubectl -n osc-apps delete pod -l app.kubernetes.io/name=api-gateway --wait=true >/dev/null
  kubectl -n osc-apps rollout status deployment/api-gateway --timeout=300s >/dev/null
  kill "${PORT_FORWARD_PIDS[0]}" 2>/dev/null || true
  wait "${PORT_FORWARD_PIDS[0]}" 2>/dev/null || true
  kubectl -n osc-apps port-forward service/api-gateway 13000:3000 \
    --address 127.0.0.1 >"${TMP_DIR}/api-forward-recovered.log" 2>&1 &
  PORT_FORWARD_PIDS+=("$!")
  for _ in $(seq 1 30); do
    curl --fail --silent "${API_URL}/health" >/dev/null && break
    sleep 1
  done
  curl --fail --silent "${API_URL}/health" >/dev/null
else
  kubectl -n osc-apps scale statefulset/rabbitmq --replicas=0 >/dev/null
  kubectl -n osc-apps wait --for=delete pod/rabbitmq-0 --timeout=90s >/dev/null
fi
RABBIT_ARTIFACT_ID=$(create_artifact rabbitmq "${RUN_ID}")
sleep 2
rabbit_pending_state=$(artifact_state "${RABBIT_ARTIFACT_ID}" | jq -r '.submissionState')
[[ "${rabbit_pending_state}" == PENDING ]]
rabbit_outbox_before=$(outbox_status "${RABBIT_ARTIFACT_ID}")
[[ "${rabbit_outbox_before}" == pending ]]

if [[ "${RECOVERY_MODE}" == "aws" ]]; then
  kubectl -n osc-apps delete pod -l app.kubernetes.io/name=submission-worker --wait=true >/dev/null
  kubectl -n osc-apps rollout status deployment/submission-worker --timeout=180s >/dev/null
  worker_restarted=true
  restore_rabbitmq_egress
  kubectl -n argocd patch application "${APPLICATION}" --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}}}' >/dev/null
  kubectl -n argocd annotate application "${APPLICATION}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
else
  kubectl -n osc-apps scale statefulset/rabbitmq --replicas=1 >/dev/null
  kubectl -n osc-apps rollout status statefulset/rabbitmq --timeout=180s >/dev/null
fi
kubectl -n osc-apps rollout status deployment/submission-worker --timeout=180s >/dev/null
kubectl -n osc-apps rollout status deployment/submission-listener --timeout=180s >/dev/null
RABBIT_TX=$(wait_for_success "${RABBIT_ARTIFACT_ID}")
rabbit_recovery_seconds=$(( $(date +%s) - rabbit_started ))
rabbit_outbox_after=$(outbox_status "${RABBIT_ARTIFACT_ID}")
[[ "${rabbit_outbox_after}" == published ]]
RABBIT_HISTORY=$(curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer ${LEDGER_TOKEN}" \
  "${LEDGER_URL}/history/${RABBIT_ARTIFACT_ID}")
rabbit_revision_count=$(jq -er 'length' <<<"${RABBIT_HISTORY}")
[[ "${rabbit_revision_count}" == 1 ]]

# Scenario 3: one NSG peer disappears while the organization gateway uses peer2.
peer_started=$(date +%s)
kubectl -n osc-fabric scale deployment/org1-peer1 --replicas=0 >/dev/null
kubectl -n osc-fabric wait --for=delete pod -l app=org1-peer1 --timeout=90s >/dev/null
PEER_ARTIFACT_ID=$(create_artifact peer "${RUN_ID}")
PEER_TX=$(wait_for_success "${PEER_ARTIFACT_ID}")
peer_recovery_seconds=$(( $(date +%s) - peer_started ))
PEER_HISTORY=$(curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer ${LEDGER_TOKEN}" \
  "${LEDGER_URL}/history/${PEER_ARTIFACT_ID}")
peer_revision_count=$(jq -er 'length' <<<"${PEER_HISTORY}")
[[ "${peer_revision_count}" == 1 ]]
kubectl -n osc-fabric scale deployment/org1-peer1 --replicas=1 >/dev/null
kubectl -n osc-fabric rollout status deployment/org1-peer1 --timeout=180s >/dev/null

jq -n \
  --arg runId "${RUN_ID}" \
  --arg gatewayArtifactId "${GATEWAY_ARTIFACT_ID}" \
  --arg gatewayTransactionId "${GATEWAY_TX}" \
  --argjson gatewayRecoverySeconds "${gateway_recovery_seconds}" \
  --argjson gatewayRevisions "${gateway_revision_count}" \
  --arg rabbitArtifactId "${RABBIT_ARTIFACT_ID}" \
  --arg rabbitTransactionId "${RABBIT_TX}" \
  --argjson rabbitRecoverySeconds "${rabbit_recovery_seconds}" \
  --argjson rabbitRevisions "${rabbit_revision_count}" \
  --arg outboxBefore "${rabbit_outbox_before}" \
  --arg outboxAfter "${rabbit_outbox_after}" \
  --argjson workerRestarted "${worker_restarted}" \
  --arg peerArtifactId "${PEER_ARTIFACT_ID}" \
  --arg peerTransactionId "${PEER_TX}" \
  --argjson peerRecoverySeconds "${peer_recovery_seconds}" \
  --argjson peerRevisions "${peer_revision_count}" \
  '{
    testRun: $runId,
    ledgerGatewayRecovery: {
      acceptedState: "PENDING", recoveredState: "SUCCESS",
      artifactId: $gatewayArtifactId, transactionId: $gatewayTransactionId,
      recoverySeconds: $gatewayRecoverySeconds, ledgerRevisions: $gatewayRevisions
    },
    rabbitMqRecovery: {
      acceptedState: "PENDING", recoveredState: "SUCCESS",
      artifactId: $rabbitArtifactId, transactionId: $rabbitTransactionId,
      outboxBeforeRecovery: $outboxBefore, outboxAfterRecovery: $outboxAfter,
      recoverySeconds: $rabbitRecoverySeconds, ledgerRevisions: $rabbitRevisions,
      workerRestartedDuringOutage: $workerRestarted
    },
    peerFailure: {
      alternatePeerAcceptedTransaction: true,
      artifactId: $peerArtifactId, transactionId: $peerTransactionId,
      recoverySeconds: $peerRecoverySeconds, ledgerRevisions: $peerRevisions
    },
    duplicateLedgerWritesObserved: false,
    credentialsRetained: false
  }' | tee "${EVIDENCE_DIR}/summary.json"

echo "Local dependency-failure recovery validation passed."
