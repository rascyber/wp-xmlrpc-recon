#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASE_URL="${1:?base url is required}"
OUTPUT_DIR="${2:?output directory is required}"

mkdir -p "${OUTPUT_DIR}" "${PROJECT_ROOT}/wordlists/generated"

SLUG="$(slugify_target "${BASE_URL}")"
TARGET_WORDLIST="${OUTPUT_DIR}/wordlist.txt"
GLOBAL_WORDLIST="${PROJECT_ROOT}/wordlists/generated/${SLUG}.txt"
STATUS="unavailable"
WORD_COUNT=0
TARGET_HOST="$(printf '%s' "${BASE_URL}" | sed 's#^[[:alpha:]][[:alnum:]+.-]*://##; s#/.*$##; s/:.*$//')"
ENGINE="none"
CEWL_DOCKER_IMAGE="${CEWL_DOCKER_IMAGE:-ghcr.io/digininja/cewl:latest}"
OUTPUT_DIR_ABS="$(abs_path "${OUTPUT_DIR}")"
CEWL_BIN=""
CONTAINER_BIN=""
TIMEOUT_BIN=""

: > "${TARGET_WORDLIST}"
: > "${GLOBAL_WORDLIST}"

if has_command timeout; then
  TIMEOUT_BIN="timeout"
elif has_command gtimeout; then
  TIMEOUT_BIN="gtimeout"
fi

if [[ "${TARGET_HOST}" == "127.0.0.1" || "${TARGET_HOST}" == "localhost" ]]; then
  STATUS="skipped_loopback"
elif CEWL_BIN="$(tool_path cewl 2>/dev/null)" && tool_works cewl --help; then
  if [[ -n "${TIMEOUT_BIN}" ]]; then
    if "${TIMEOUT_BIN}" 60 "${CEWL_BIN}" "${BASE_URL}" -d 2 -m 5 -w "${TARGET_WORDLIST}" >/dev/null 2>&1; then
      cp "${TARGET_WORDLIST}" "${GLOBAL_WORDLIST}"
      STATUS="generated"
      ENGINE="native"
      WORD_COUNT="$(wc -l < "${TARGET_WORDLIST}" | tr -d ' ')"
    else
      STATUS="error"
    fi
  elif "${CEWL_BIN}" "${BASE_URL}" -d 2 -m 5 -w "${TARGET_WORDLIST}" >/dev/null 2>&1; then
    cp "${TARGET_WORDLIST}" "${GLOBAL_WORDLIST}"
    STATUS="generated"
    ENGINE="native"
    WORD_COUNT="$(wc -l < "${TARGET_WORDLIST}" | tr -d ' ')"
  else
    STATUS="error"
  fi
elif CONTAINER_BIN="$(container_runtime 2>/dev/null)"; then
  if "${CONTAINER_BIN}" run --rm \
    -v "${OUTPUT_DIR_ABS}:/output" \
    "${CEWL_DOCKER_IMAGE}" \
    "${BASE_URL}" -d 2 -m 5 -w /output/wordlist.txt >/dev/null 2>&1; then
    cp "${TARGET_WORDLIST}" "${GLOBAL_WORDLIST}"
    STATUS="generated"
    ENGINE="${CONTAINER_BIN}"
    WORD_COUNT="$(wc -l < "${TARGET_WORDLIST}" | tr -d ' ')"
  else
    STATUS="error"
    ENGINE="${CONTAINER_BIN}"
  fi
fi

jq -n \
  --arg base_url "${BASE_URL}" \
  --arg status "${STATUS}" \
  --arg engine "${ENGINE}" \
  --arg output_file "${TARGET_WORDLIST}" \
  --arg shared_wordlist "${GLOBAL_WORDLIST}" \
  --argjson word_count "${WORD_COUNT:-0}" \
  '{
    base_url: $base_url,
    status: $status,
    engine: $engine,
    output_file: $output_file,
    shared_wordlist: $shared_wordlist,
    word_count: $word_count
  }' > "${OUTPUT_DIR}/wordlist.json"
