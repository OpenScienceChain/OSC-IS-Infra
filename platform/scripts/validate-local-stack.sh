#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
EVIDENCE_DIR="${PLATFORM_DIR}/.generated/evidence/local-stack"
API_URL=http://127.0.0.1:13000/api/v1
LEDGER_URL=http://127.0.0.1:14001
NSG_ID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
CITIZEN_ID=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
TMP_DIR=$(mktemp -d)
PORT_FORWARD_PIDS=()

on_error() {
  local line=$1
  echo "Local stack validation failed at line ${line}."
  for log in "${TMP_DIR}"/*-forward.log; do
    [[ -f "${log}" ]] && tail -n 10 "${log}"
  done
}

cleanup() {
  local pid
  for pid in "${PORT_FORWARD_PIDS[@]:-}"; do
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  rm -rf "${TMP_DIR}"
}
trap 'on_error ${LINENO}' ERR
trap cleanup EXIT

if ! kubectl config current-context | grep -Fxq kind-osc-usrse26-infra; then
  echo "Refusing to validate outside kind-osc-usrse26-infra"
  exit 1
fi
for command in curl jq base64; do
  command -v "${command}" >/dev/null || { echo "Missing required command: ${command}"; exit 1; }
done

mkdir -p "${EVIDENCE_DIR}"
PASSWORD=$(kubectl -n osc-apps get secret e2e-user-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
LEDGER_TOKEN=$(kubectl -n osc-apps get secret ledger-gateway-nsg-auth \
  -o jsonpath='{.data.token}' | base64 -d)

kubectl -n osc-apps port-forward service/api-gateway 13000:3000 \
  --address 127.0.0.1 >"${TMP_DIR}/api-forward.log" 2>&1 &
PORT_FORWARD_PIDS+=("$!")
kubectl -n osc-apps port-forward service/ledger-gateway-nsg 14001:4000 \
  --address 127.0.0.1 >"${TMP_DIR}/ledger-forward.log" 2>&1 &
PORT_FORWARD_PIDS+=("$!")

for _ in $(seq 1 30); do
  if curl --fail --silent "${API_URL}/health" >/dev/null \
    && curl --fail --silent "${LEDGER_URL}/health" >/dev/null; then
    break
  fi
  sleep 1
done
curl --fail --silent "${API_URL}/health" >/dev/null
curl --fail --silent "${LEDGER_URL}/health" >/dev/null

login() {
  local username=$1 organization_id=$2 response
  response=$(curl --fail-with-body --silent --show-error \
    -X POST "${API_URL}/users/login" \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc \
      --arg username "${username}" \
      --arg password "${PASSWORD}" \
      --arg organizationId "${organization_id}" \
      '{username: $username, password: $password, organizationId: $organizationId}')")
  jq -er '.token' <<<"${response}"
}

expect_status() {
  local expected_pattern=$1 method=$2 url=$3 token=${4:-} body=${5:-}
  local args=(-sS -o "${TMP_DIR}/response.json" -w '%{http_code}' -X "${method}" "${url}")
  [[ -z "${token}" ]] || args+=(-H "Authorization: Bearer ${token}")
  if [[ -n "${body}" ]]; then
    args+=(-H 'Content-Type: application/json' --data "${body}")
  fi
  local status
  status=$(curl "${args[@]}")
  if [[ ! "${status}" =~ ${expected_pattern} ]]; then
    echo "Expected HTTP ${expected_pattern}, got ${status} from ${method} ${url}"
    jq . "${TMP_DIR}/response.json" 2>/dev/null || cat "${TMP_DIR}/response.json"
    exit 1
  fi
  printf '%s' "${status}"
}

wait_for_success() {
  local resource=$1 id=$2 token=$3 response state
  for _ in $(seq 1 60); do
    response=$(curl --fail-with-body --silent --show-error \
      -H "Authorization: Bearer ${token}" "${API_URL}/${resource}/${id}")
    state=$(jq -r '.submissionState' <<<"${response}")
    if [[ "${state}" == SUCCESS ]]; then
      jq -e '.blockchainTxId | type == "string" and length > 10' <<<"${response}" >/dev/null
      printf '%s' "${response}"
      return 0
    fi
    if [[ "${state}" == FAILED ]]; then
      echo "${resource}/${id} reached FAILED"
      jq . <<<"${response}"
      return 1
    fi
    sleep 2
  done
  echo "Timed out waiting for ${resource}/${id}"
  return 1
}

# A multi-organization user must choose an active context.
cross_org_without_context=$(expect_status '^401$' POST "${API_URL}/users/login" '' \
  "$(jq -nc --arg username cross-org --arg password "${PASSWORD}" \
    '{username: $username, password: $password}')")

NSG_TOKEN=$(login nsg-pi "${NSG_ID}")
CITIZEN_TOKEN=$(login citizen-contributor "${CITIZEN_ID}")
CROSS_NSG_TOKEN=$(login cross-org "${NSG_ID}")
CROSS_CITIZEN_TOKEN=$(login cross-org "${CITIZEN_ID}")
COLLABORATOR_TOKEN=$(login nsg-collaborator "${NSG_ID}")

# Caller-supplied tenancy fields are rejected before persistence.
undeclared_field_status=$(expect_status '^400$' POST "${API_URL}/artifacts" "${NSG_TOKEN}" \
  "$(jq -nc --arg organizationId "${CITIZEN_ID}" '{
    title: "Rejected caller tenancy", description: "This intentionally invalid request proves that tenancy cannot be selected through an artifact body.",
    visibility: "private", keywords: [], links: [], dois: [], fundingAgencies: [], acknowledgements: "",
    manifest: [{filename: "invalid.txt", hash: ("0" * 64), algorithm: "sha256"}], footprint: ("1" * 64),
    submission_comment: "This request must be rejected before persistence.", organizationId: $organizationId
  }')")

RUN_ID=$(date -u +%Y%m%d%H%M%S)
ARTIFACT_BODY=$(jq -nc --arg run "${RUN_ID}" '{
  title: ("USRSE evidence artifact " + $run),
  description: "A deterministic microscopy result used to validate provenance, organization isolation, and asynchronous delivery through the complete OSC-IS stack.",
  visibility: "private", keywords: ["usrse26", "provenance"],
  links: ["https://example.invalid/research/usrse26"], dois: [], fundingAgencies: ["NSF"],
  acknowledgements: "Generated only for a disposable local evidence run.",
  manifest: [{filename: "result.csv", hash: ("a" * 64), algorithm: "sha256"}],
  footprint: ("b" * 64), submission_comment: "Initial deterministic evidence submission for the US-RSE architecture demonstration."
}')
ARTIFACT_CREATE=$(curl --fail-with-body --silent --show-error \
  -X POST "${API_URL}/artifacts" \
  -H "Authorization: Bearer ${NSG_TOKEN}" -H 'Content-Type: application/json' \
  -H "X-Correlation-Id: usrse-artifact-${RUN_ID}" --data "${ARTIFACT_BODY}")
ARTIFACT_ID=$(jq -er '.id' <<<"${ARTIFACT_CREATE}")
ARTIFACT_RESULT=$(wait_for_success artifacts "${ARTIFACT_ID}" "${NSG_TOKEN}")

cross_org_read_status=$(expect_status '^4[0-9][0-9]$' GET \
  "${API_URL}/artifacts/${ARTIFACT_ID}" "${CITIZEN_TOKEN}")
cross_org_write_status=$(expect_status '^4[0-9][0-9]$' PUT \
  "${API_URL}/artifacts/${ARTIFACT_ID}" "${CITIZEN_TOKEN}" \
  '{"submission_comment":"A cross-organization write attempt that must be denied."}')
collaborator_admin_status=$(expect_status '^403$' POST "${API_URL}/users/register" \
  "${COLLABORATOR_TOKEN}" \
  '{"name":"Unauthorized User","username":"unauthorized-user","email":"unauthorized@example.invalid","password":"NotARealPassword123!","roles":["collaborator"]}')

UPDATE_BODY='{"submission_comment":"A second revision proves chronological, append-only provenance history.","keywords":["usrse26","provenance","revision-two"]}'
curl --fail-with-body --silent --show-error -X PUT \
  "${API_URL}/artifacts/${ARTIFACT_ID}" \
  -H "Authorization: Bearer ${NSG_TOKEN}" -H 'Content-Type: application/json' \
  -H "X-Correlation-Id: usrse-artifact-update-${RUN_ID}" --data "${UPDATE_BODY}" >/dev/null
ARTIFACT_UPDATED=$(wait_for_success artifacts "${ARTIFACT_ID}" "${NSG_TOKEN}")

WORKFLOW_BODY=$(jq -nc --arg run "${RUN_ID}" --arg artifactId "${ARTIFACT_ID}" '{
  title: ("USRSE evidence workflow " + $run),
  description: "A versioned analysis workflow that demonstrates how OSC-IS connects reproducible computational steps to a preserved research artifact.",
  visibility: "private", keywords: ["usrse26", "workflow"],
  githubRepositories: [{url: "https://github.com/OpenScienceChain/OSC-IS-Infra", description: "Evidence infrastructure", gitHash: "local-evidence"}],
  artifactIds: [$artifactId], submission_comment: "Connect the validated artifact to its reproducible analysis workflow."
}')
WORKFLOW_CREATE=$(curl --fail-with-body --silent --show-error \
  -X POST "${API_URL}/workflows" \
  -H "Authorization: Bearer ${NSG_TOKEN}" -H 'Content-Type: application/json' \
  -H "X-Correlation-Id: usrse-workflow-${RUN_ID}" --data "${WORKFLOW_BODY}")
WORKFLOW_ID=$(jq -er '.id' <<<"${WORKFLOW_CREATE}")
WORKFLOW_RESULT=$(wait_for_success workflows "${WORKFLOW_ID}" "${NSG_TOKEN}")

ARTIFACT_HISTORY=$(curl --silent --show-error \
  -H "Authorization: Bearer ${LEDGER_TOKEN}" "${LEDGER_URL}/history/${ARTIFACT_ID}")
WORKFLOW_HISTORY=$(curl --silent --show-error \
  -H "Authorization: Bearer ${LEDGER_TOKEN}" "${LEDGER_URL}/workflow/history/${WORKFLOW_ID}")
if ! jq -e 'type == "array"' <<<"${ARTIFACT_HISTORY}" >/dev/null; then
  echo "Artifact ledger history read failed:"
  jq . <<<"${ARTIFACT_HISTORY}"
  exit 1
fi
if ! jq -e 'type == "array"' <<<"${WORKFLOW_HISTORY}" >/dev/null; then
  echo "Workflow ledger history read failed:"
  jq . <<<"${WORKFLOW_HISTORY}"
  exit 1
fi
jq -e 'length == 2 and .[0].record.revision == 1 and .[1].record.revision == 2' \
  <<<"${ARTIFACT_HISTORY}" >/dev/null
jq -e 'length == 1 and .[0].record.revision == 1' <<<"${WORKFLOW_HISTORY}" >/dev/null

# Decode only non-secret JWT claims, proving that a token carries one active org.
jwt_claims() {
  local payload padding
  payload=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  padding=$(( (4 - ${#payload} % 4) % 4 ))
  payload+=$(printf '=%.0s' $(seq 1 "${padding}"))
  printf '%s' "${payload}" | base64 -d 2>/dev/null
}
NSG_CLAIMS=$(jwt_claims "${CROSS_NSG_TOKEN}")
CITIZEN_CLAIMS=$(jwt_claims "${CROSS_CITIZEN_TOKEN}")
jq -e --arg id "${NSG_ID}" '.organizationId == $id and .roles == ["collaborator"]' <<<"${NSG_CLAIMS}" >/dev/null
jq -e --arg id "${CITIZEN_ID}" '.organizationId == $id and .roles == ["collaborator"]' <<<"${CITIZEN_CLAIMS}" >/dev/null

jq -n \
  --arg runId "${RUN_ID}" \
  --arg artifactId "${ARTIFACT_ID}" \
  --arg artifactTxId "$(jq -r '.blockchainTxId' <<<"${ARTIFACT_UPDATED}")" \
  --arg workflowId "${WORKFLOW_ID}" \
  --arg workflowTxId "$(jq -r '.blockchainTxId' <<<"${WORKFLOW_RESULT}")" \
  --argjson artifactRevisions "$(jq 'length' <<<"${ARTIFACT_HISTORY}")" \
  --argjson workflowRevisions "$(jq 'length' <<<"${WORKFLOW_HISTORY}")" \
  --arg crossOrgWithoutContext "${cross_org_without_context}" \
  --arg undeclaredField "${undeclared_field_status}" \
  --arg crossOrgRead "${cross_org_read_status}" \
  --arg crossOrgWrite "${cross_org_write_status}" \
  --arg collaboratorAdmin "${collaborator_admin_status}" \
  '{
    testRun: $runId,
    organizations: [
      {name: "nEUROSCIENCE GATEWAY", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", mspId: "NSGMSP"},
      {name: "CITIZEN SCIENCE", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", mspId: "CitizenScienceMSP"}
    ],
    artifact: {id: $artifactId, finalTransactionId: $artifactTxId, revisions: $artifactRevisions},
    workflow: {id: $workflowId, transactionId: $workflowTxId, revisions: $workflowRevisions},
    authorization: {
      multiOrgSelectionRequired: ($crossOrgWithoutContext == "401"),
      callerTenancyFieldRejected: ($undeclaredField == "400"),
      crossOrgReadDenied: ($crossOrgRead | startswith("4")),
      crossOrgWriteDenied: ($crossOrgWrite | startswith("4")),
      collaboratorAdminDenied: ($collaboratorAdmin == "403"),
      activeOrganizationClaimsVerified: true
    },
    credentialsRetained: false
  }' | tee "${EVIDENCE_DIR}/summary.json"

echo "Local end-to-end provenance and authorization validation passed."
