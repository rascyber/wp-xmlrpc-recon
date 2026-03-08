#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASE_URL="${1:?base url is required}"
OUTPUT_DIR="${2:?output directory is required}"

mkdir -p "${OUTPUT_DIR}"

TEMP_DIR="$(mktemp -d)"
ROOT_BODY="${TEMP_DIR}/root.json"
ROOT_HEADERS="${TEMP_DIR}/root.headers"
USERS_BODY="${TEMP_DIR}/users.json"
USERS_HEADERS="${TEMP_DIR}/users.headers"
POSTS_BODY="${TEMP_DIR}/posts.json"
POSTS_HEADERS="${TEMP_DIR}/posts.headers"

ROOT_CODE="$(http_request GET "${BASE_URL}/wp-json" "${ROOT_BODY}" "${ROOT_HEADERS}" || true)"
USERS_CODE="$(http_request GET "${BASE_URL}/wp-json/wp/v2/users" "${USERS_BODY}" "${USERS_HEADERS}" || true)"
POSTS_CODE="$(http_request GET "${BASE_URL}/wp-json/wp/v2/posts" "${POSTS_BODY}" "${POSTS_HEADERS}" || true)"

if [[ "${ROOT_CODE}" == "200" ]]; then
  jq -r '.namespaces[]?' "${ROOT_BODY}" 2>/dev/null > "${TEMP_DIR}/namespaces.txt" || true
  jq -r '.routes | keys[]?' "${ROOT_BODY}" 2>/dev/null > "${TEMP_DIR}/routes.txt" || true
else
  : > "${TEMP_DIR}/namespaces.txt"
  : > "${TEMP_DIR}/routes.txt"
fi

CUSTOM_ENDPOINTS_JSON="$(jq -R -s 'split("\n") | map(select(length > 0)) | map(select((startswith("/wp/v2/") | not) and (startswith("/oembed/") | not)))' "${TEMP_DIR}/routes.txt")"
NAMESPACES_JSON="$(json_array_from_lines_file "${TEMP_DIR}/namespaces.txt")"
USERS_EXPOSED="no"
POSTS_EXPOSED="no"
DRAFTS_EXPOSED="no"

if [[ "${USERS_CODE}" == "200" ]] && jq -e 'type == "array" and length > 0' "${USERS_BODY}" >/dev/null 2>&1; then
  USERS_EXPOSED="yes"
fi

if [[ "${POSTS_CODE}" == "200" ]] && jq -e 'type == "array" and length > 0' "${POSTS_BODY}" >/dev/null 2>&1; then
  POSTS_EXPOSED="yes"
fi

if [[ "${POSTS_CODE}" == "200" ]] && jq -e 'type == "array" and any(.[]?; (.status // "") == "draft")' "${POSTS_BODY}" >/dev/null 2>&1; then
  DRAFTS_EXPOSED="yes"
fi

jq -n \
  --arg base_url "${BASE_URL}" \
  --arg root_status "${ROOT_CODE}" \
  --arg users_status "${USERS_CODE}" \
  --arg posts_status "${POSTS_CODE}" \
  --arg users_exposed "${USERS_EXPOSED}" \
  --arg posts_exposed "${POSTS_EXPOSED}" \
  --arg drafts_exposed "${DRAFTS_EXPOSED}" \
  --argjson namespaces "${NAMESPACES_JSON}" \
  --argjson custom_endpoints "${CUSTOM_ENDPOINTS_JSON}" \
  '{
    base_url: $base_url,
    endpoints: {
      root: $root_status,
      users: $users_status,
      posts: $posts_status
    },
    users_exposed: $users_exposed,
    posts_exposed: $posts_exposed,
    drafts_exposed: $drafts_exposed,
    namespaces: $namespaces,
    custom_endpoints: $custom_endpoints
  }' > "${OUTPUT_DIR}/rest_endpoints.json"
