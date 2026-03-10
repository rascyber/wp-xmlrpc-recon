#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASE_URL="${1:?base url is required}"
OUTPUT_DIR="${2:?output directory is required}"

mkdir -p "${OUTPUT_DIR}"

TEMP_DIR="$(mktemp -d)"
LOGIN_BODY="${TEMP_DIR}/login.html"
LOGIN_HEADERS="${TEMP_DIR}/login.headers"
POST_BODY="${TEMP_DIR}/login_post.html"
POST_HEADERS="${TEMP_DIR}/login_post.headers"
ADMIN_BODY="${TEMP_DIR}/admin.html"
ADMIN_HEADERS="${TEMP_DIR}/admin.headers"

LOGIN_CODE="$(http_request GET "${BASE_URL}/wp-login.php" "${LOGIN_BODY}" "${LOGIN_HEADERS}" || true)"
POST_CODE="$(http_request POST "${BASE_URL}/wp-login.php" "${POST_BODY}" "${POST_HEADERS}" 'log=invalid-user&pwd=invalid-pass&wp-submit=Log+In' 'application/x-www-form-urlencoded' || true)"
ADMIN_CODE="$(http_request GET "${BASE_URL}/wp-admin/" "${ADMIN_BODY}" "${ADMIN_HEADERS}" || true)"

LOGIN_PRESENT="no"
ERROR_RESPONSE="no"
RATE_LIMITING="no"
ADMIN_ENDPOINT="no"
LOGIN_PATHS='[]'

if [[ "${LOGIN_CODE}" == "200" ]] && grep -Eqi 'wp-submit|user_login|wp-login' "${LOGIN_BODY}" 2>/dev/null; then
  LOGIN_PRESENT="yes"
fi

case "${ADMIN_CODE}" in
  200|301|302|401|403) ADMIN_ENDPOINT="yes" ;;
esac

if [[ "${POST_CODE}" == "200" || "${POST_CODE}" == "302" ]] && grep -Eqi 'login_error|incorrect|invalid username|try again' "${POST_BODY}" 2>/dev/null; then
  ERROR_RESPONSE="yes"
fi

if grep -Eqi 'retry-after|x-ratelimit|too many|slow down' "${POST_HEADERS}" "${POST_BODY}" 2>/dev/null; then
  RATE_LIMITING="yes"
fi

LOGIN_PATHS="$(jq -n \
  --arg login_present "${LOGIN_PRESENT}" \
  --arg admin_present "${ADMIN_ENDPOINT}" \
  '[
    if $login_present == "yes" then "/wp-login.php" else empty end,
    if $admin_present == "yes" then "/wp-admin/" else empty end
  ]')"

jq -n \
  --arg base_url "${BASE_URL}" \
  --arg login_status "${LOGIN_CODE}" \
  --arg login_page_present "${LOGIN_PRESENT}" \
  --arg invalid_login_response "${ERROR_RESPONSE}" \
  --arg rate_limiting_signals "${RATE_LIMITING}" \
  --arg wp_admin_endpoint "${ADMIN_ENDPOINT}" \
  --arg admin_status "${ADMIN_CODE}" \
  --argjson login_paths "${LOGIN_PATHS}" \
  '{
    base_url: $base_url,
    login_status: $login_status,
    login_page_present: $login_page_present,
    invalid_login_response: $invalid_login_response,
    rate_limiting_signals: $rate_limiting_signals,
    wp_admin_endpoint: $wp_admin_endpoint,
    wp_admin_status: $admin_status,
    login_paths: $login_paths
  }' > "${OUTPUT_DIR}/login_surface.json"
