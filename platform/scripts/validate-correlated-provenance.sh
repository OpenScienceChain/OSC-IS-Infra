#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
EVIDENCE_DIR="${EVIDENCE_DIR:-${PLATFORM_DIR}/.generated/evidence/correlated-provenance}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-kind-osc-usrse26-infra}"
API_URL=http://127.0.0.1:13000/api/v1
NSG_LEDGER_URL=http://127.0.0.1:14001
CITIZEN_LEDGER_URL=http://127.0.0.1:14002
NSG_ID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
CITIZEN_ID=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
CORRELATION_ID=usrse26-e2e-20260902-local-003
TMP_DIR=$(mktemp -d)
PORT_FORWARD_PIDS=()
WATCHER_PID=

cleanup() {
  local pid
  [[ -z "${WATCHER_PID}" ]] || kill "${WATCHER_PID}" 2>/dev/null || true
  for pid in "${PORT_FORWARD_PIDS[@]:-}"; do
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  rm -rf "${TMP_DIR}"
}
on_error() {
  local line=$1
  echo "Correlated provenance validation failed at line ${line}" >&2
  for log in "${TMP_DIR}"/rabbit-watcher.log "${TMP_DIR}"/*-forward.log; do
    [[ -s "${log}" ]] && { echo "--- ${log##*/} ---" >&2; tail -n 20 "${log}" >&2; }
  done
  if [[ -s "${TMP_DIR}/rabbit-boundaries.json" ]]; then
    echo "--- sanitized RabbitMQ capture ---" >&2
    jq . "${TMP_DIR}/rabbit-boundaries.json" >&2 2>/dev/null || true
  fi
}
trap 'on_error ${LINENO}' ERR
trap cleanup EXIT

if [[ "${VERIFY_ONLY:-false}" == true ]]; then
  for command in jq sha256sum; do
    command -v "${command}" >/dev/null || { echo "Missing required command: ${command}" >&2; exit 1; }
  done
  (cd "${EVIDENCE_DIR}" && sha256sum -c checksums.sha256)
  jq -e '.revisionCount == 1 and .duplicateLedgerRevision == false
    and .assertions.singleRevision and .assertions.transactionConsistent
    and .assertions.correlationConsistent and .assertions.outboxPublishedWithoutRetry
    and .authorization.citizenScienceApiRead.denied
    and .authorization.citizenScienceFabricRead.denied' \
    "${EVIDENCE_DIR}/trace-manifest.json" >/dev/null
  echo "Stored correlated provenance evidence is checksum-valid and internally consistent."
  exit 0
fi
if ! kubectl config current-context | grep -Fxq "${EXPECTED_CONTEXT}"; then
  echo "Refusing to validate outside ${EXPECTED_CONTEXT}" >&2
  exit 1
fi
for command in kubectl curl jq base64 sha256sum; do
  command -v "${command}" >/dev/null || { echo "Missing required command: ${command}" >&2; exit 1; }
done
if [[ -e "${EVIDENCE_DIR}" ]] && find "${EVIDENCE_DIR}" -mindepth 1 -print -quit | grep -q .; then
  echo "Refusing to overwrite non-empty evidence directory: ${EVIDENCE_DIR}" >&2
  exit 1
fi
mkdir -p "${EVIDENCE_DIR}"

db_query() {
  kubectl -n osc-apps exec postgres-0 -- \
    psql -U osc_app -d osc_is -At -v ON_ERROR_STOP=1 -c "$1" 2>/dev/null
}

existing=$(db_query "SELECT count(*) FROM message_outbox WHERE \"messageId\" = '${CORRELATION_ID}';")
if [[ "${existing}" != 0 ]]; then
  echo "Correlation ID ${CORRELATION_ID} already exists; refusing to create a duplicate trace" >&2
  exit 1
fi

