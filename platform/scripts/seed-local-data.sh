#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/runtime-secrets.sh"
runtime_secrets_init
trap runtime_secrets_cleanup EXIT
SECRET_DIR="${RUNTIME_SECRET_DIR}"
PASSWORD_FILE="${SECRET_DIR}/e2e-password"
API_IMAGE=${API_IMAGE:-localhost:5017/osc-api-gateway@sha256:917bd71bd7c1906ae4af22c90468ddd2ac00008dfeb9c5241a7ddf7b8308603d}

PASSWORD=$(openssl rand -base64 24 | tr -d '\r\n')
printf '%s' "${PASSWORD}" > "${PASSWORD_FILE}"
runtime_secrets_verify_files

PASSWORD_HASH=$(docker run --rm -i --entrypoint node "${API_IMAGE}" -e '
  const bcrypt = require("bcrypt");
  let value = "";
  process.stdin.on("data", chunk => value += chunk);
  process.stdin.on("end", async () => process.stdout.write(await bcrypt.hash(value.trim(), 12)));
' < "${PASSWORD_FILE}")

kubectl -n osc-apps exec -i statefulset/postgres -- \
  psql -v ON_ERROR_STOP=1 -U osc_app -d osc_is -v password_hash="${PASSWORD_HASH}" \
  < "${SCRIPT_DIR}/seed-local-data.sql" >/dev/null

kubectl -n osc-apps create secret generic e2e-user-credentials \
  --from-literal=nsg-admin=nsg-admin \
  --from-literal=nsg-pi=nsg-pi \
  --from-literal=nsg-collaborator=nsg-collaborator \
  --from-literal=citizen-admin=citizen-admin \
  --from-literal=citizen-contributor=citizen-contributor \
  --from-literal=cross-org=cross-org \
  --from-file=password="${PASSWORD_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n osc-apps exec deployment/api-gateway -- node -e '
  const now = Date.now();
  fetch("http://127.0.0.1:3000/api/v1/demo/internal/status", {
    method: "PUT",
    headers: {
      "Content-Type": "application/json",
      "X-Demo-Control-Key": process.env.DEMO_CONTROL_API_KEY
    },
    body: JSON.stringify({
      state: "OPEN",
      runId: "local-kind",
      opensAt: new Date(now - 60_000).toISOString(),
      closesAt: new Date(now + 86_400_000).toISOString()
    })
  }).then(async response => {
    if (!response.ok) throw new Error(`demo status ${response.status}`);
  }).catch(error => { console.error(error.message); process.exit(1); });
'

echo "Deterministic organizations, users, memberships, and the local OPEN demo state are seeded; credentials remain in Kubernetes Secrets."
