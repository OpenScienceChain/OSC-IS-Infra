#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SECRET_DIR="${PLATFORM_DIR}/.generated/runtime-secrets"
PASSWORD_FILE="${SECRET_DIR}/e2e-password"
API_IMAGE=localhost:5017/osc-api-gateway@sha256:917bd71bd7c1906ae4af22c90468ddd2ac00008dfeb9c5241a7ddf7b8308603d

umask 077
if [[ -s "${PASSWORD_FILE}" ]]; then
  PASSWORD=$(tr -d '\r\n' < "${PASSWORD_FILE}")
else
  PASSWORD=$(openssl rand -base64 24 | tr -d '\r\n')
fi
printf '%s' "${PASSWORD}" > "${PASSWORD_FILE}"

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

echo "Deterministic organizations, users, and memberships are seeded; credentials remain in a Kubernetes Secret."
