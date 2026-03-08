#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET="${1:?target is required}"
OUTPUT_DIR="${2:?output directory is required}"

mkdir -p "${OUTPUT_DIR}"

TEMP_DIR="$(mktemp -d)"
SIGNALS_FILE="${TEMP_DIR}/signals.txt"
FIRST_BASE=""
ACTIVE_BASE=""
WORDPRESS_DETECTED="no"
HOME_CODE="000"
JSON_CODE="000"
LOGIN_CODE="000"

while IFS= read -r base_url; do
  [[ -z "${base_url}" ]] && continue
  [[ -z "${FIRST_BASE}" ]] && FIRST_BASE="${base_url}"

  HOME_BODY="${TEMP_DIR}/home.html"
  HOME_HEADERS="${TEMP_DIR}/home.headers"
  JSON_BODY="${TEMP_DIR}/wp-json.json"
  JSON_HEADERS="${TEMP_DIR}/wp-json.headers"
  LOGIN_BODY="${TEMP_DIR}/login.html"
  LOGIN_HEADERS="${TEMP_DIR}/login.headers"
  CONTENT_BODY="${TEMP_DIR}/wp-content.html"
  CONTENT_HEADERS="${TEMP_DIR}/wp-content.headers"

  HOME_CODE="$(http_request GET "${base_url}/" "${HOME_BODY}" "${HOME_HEADERS}" || true)"
  JSON_CODE="$(http_request GET "${base_url}/wp-json" "${JSON_BODY}" "${JSON_HEADERS}" || true)"
  LOGIN_CODE="$(http_request GET "${base_url}/wp-login.php" "${LOGIN_BODY}" "${LOGIN_HEADERS}" || true)"
  CONTENT_CODE="$(http_request GET "${base_url}/wp-content/" "${CONTENT_BODY}" "${CONTENT_HEADERS}" || true)"

  if grep -Eqi 'wp-content|wp-includes|generator[^>]*wordpress' "${HOME_BODY}" 2>/dev/null; then
    append_unique_line "homepage markers" "${SIGNALS_FILE}"
  fi

  if [[ "${JSON_CODE}" == "200" ]] && grep -q '"routes"' "${JSON_BODY}" 2>/dev/null; then
    append_unique_line "wp-json endpoint" "${SIGNALS_FILE}"
  fi

  if [[ "${LOGIN_CODE}" == "200" ]] && grep -Eqi 'wp-submit|user_login|wp-login' "${LOGIN_BODY}" 2>/dev/null; then
    append_unique_line "login page markers" "${SIGNALS_FILE}"
  fi

  case "${CONTENT_CODE}" in
    200|301|302|401|403) append_unique_line "wp-content path" "${SIGNALS_FILE}" ;;
  esac

  if [[ -s "${SIGNALS_FILE}" ]]; then
    ACTIVE_BASE="${base_url}"
    WORDPRESS_DETECTED="yes"
    break
  fi
done <<EOF
$(candidate_base_urls "${TARGET}")
EOF

if [[ -z "${ACTIVE_BASE}" ]]; then
  ACTIVE_BASE="${FIRST_BASE}"
fi

SIGNALS_JSON="$(json_array_from_lines_file "${SIGNALS_FILE}")"

jq -n \
  --arg target "${TARGET}" \
  --arg base_url "${ACTIVE_BASE}" \
  --arg wordpress_detected "${WORDPRESS_DETECTED}" \
  --arg home_status "${HOME_CODE}" \
  --arg wp_json_status "${JSON_CODE}" \
  --arg login_status "${LOGIN_CODE}" \
  --argjson signals "${SIGNALS_JSON}" \
  '{
    target: $target,
    base_url: $base_url,
    wordpress_detected: $wordpress_detected,
    signals: $signals,
    http_status: {
      home: $home_status,
      wp_json: $wp_json_status,
      wp_login: $login_status
    }
  }' > "${OUTPUT_DIR}/wordpress_detection.json"
