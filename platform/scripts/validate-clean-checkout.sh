#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${PLATFORM_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/runtime-secrets.sh"

cleanup() {
  runtime_secrets_cleanup 2>/dev/null || true
}
trap cleanup EXIT

grep -Fxq '*.sh text eol=lf' "${ROOT_DIR}/.gitattributes"
grep -Fxq 'platform/versions.env text eol=lf' "${ROOT_DIR}/.gitattributes"

while IFS= read -r -d '' path; do
  relative_path="${path#"${ROOT_DIR}/"}"
  if LC_ALL=C grep -q $'\r' "${path}"; then
    echo "CR byte found in Linux input: ${relative_path}" >&2
    exit 1
  fi
  bash -n "${path}"
done < <(
  find "${ROOT_DIR}" \
    -path "${PLATFORM_DIR}/.generated" -prune -o \
    -type f -name '*.sh' -print0
)

if LC_ALL=C grep -q $'\r' "${PLATFORM_DIR}/versions.env"; then
  echo "CR byte found in Linux input: platform/versions.env" >&2
  exit 1
fi
(
  # shellcheck source=../versions.env
  source "${PLATFORM_DIR}/versions.env"
  : "${KIND_VERSION:?KIND_VERSION was not loaded}"
)

runtime_secrets_init
[[ -d "${RUNTIME_SECRET_DIR}" ]]
[[ "${RUNTIME_SECRET_PERMISSION_MODEL}" =~ ^(posix|windows-acl)$ ]]
printf '%s' 'permission-sentinel' >"${RUNTIME_SECRET_DIR}/sentinel"
runtime_secrets_verify_files
[[ "${RUNTIME_SECRET_PERMISSION_MODEL}" =~ ^(posix|windows-acl)$ ]]

# A repeated bootstrap removes stale local material before creating new files.
runtime_secrets_init
[[ ! -e "${RUNTIME_SECRET_DIR}/sentinel" ]]
printf '%s' 'cleanup-sentinel' >"${RUNTIME_SECRET_DIR}/sentinel"
runtime_secrets_verify_files
runtime_secrets_cleanup
trap - EXIT
[[ ! -e "${RUNTIME_SECRET_DIR}" ]]

set +e
(
  set -e
  runtime_secrets_init
  trap runtime_secrets_cleanup EXIT
  printf '%s' 'error-cleanup-sentinel' >"${RUNTIME_SECRET_DIR}/sentinel"
  runtime_secrets_verify_files
  false
)
failure_status=$?
set -e
[[ "${failure_status}" -ne 0 ]]
[[ ! -e "${RUNTIME_SECRET_DIR}" ]]

echo "Clean-checkout line-ending and transient-secret validation passed."
