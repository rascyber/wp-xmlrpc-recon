#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASE_URL="${1:?base url is required}"
OUTPUT_DIR="${2:?output directory is required}"

mkdir -p "${OUTPUT_DIR}"

TEMP_DIR="$(mktemp -d)"
XMLRPC_URL="${BASE_URL}/xmlrpc.php"
BODY_FILE="${TEMP_DIR}/xmlrpc.xml"
HEADERS_FILE="${TEMP_DIR}/xmlrpc.headers"
AUTH_BODY="${TEMP_DIR}/xmlrpc_auth.xml"
AUTH_HEADERS="${TEMP_DIR}/xmlrpc_auth.headers"
METHODS_FILE="${OUTPUT_DIR}/xmlrpc_methods.txt"
METHODS_XML_FILE="${OUTPUT_DIR}/xmlrpc_methods.xml"

LIST_METHODS_PAYLOAD='<?xml version="1.0"?><methodCall><methodName>system.listMethods</methodName><params></params></methodCall>'
AUTH_PROBE_PAYLOAD='<?xml version="1.0"?><methodCall><methodName>wp.getUsersBlogs</methodName><params><param><value><string>invalid-user</string></value></param><param><value><string>invalid-pass</string></value></param></params></methodCall>'

XMLRPC_DETECTED="no"
METHOD_COUNT=0
MULTICALL="no"
PINGBACK="no"
AUTH_EXPOSED="no"
HTTP_CODE="$(http_request POST "${XMLRPC_URL}" "${BODY_FILE}" "${HEADERS_FILE}" "${LIST_METHODS_PAYLOAD}" "text/xml" || true)"

if [[ "${HTTP_CODE}" == "200" ]] && grep -q '<methodResponse>' "${BODY_FILE}" 2>/dev/null; then
  XMLRPC_DETECTED="yes"
  cp "${BODY_FILE}" "${METHODS_XML_FILE}"
  tr '\n' ' ' < "${BODY_FILE}" | sed 's/<string>/\
<string>/g' | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p' | sort -u > "${METHODS_FILE}" || true
  METHOD_COUNT="$(wc -l < "${METHODS_FILE}" | tr -d ' ')"

  if grep -Fxq 'system.multicall' "${METHODS_FILE}" 2>/dev/null; then
    MULTICALL="yes"
  fi

  if grep -Fxq 'pingback.ping' "${METHODS_FILE}" 2>/dev/null; then
    PINGBACK="yes"
  fi

  if grep -Fxq 'wp.getUsersBlogs' "${METHODS_FILE}" 2>/dev/null; then
    AUTH_EXPOSED="yes"
  else
    AUTH_CODE="$(http_request POST "${XMLRPC_URL}" "${AUTH_BODY}" "${AUTH_HEADERS}" "${AUTH_PROBE_PAYLOAD}" "text/xml" || true)"
    if [[ "${AUTH_CODE}" == "200" ]] && grep -Eqi 'Incorrect username or password|wp.getUsersBlogs|fault' "${AUTH_BODY}" 2>/dev/null; then
      AUTH_EXPOSED="yes"
    fi
  fi
else
  : > "${METHODS_FILE}"
  : > "${METHODS_XML_FILE}"
fi

METHODS_JSON="$(json_array_from_lines_file "${METHODS_FILE}")"

jq -n \
  --arg xmlrpc_url "${XMLRPC_URL}" \
  --arg xmlrpc_detected "${XMLRPC_DETECTED}" \
  --arg http_status "${HTTP_CODE}" \
  --arg multicall "${MULTICALL}" \
  --arg pingback "${PINGBACK}" \
  --arg auth_exposed "${AUTH_EXPOSED}" \
  --argjson method_count "${METHOD_COUNT:-0}" \
  --argjson methods "${METHODS_JSON}" \
  '{
    xmlrpc_url: $xmlrpc_url,
    xmlrpc_detected: $xmlrpc_detected,
    http_status: $http_status,
    method_count: $method_count,
    methods: $methods,
    multicall: $multicall,
    pingback: $pingback,
    auth_endpoint_exposed: $auth_exposed
  }' > "${OUTPUT_DIR}/xmlrpc_summary.json"
