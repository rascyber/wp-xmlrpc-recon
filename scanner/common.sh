#!/usr/bin/env bash

REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-10}"
REQUEST_DELAY="${REQUEST_DELAY:-0}"
USER_AGENT="${USER_AGENT:-wp-attack-surface-scanner/2.0}"
COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_PROJECT_ROOT="$(cd "${COMMON_SCRIPT_DIR}/.." && pwd)"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Missing required dependency: %s\n' "${command_name}" >&2
    exit 1
  fi
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

tool_path() {
  local tool_name="$1"
  local candidate=""

  for candidate in \
    "${COMMON_PROJECT_ROOT}/tools/bin/${tool_name}" \
    "${COMMON_PROJECT_ROOT}/.tools/bin/${tool_name}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  if command -v "${tool_name}" >/dev/null 2>&1; then
    command -v "${tool_name}"
    return 0
  fi

  return 1
}

command_works() {
  local command_name="$1"
  shift || true
  "${command_name}" "$@" >/dev/null 2>&1
}

tool_works() {
  local tool_name="$1"
  local tool_bin=""
  shift || true

  if ! tool_bin="$(tool_path "${tool_name}")"; then
    return 1
  fi

  "${tool_bin}" "$@" >/dev/null 2>&1
}

container_runtime() {
  if has_command docker && command_works docker info; then
    printf 'docker\n'
    return 0
  fi

  if has_command podman && command_works podman info; then
    printf 'podman\n'
    return 0
  fi

  return 1
}

docker_available() {
  container_runtime >/dev/null 2>&1
}

trim_line() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

strip_trailing_slash() {
  local value="$1"
  while [[ "${value}" == */ ]]; do
    value="${value%/}"
  done
  printf '%s' "${value}"
}

ensure_scheme() {
  local target="$1"
  if [[ "${target}" == http://* || "${target}" == https://* ]]; then
    printf '%s\n' "$(strip_trailing_slash "${target}")"
  else
    printf 'https://%s\n' "$(strip_trailing_slash "${target}")"
  fi
}

candidate_base_urls() {
  local target="$1"
  target="$(trim_line "${target}")"

  if [[ "${target}" == http://* || "${target}" == https://* ]]; then
    printf '%s\n' "$(strip_trailing_slash "${target}")"
    return
  fi

  printf 'https://%s\n' "$(strip_trailing_slash "${target}")"
  printf 'http://%s\n' "$(strip_trailing_slash "${target}")"
}

slugify_target() {
  local target="$1"
  target="$(printf '%s' "${target}" | sed 's#^[[:alpha:]][[:alnum:]+.-]*://##')"
  target="$(printf '%s' "${target}" | sed 's#[/?&=:#]#_#g')"
  target="$(printf '%s' "${target}" | tr '[:upper:]' '[:lower:]')"
  target="$(printf '%s' "${target}" | sed 's/[^a-z0-9._-]/_/g; s/__\+/_/g; s/^_//; s/_$//')"
  printf '%s' "${target}"
}

append_unique_line() {
  local value="$1"
  local file="$2"
  [[ -z "${value}" ]] && return 0
  touch "${file}"
  if ! grep -Fxq "${value}" "${file}" 2>/dev/null; then
    printf '%s\n' "${value}" >> "${file}"
  fi
}

json_array_from_lines_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    jq -R -s 'split("\n") | map(select(length > 0))' "${file}"
  else
    printf '[]'
  fi
}

html_escape() {
  local value="$1"
  printf '%s' "${value}" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&#39;/g"
}

abs_path() {
  local target="$1"
  local target_dir=""
  local target_file=""

  target_dir="$(cd "$(dirname "${target}")" && pwd)"
  target_file="$(basename "${target}")"
  printf '%s/%s' "${target_dir}" "${target_file}"
}

http_request() {
  local method="$1"
  local url="$2"
  local body_file="$3"
  local header_file="$4"
  local data="${5:-}"
  local content_type="${6:-}"
  local http_code=""
  local delay="${REQUEST_DELAY}"
  local -a curl_args

  if [[ "${delay}" != "0" && "${delay}" != "0.0" ]]; then
    sleep "${delay}"
  fi

  curl_args=(
    --silent
    --show-error
    --location
    --max-time "${REQUEST_TIMEOUT}"
    --user-agent "${USER_AGENT}"
    --request "${method}"
    --output "${body_file}"
    --dump-header "${header_file}"
    --write-out '%{http_code}'
  )

  if [[ -n "${content_type}" ]]; then
    curl_args+=(--header "Content-Type: ${content_type}")
  fi

  if [[ -n "${data}" ]]; then
    curl_args+=(--data "${data}")
  fi

  if http_code="$(curl "${curl_args[@]}" "${url}")"; then
    printf '%s' "${http_code}"
    return 0
  fi

  printf '000'
  return 1
}
