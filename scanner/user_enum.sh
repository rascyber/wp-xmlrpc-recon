#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASE_URL="${1:?base url is required}"
OUTPUT_DIR="${2:?output directory is required}"

mkdir -p "${OUTPUT_DIR}"

TEMP_DIR="$(mktemp -d)"
USERS_FILE="${OUTPUT_DIR}/users.txt"
: > "${USERS_FILE}"
REST_USERS_FILE="${TEMP_DIR}/rest_users.txt"
AUTHOR_ARCHIVE_FILE="${TEMP_DIR}/author_archives.txt"
SITEMAP_AUTHORS_FILE="${TEMP_DIR}/sitemap_authors.txt"
FEED_AUTHORS_FILE="${TEMP_DIR}/feed_authors.txt"
: > "${REST_USERS_FILE}"
: > "${AUTHOR_ARCHIVE_FILE}"
: > "${SITEMAP_AUTHORS_FILE}"
: > "${FEED_AUTHORS_FILE}"

REST_BODY="${TEMP_DIR}/users.json"
REST_HEADERS="${TEMP_DIR}/users.headers"
HOME_BODY="${TEMP_DIR}/home.html"
HOME_HEADERS="${TEMP_DIR}/home.headers"
SITEMAP_BODY="${TEMP_DIR}/sitemap.xml"
SITEMAP_HEADERS="${TEMP_DIR}/sitemap.headers"
FEED_BODY="${TEMP_DIR}/feed.xml"
FEED_HEADERS="${TEMP_DIR}/feed.headers"

REST_CODE="$(http_request GET "${BASE_URL}/wp-json/wp/v2/users" "${REST_BODY}" "${REST_HEADERS}" || true)"
http_request GET "${BASE_URL}/" "${HOME_BODY}" "${HOME_HEADERS}" >/dev/null || true
SITEMAP_CODE="$(http_request GET "${BASE_URL}/wp-sitemap-users-1.xml" "${SITEMAP_BODY}" "${SITEMAP_HEADERS}" || true)"
FEED_CODE="$(http_request GET "${BASE_URL}/feed" "${FEED_BODY}" "${FEED_HEADERS}" || true)"

if [[ "${REST_CODE}" == "200" ]]; then
  jq -r '.[]? | (.slug // .name // empty)' "${REST_BODY}" 2>/dev/null | while IFS= read -r user_value; do
    append_unique_line "${user_value}" "${REST_USERS_FILE}"
    append_unique_line "${user_value}" "${USERS_FILE}"
  done || true
fi

grep -Eo '/author/[A-Za-z0-9._-]+/?' "${HOME_BODY}" 2>/dev/null | sed 's#^/author/##; s#/$##' | while IFS= read -r user_value; do
  append_unique_line "${user_value}" "${AUTHOR_ARCHIVE_FILE}"
  append_unique_line "${user_value}" "${USERS_FILE}"
done || true

if [[ "${SITEMAP_CODE}" == "200" ]]; then
  grep -Eo '/author/[A-Za-z0-9._-]+/?' "${SITEMAP_BODY}" 2>/dev/null | sed 's#^/author/##; s#/$##' | while IFS= read -r user_value; do
    append_unique_line "${user_value}" "${SITEMAP_AUTHORS_FILE}"
    append_unique_line "${user_value}" "${USERS_FILE}"
  done || true
fi

if [[ "${FEED_CODE}" == "200" ]]; then
  grep -Eo '<dc:creator><!\[CDATA\[[^]]+\]\]></dc:creator>' "${FEED_BODY}" 2>/dev/null | sed -E 's#<dc:creator><!\[CDATA\[([^]]+)\]\]></dc:creator>#\1#' | while IFS= read -r user_value; do
    append_unique_line "${user_value}" "${FEED_AUTHORS_FILE}"
    append_unique_line "${user_value}" "${USERS_FILE}"
  done || true
fi

sort -u "${USERS_FILE}" -o "${USERS_FILE}"
USERS_JSON="$(json_array_from_lines_file "${USERS_FILE}")"
USER_COUNT="$(jq 'length' <<<"${USERS_JSON}")"
REST_USERS_JSON="$(json_array_from_lines_file "${REST_USERS_FILE}")"
AUTHOR_ARCHIVE_JSON="$(json_array_from_lines_file "${AUTHOR_ARCHIVE_FILE}")"
SITEMAP_AUTHORS_JSON="$(json_array_from_lines_file "${SITEMAP_AUTHORS_FILE}")"
FEED_AUTHORS_JSON="$(json_array_from_lines_file "${FEED_AUTHORS_FILE}")"

jq -n \
  --arg base_url "${BASE_URL}" \
  --arg rest_status "${REST_CODE}" \
  --arg sitemap_status "${SITEMAP_CODE}" \
  --arg feed_status "${FEED_CODE}" \
  --argjson user_count "${USER_COUNT}" \
  --argjson users "${USERS_JSON}" \
  --argjson rest_users "${REST_USERS_JSON}" \
  --argjson author_archives "${AUTHOR_ARCHIVE_JSON}" \
  --argjson sitemap_authors "${SITEMAP_AUTHORS_JSON}" \
  --argjson feed_authors "${FEED_AUTHORS_JSON}" \
  '{
    base_url: $base_url,
    user_count: $user_count,
    users: $users,
    vectors: [
      if ($rest_users | length) > 0 then "REST API /wp-json/wp/v2/users" else empty end,
      if ($author_archives | length) > 0 then "Author archives" else empty end,
      if ($sitemap_authors | length) > 0 then "User sitemap" else empty end,
      if ($feed_authors | length) > 0 then "RSS feed creators" else empty end
    ],
    evidence: {
      rest_users: $rest_users,
      author_archives: $author_archives,
      sitemap_authors: $sitemap_authors,
      feed_authors: $feed_authors
    },
    sources: {
      rest_api: $rest_status,
      sitemap: $sitemap_status,
      feed: $feed_status
    }
  }' > "${OUTPUT_DIR}/users.json"