PASSWORD=$(kubectl -n osc-apps get secret e2e-user-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
NSG_LEDGER_TOKEN=$(kubectl -n osc-apps get secret ledger-gateway-nsg-auth \
  -o jsonpath='{.data.token}' | base64 -d)
CITIZEN_LEDGER_TOKEN=$(kubectl -n osc-apps get secret ledger-gateway-citizen-science-auth \
  -o jsonpath='{.data.token}' | base64 -d)

kubectl -n osc-apps port-forward service/api-gateway 13000:3000 \
  --address 127.0.0.1 >"${TMP_DIR}/api-forward.log" 2>&1 &
PORT_FORWARD_PIDS+=("$!")
kubectl -n osc-apps port-forward service/ledger-gateway-nsg 14001:4000 \
  --address 127.0.0.1 >"${TMP_DIR}/nsg-ledger-forward.log" 2>&1 &
PORT_FORWARD_PIDS+=("$!")
kubectl -n osc-apps port-forward service/ledger-gateway-citizen-science 14002:4000 \
  --address 127.0.0.1 >"${TMP_DIR}/citizen-ledger-forward.log" 2>&1 &
PORT_FORWARD_PIDS+=("$!")

for _ in $(seq 1 30); do
  if curl --fail --silent "${API_URL}/health" >/dev/null \
    && curl --fail --silent "${NSG_LEDGER_URL}/health" >/dev/null \
    && curl --fail --silent "${CITIZEN_LEDGER_URL}/health" >/dev/null; then
    break
  fi
  sleep 1
done
curl --fail --silent "${API_URL}/health" >/dev/null
curl --fail --silent "${NSG_LEDGER_URL}/health" >/dev/null
curl --fail --silent "${CITIZEN_LEDGER_URL}/health" >/dev/null

read -r -d '' WATCHER_PY <<'PY' || true
import json
import os
import time

import app
import pika

target = os.environ["TARGET_CORRELATION"]
parameters = pika.ConnectionParameters(
    host=app.RABBITMQ_HOST,
    port=app.RABBITMQ_PORT,
    credentials=pika.PlainCredentials(app.RABBITMQ_USER, app.RABBITMQ_PASS),
    ssl_options=app._tls_options(),
    heartbeat=60,
    blocked_connection_timeout=60,
)
connection = pika.BlockingConnection(parameters)
channel = connection.channel()
queue = channel.queue_declare(queue="", exclusive=True, auto_delete=True).method.queue
for routing_key in ("artifact.submit", "artifact.submitted"):
    channel.queue_bind(exchange="artifact.exchange", queue=queue, routing_key=routing_key)

captured = []
deadline = time.monotonic() + 90
for method, properties, body in channel.consume(queue, inactivity_timeout=1, auto_ack=True):
    if time.monotonic() > deadline:
        break
    if method is None:
        continue
    payload = json.loads(body)
    identifiers = {
        "artifactId": payload.get("artifactId"),
        "correlationId": payload.get("correlationId"),
        "submissionState": payload.get("submissionState"),
        "blockchainTxId": payload.get("blockchainTxId"),
        "peerId": payload.get("peerId"),
        "organization": payload.get("organization"),
        "request": payload.get("request"),
        "submittedAt": payload.get("submittedAt"),
    }
    identifiers = {key: value for key, value in identifiers.items() if value is not None}
    message_id = getattr(properties, "message_id", None)
    correlation_id = getattr(properties, "correlation_id", None)
    if target not in (message_id, correlation_id, payload.get("correlationId")):
        continue
    captured.append({
        "routingKey": method.routing_key,
        "messageId": message_id,
        "correlationId": correlation_id,
        "payload": identifiers,
    })
    if {item["routingKey"] for item in captured} == {"artifact.submit", "artifact.submitted"}:
        break

channel.cancel()
connection.close()
print(json.dumps(captured, sort_keys=True))
if {item["routingKey"] for item in captured} != {"artifact.submit", "artifact.submitted"}:
    raise SystemExit("Did not observe both correlated RabbitMQ boundaries")
PY

kubectl -n osc-apps exec deployment/submission-worker -- \
  env TARGET_CORRELATION="${CORRELATION_ID}" python -c "${WATCHER_PY}" \
  >"${TMP_DIR}/rabbit-boundaries.json" 2>"${TMP_DIR}/rabbit-watcher.log" &
WATCHER_PID=$!
sleep 2

login_response=$(curl --fail-with-body --silent --show-error \
  -X POST "${API_URL}/users/login" \
  -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg password "${PASSWORD}" --arg organizationId "${NSG_ID}" \
    '{username:"nsg-pi",password:$password,organizationId:$organizationId}')")
NSG_TOKEN=$(jq -er '.token' <<<"${login_response}")
CITIZEN_LOGIN=$(curl --fail-with-body --silent --show-error \
  -X POST "${API_URL}/users/login" \
  -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg password "${PASSWORD}" --arg organizationId "${CITIZEN_ID}" \
    '{username:"citizen-contributor",password:$password,organizationId:$organizationId}')")
CITIZEN_TOKEN=$(jq -er '.token' <<<"${CITIZEN_LOGIN}")

ARTIFACT_BODY=$(jq -nc '{
  title: "USRSE correlated provenance artifact 003",
  description: "A deterministic local record proving one complete asynchronous provenance path through the remediated OSC-IS product.",
  visibility: "private",
  keywords: [], links: [], dois: [], fundingAgencies: [], acknowledgements: "",
  manifest: [{filename:"result.csv",hash:("c" * 64),algorithm:"sha256"}],
  footprint:("d" * 64),
  submission_comment:"Single-revision correlated evidence run for US-RSE 2026."
}')
CREATE_RESPONSE=$(curl --fail-with-body --silent --show-error \
  -X POST "${API_URL}/artifacts" \
  -H "Authorization: Bearer ${NSG_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H "X-Correlation-Id: ${CORRELATION_ID}" \
  --data "${ARTIFACT_BODY}")
ARTIFACT_ID=$(jq -er '.id' <<<"${CREATE_RESPONSE}")

FINAL_RESPONSE=
for _ in $(seq 1 60); do
  FINAL_RESPONSE=$(curl --fail-with-body --silent --show-error \
    -H "Authorization: Bearer ${NSG_TOKEN}" "${API_URL}/artifacts/${ARTIFACT_ID}")
  state=$(jq -r '.submissionState' <<<"${FINAL_RESPONSE}")
  [[ "${state}" != FAILED ]] || { echo "Artifact submission failed" >&2; exit 1; }
  [[ "${state}" != SUCCESS ]] || break
  sleep 2
done
jq -e '.submissionState == "SUCCESS" and (.blockchainTxId | type == "string" and length > 10)' \
  <<<"${FINAL_RESPONSE}" >/dev/null
TX_ID=$(jq -er '.blockchainTxId' <<<"${FINAL_RESPONSE}")

wait "${WATCHER_PID}"
WATCHER_PID=
jq -e --arg correlation "${CORRELATION_ID}" --arg artifact "${ARTIFACT_ID}" --arg tx "${TX_ID}" '
  length == 2
  and (map(.routingKey) | sort == ["artifact.submit", "artifact.submitted"])
  and (.[0:2] | all(.payload.artifactId == $artifact))
  and (map(select(.routingKey == "artifact.submit"))[0].payload.correlationId == $correlation)
  and (map(select(.routingKey == "artifact.submitted"))[0].correlationId == $correlation)
  and (map(select(.routingKey == "artifact.submitted"))[0].payload.blockchainTxId == $tx)
' "${TMP_DIR}/rabbit-boundaries.json" >/dev/null

LEDGER_HISTORY=$(curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer ${NSG_LEDGER_TOKEN}" \
  "${NSG_LEDGER_URL}/history/${ARTIFACT_ID}")
jq -e --arg artifact "${ARTIFACT_ID}" --arg tx "${TX_ID}" '
  length == 1 and .[0].transactionId == $tx
  and .[0].record.assetId == $artifact and .[0].record.revision == 1
  and .[0].record.organizationMsp == "NSGMSP"
  and .[0].record.lastTransactionId == $tx
  and .[0].record.lastCorrelationId == "usrse26-e2e-20260902-local-003"
' <<<"${LEDGER_HISTORY}" >/dev/null

cross_api_status=$(curl --silent --show-error -o "${TMP_DIR}/cross-api.json" -w '%{http_code}' \
  -H "Authorization: Bearer ${CITIZEN_TOKEN}" "${API_URL}/artifacts/${ARTIFACT_ID}")
[[ "${cross_api_status}" =~ ^4[0-9][0-9]$ ]]
cross_ledger_status=$(curl --silent --show-error -o "${TMP_DIR}/cross-ledger.json" -w '%{http_code}' \
  -H "Authorization: Bearer ${CITIZEN_LEDGER_TOKEN}" \
  "${CITIZEN_LEDGER_URL}/history/${ARTIFACT_ID}")
[[ "${cross_ledger_status}" =~ ^4[0-9][0-9]$ ]]

DB_TRACE=$(db_query "
  SELECT json_build_object(
    'artifact', json_build_object(
      'id', a.id, 'organizationId', a.\"organizationId\",
      'submissionState', a.\"submissionState\",
      'blockchainTxId', a.\"blockchainTxId\", 'peerId', a.\"peerId\"),
    'outbox', json_build_object(
      'id', o.id, 'routingKey', o.\"routingKey\", 'aggregateId', o.\"aggregateId\",
      'messageId', o.\"messageId\", 'payloadCorrelationId', o.payload->>'correlationId',
      'status', o.status, 'attempts', o.attempts,
      'createdAt', o.\"createdAt\", 'publishedAt', o.\"publishedAt\")
  )::text
  FROM artifact_entity a
  JOIN message_outbox o ON o.\"aggregateId\" = a.id::text
  WHERE a.id = '${ARTIFACT_ID}' AND o.\"messageId\" = '${CORRELATION_ID}';")
jq -e --arg artifact "${ARTIFACT_ID}" --arg correlation "${CORRELATION_ID}" --arg tx "${TX_ID}" '
  .artifact.id == $artifact and .artifact.submissionState == "SUCCESS"
  and .artifact.blockchainTxId == $tx
  and .outbox.aggregateId == $artifact and .outbox.messageId == $correlation
  and .outbox.payloadCorrelationId == $correlation
  and .outbox.routingKey == "artifact.submit" and .outbox.status == "published"
  and .outbox.attempts == 0
' <<<"${DB_TRACE}" >/dev/null

QUEUE_DEPTHS=$(kubectl -n osc-apps exec rabbitmq-0 -- rabbitmqctl -q list_queues name messages \
  | awk '$1 == "artifact.submit.queue" || $1 == "artifact.submitted.queue" {print $1, $2}' \
  | jq -Rn '[inputs | split(" ") | {queue:.[0],messages:(.[1]|tonumber)}]')
jq -e 'length == 2 and all(.messages == 0)' <<<"${QUEUE_DEPTHS}" >/dev/null

jq '{request:{correlationId:$correlation,artifactId:$artifact,organizationId:$organization},
      finalApi:{id:.id,organizationId:.organizationId,submissionState:.submissionState,
        blockchainTxId:.blockchainTxId,peerId:.peerId}}' \
  --arg correlation "${CORRELATION_ID}" --arg artifact "${ARTIFACT_ID}" --arg organization "${NSG_ID}" \
  <<<"${FINAL_RESPONSE}" >"${EVIDENCE_DIR}/api-boundaries.json"
jq . <<<"${DB_TRACE}" >"${EVIDENCE_DIR}/database-outbox.json"
jq . "${TMP_DIR}/rabbit-boundaries.json" >"${EVIDENCE_DIR}/rabbitmq-boundaries.json"
jq '[.[] | {transactionId,committedAt,deleted,record:{assetId:.record.assetId,
      organizationId:.record.organizationId,organizationMsp:.record.organizationMsp,
      revision:.record.revision,createdBy:.record.createdBy,
      lastCorrelationId:.record.lastCorrelationId,lastTransactionId:.record.lastTransactionId,
      payload:{title:.record.payload.title,visibility:.record.payload.visibility,
        footprint:.record.payload.footprint}}}]' \
  <<<"${LEDGER_HISTORY}" >"${EVIDENCE_DIR}/fabric-history.json"
jq -n --arg api "${cross_api_status}" --arg ledger "${cross_ledger_status}" \
  '{citizenScienceApiRead:{status:($api|tonumber),denied:true},
    citizenScienceFabricRead:{status:($ledger|tonumber),denied:true}}' \
  >"${EVIDENCE_DIR}/cross-organization-denial.json"
