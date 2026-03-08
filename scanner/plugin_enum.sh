#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASE_URL="${1:?base url is required}"
OUTPUT_DIR="${2:?output directory is required}"

mkdir -p "${OUTPUT_DIR}"

TEMP_DIR="$(mktemp -d)"
PLUGINS_FILE="${OUTPUT_DIR}/plugins.txt"
SOURCES_FILE="${TEMP_DIR}/plugin_sources.txt"
: > "${PLUGINS_FILE}"

extract_plugins_from_file() {
  local input_file="$1"
  local source_label="$2"
  local matches=""

  matches="$(grep -Eo 'wp-content/plugins/[A-Za-z0-9._-]+' "${input_file}" 2>/dev/null | sed 's#wp-content/plugins/##' | sort -u || true)"

  if [[ -n "${matches}" ]]; then
    printf '%s\n' "${matches}" | while IFS= read -r plugin_slug; do
      append_unique_line "${plugin_slug}" "${PLUGINS_FILE}"
      append_unique_line "${source_label}" "${SOURCES_FILE}"
    done
  fi
}

HOME_BODY="${TEMP_DIR}/home.html"
HOME_HEADERS="${TEMP_DIR}/home.headers"
ROBOTS_BODY="${TEMP_DIR}/robots.txt"
ROBOTS_HEADERS="${TEMP_DIR}/robots.headers"
ROOT_BODY="${TEMP_DIR}/wp-json.json"
ROOT_HEADERS="${TEMP_DIR}/wp-json.headers"
PLUGIN_API_BODY="${TEMP_DIR}/plugins.json"
PLUGIN_API_HEADERS="${TEMP_DIR}/plugins.headers"

http_request GET "${BASE_URL}/" "${HOME_BODY}" "${HOME_HEADERS}" >/dev/null || true
http_request GET "${BASE_URL}/robots.txt" "${ROBOTS_BODY}" "${ROBOTS_HEADERS}" >/dev/null || true
ROOT_CODE="$(http_request GET "${BASE_URL}/wp-json" "${ROOT_BODY}" "${ROOT_HEADERS}" || true)"
PLUGIN_API_CODE="$(http_request GET "${BASE_URL}/wp-json/wp/v2/plugins" "${PLUGIN_API_BODY}" "${PLUGIN_API_HEADERS}" || true)"

extract_plugins_from_file "${HOME_BODY}" "homepage"
extract_plugins_from_file "${ROBOTS_BODY}" "robots.txt"

if [[ "${PLUGIN_API_CODE}" == "200" ]]; then
  jq -r '.[]? | (.slug // .name // empty)' "${PLUGIN_API_BODY}" 2>/dev/null | while IFS= read -r plugin_slug; do
    append_unique_line "${plugin_slug}" "${PLUGINS_FILE}"
    append_unique_line "wp-json/wp/v2/plugins" "${SOURCES_FILE}"
  done || true
fi

if [[ "${ROOT_CODE}" == "200" ]]; then
  jq -r '.namespaces[]? | select(test("^(wp|oembed|yoast|rankmath|acf|contact-form-7|jetpack|wc|woocommerce)/") | not)' "${ROOT_BODY}" 2>/dev/null | while IFS= read -r namespace; do
    append_unique_line "${namespace}" "${TEMP_DIR}/custom_namespaces.txt"
  done || true
fi

sort -u "${PLUGINS_FILE}" -o "${PLUGINS_FILE}"
SOURCES_JSON="$(json_array_from_lines_file "${SOURCES_FILE}")"
CUSTOM_NAMESPACES_JSON="$(json_array_from_lines_file "${TEMP_DIR}/custom_namespaces.txt")"
PLUGINS_JSON="$(json_array_from_lines_file "${PLUGINS_FILE}")"
PLUGIN_COUNT="$(jq 'length' <<<"${PLUGINS_JSON}")"

jq -n \
  --arg base_url "${BASE_URL}" \
  --arg plugin_api_status "${PLUGIN_API_CODE}" \
  --argjson plugins "${PLUGINS_JSON}" \
  --argjson sources "${SOURCES_JSON}" \
  --argjson custom_namespaces "${CUSTOM_NAMESPACES_JSON}" \
  --argjson plugin_count "${PLUGIN_COUNT}" \
  '{
    base_url: $base_url,
    plugin_count: $plugin_count,
    plugins: $plugins,
    sources: $sources,
    plugin_api_status: $plugin_api_status,
    custom_namespaces: $custom_namespaces
  }' > "${OUTPUT_DIR}/plugins.json"
