#!/usr/bin/env bash
set -euo pipefail

RUNTIME_SECRET_DIR="${OSC_RUNTIME_SECRET_DIR:-${PLATFORM_DIR}/.generated/runtime-secrets}"
RUNTIME_SECRET_PERMISSION_MODEL=unverified

runtime_secrets_assert_path() {
  if [[ -L "${RUNTIME_SECRET_DIR}" ]]; then
    echo "Refusing symlinked runtime secret directory: ${RUNTIME_SECRET_DIR}" >&2
    return 1
  fi
}

runtime_secrets_restrict_path() {
  local path=$1
  local mode=$2
  local windows_grant=$3
  chmod "${mode}" "${path}"
  if [[ "$(stat -c '%a' "${path}")" == "${mode}" ]]; then
    RUNTIME_SECRET_PERMISSION_MODEL=posix
    return 0
  fi

  if [[ "${path}" == /mnt/?/* ]] \
    && command -v wslpath >/dev/null \
    && command -v whoami.exe >/dev/null \
    && command -v icacls.exe >/dev/null; then
    local windows_path windows_user
    windows_path=$(wslpath -w "${path}")
    windows_user=$(whoami.exe | tr -d '\r\n')
    [[ -n "${windows_user}" ]]
    icacls.exe "${windows_path}" \
      /inheritance:r \
      /grant:r "${windows_user}:${windows_grant}" >/dev/null
    RUNTIME_SECRET_PERMISSION_MODEL=windows-acl
    return 0
  fi

  echo "Could not enforce restrictive permissions on ${path}" >&2
  return 1
}

runtime_secrets_init() {
  runtime_secrets_assert_path
  umask 077
  mkdir -p "${RUNTIME_SECRET_DIR}"
  runtime_secrets_restrict_path "${RUNTIME_SECRET_DIR}" 700 '(OI)(CI)F'

  local entry
  while IFS= read -r -d '' entry; do
    if [[ -L "${entry}" || ! -f "${entry}" ]]; then
      echo "Unexpected entry in runtime secret directory: ${entry}" >&2
      return 1
    fi
    : >"${entry}"
    rm -f -- "${entry}"
  done < <(find -P "${RUNTIME_SECRET_DIR}" -mindepth 1 -maxdepth 1 -print0)
}

runtime_secrets_verify_files() {
  runtime_secrets_assert_path
  local entry
  while IFS= read -r -d '' entry; do
    if [[ -L "${entry}" || ! -f "${entry}" ]]; then
      echo "Unexpected entry in runtime secret directory: ${entry}" >&2
      return 1
    fi
    runtime_secrets_restrict_path "${entry}" 600 F
  done < <(find -P "${RUNTIME_SECRET_DIR}" -mindepth 1 -maxdepth 1 -print0)
}

runtime_secrets_cleanup() {
  runtime_secrets_assert_path || return 1
  [[ -d "${RUNTIME_SECRET_DIR}" ]] || return 0
  local entry unexpected=0
  while IFS= read -r -d '' entry; do
    if [[ -f "${entry}" && ! -L "${entry}" ]]; then
      : >"${entry}"
      rm -f -- "${entry}"
    else
      echo "Refusing to remove unexpected runtime secret entry: ${entry}" >&2
      unexpected=1
    fi
  done < <(find -P "${RUNTIME_SECRET_DIR}" -mindepth 1 -maxdepth 1 -print0)
  [[ "${unexpected}" == 0 ]] || return 1
  rmdir "${RUNTIME_SECRET_DIR}"
}