jq . <<<"${QUEUE_DEPTHS}" >"${EVIDENCE_DIR}/queue-depths-after.json"

jq -n \
  --arg correlationId "${CORRELATION_ID}" --arg artifactId "${ARTIFACT_ID}" --arg txId "${TX_ID}" \
  --argjson api "$(cat "${EVIDENCE_DIR}/api-boundaries.json")" \
  --argjson database "$(cat "${EVIDENCE_DIR}/database-outbox.json")" \
  --argjson rabbit "$(cat "${EVIDENCE_DIR}/rabbitmq-boundaries.json")" \
  --argjson fabric "$(cat "${EVIDENCE_DIR}/fabric-history.json")" \
  --argjson denial "$(cat "${EVIDENCE_DIR}/cross-organization-denial.json")" '
  {
    traceVersion:"1.0", correlationId:$correlationId, artifactId:$artifactId, fabricTransactionId:$txId,
    revisionCount:($fabric|length), duplicateLedgerRevision:false,
    boundaries:[
      {order:1,name:"authenticated API request",evidence:"api-boundaries.json",link:"direct",id:$correlationId},
      {order:2,name:"PostgreSQL artifact and transactional outbox",evidence:"database-outbox.json",link:"direct",id:$database.outbox.id},
      {order:3,name:"RabbitMQ artifact.submit command",evidence:"rabbitmq-boundaries.json",link:"direct",id:$rabbit[0].messageId},
      {order:4,name:"submission worker to organization ledger gateway",evidence:"rabbitmq-boundaries.json",link:"direct result event carrying the same correlation and returned transaction",id:$txId},
      {order:5,name:"Fabric commit and chaincode record",evidence:"fabric-history.json",link:"direct",id:$fabric[0].transactionId},
      {order:6,name:"RabbitMQ artifact.submitted completion",evidence:"rabbitmq-boundaries.json",link:"direct",id:$rabbit[1].correlationId},
      {order:7,name:"listener-applied final API state",evidence:"api-boundaries.json",link:"direct final state; listener consumption corroborated by empty completion queue",id:$api.finalApi.blockchainTxId}
    ],
    authorization:$denial,
    assertions:{singleRevision:($fabric|length == 1),transactionConsistent:($fabric[0].transactionId == $txId),
      correlationConsistent:true,outboxPublishedWithoutRetry:($database.outbox.status == "published" and $database.outbox.attempts == 0),
      credentialsRetained:false}
  }' >"${EVIDENCE_DIR}/trace-manifest.json"

(cd "${EVIDENCE_DIR}" && sha256sum \
  api-boundaries.json database-outbox.json rabbitmq-boundaries.json fabric-history.json \
  cross-organization-denial.json queue-depths-after.json trace-manifest.json \
  > checksums.sha256)
(cd "${EVIDENCE_DIR}" && sha256sum -c checksums.sha256)
jq -e '.revisionCount == 1 and .assertions.singleRevision and .assertions.transactionConsistent
  and .assertions.correlationConsistent and .assertions.outboxPublishedWithoutRetry
  and (.authorization.citizenScienceApiRead.denied)
  and (.authorization.citizenScienceFabricRead.denied)' \
  "${EVIDENCE_DIR}/trace-manifest.json" >/dev/null

echo "Correlated provenance trace passed: artifact=${ARTIFACT_ID} tx=${TX_ID} correlation=${CORRELATION_ID}"
