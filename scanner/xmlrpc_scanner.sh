#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_OUTPUT_ROOT="${PROJECT_ROOT}/reports"
DEFAULT_DELAY="1"
DEFAULT_TIMEOUT="10"
DEFAULT_USER_AGENT="wp-xmlrpc-recon/1.0"

LIST_METHODS_PAYLOAD='<?xml version="1.0"?><methodCall><methodName>system.listMethods</methodName><params></params></methodCall>'
AUTH_PROBE_PAYLOAD='<?xml version="1.0"?><methodCall><methodName>wp.getUsersBlogs</methodName><params><param><value><string>invalid-user</string></value></param><param><value><string>invalid-pass</string></value></param></params></methodCall>'

ROW_SEPARATOR=$'\037'

TARGET_FILE=""
OUTPUT_ROOT="${DEFAULT_OUTPUT_ROOT}"
REQUEST_DELAY="${DEFAULT_DELAY}"
REQUEST_TIMEOUT="${DEFAULT_TIMEOUT}"
USER_AGENT="${DEFAULT_USER_AGENT}"

SCAN_ROWS=()
TOTAL_TARGETS=0
EXPOSED_ENDPOINTS=0
MULTICALL_COUNT=0
PINGBACK_COUNT=0
AUTH_EXPOSED_COUNT=0

usage() {
  cat <<'EOF'
Usage: xmlrpc_scanner.sh -i <targets.txt> [-o output_dir] [-d delay_seconds] [-t timeout_seconds] [-u user_agent]

Options:
  -i  Input file containing targets, one per line
  -o  Output root directory for timestamped reports (default: ./reports)
  -d  Delay between requests in seconds (default: 1)
  -t  Request timeout in seconds (default: 10)
  -u  Custom User-Agent string
  -h  Show this help message
EOF
}

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

trim_line() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

ensure_xmlrpc_path() {
  local url="$1"

  if [[ "${url}" == */xmlrpc.php ]]; then
    printf '%s\n' "${url}"
    return
  fi

  if [[ "${url}" == */ ]]; then
    printf '%sxmlrpc.php\n' "${url}"
  else
    printf '%s/xmlrpc.php\n' "${url}"
  fi
}

build_candidate_urls() {
  local target="$1"
  target="$(trim_line "${target}")"

  if [[ "${target}" == http://* || "${target}" == https://* ]]; then
    ensure_xmlrpc_path "${target}"
    return
  fi

  ensure_xmlrpc_path "https://${target}"
  ensure_xmlrpc_path "http://${target}"
}

perform_xmlrpc_request() {
  local url="$1"
  local payload="$2"
  local body_file="$3"
  local error_file="$4"
  local http_code=""

  sleep "${REQUEST_DELAY}"

  if http_code="$(curl \
    --silent \
    --show-error \
    --location \
    --max-time "${REQUEST_TIMEOUT}" \
    --user-agent "${USER_AGENT}" \
    --header 'Content-Type: text/xml' \
    --data "${payload}" \
    --output "${body_file}" \
    --write-out '%{http_code}' \
    "${url}" 2>"${error_file}")"; then
    printf '%s' "${http_code}"
    return 0
  fi

  printf '000'
  return 1
}

xml_has_method_response() {
  local body_file="$1"
  grep -q '<methodResponse>' "${body_file}"
}

xml_has_fault() {
  local body_file="$1"
  grep -q '<fault>' "${body_file}"
}

extract_methods() {
  local body_file="$1"
  tr '\n' ' ' < "${body_file}" | sed 's/<string>/\
<string>/g' | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p'
}

string_in_list() {
  local needle="$1"
  local haystack="$2"
  printf '%s\n' "${haystack}" | grep -Fxq "${needle}"
}

build_methods_preview() {
  local methods="$1"
  local preview=""
  local count=0
  local method=""

  while IFS= read -r method; do
    [[ -z "${method}" ]] && continue
    if [[ -n "${preview}" ]]; then
      preview="${preview}, "
    fi
    preview="${preview}${method}"
    count=$((count + 1))
    if [[ "${count}" -ge 5 ]]; then
      break
    fi
  done <<EOF
${methods}
EOF

  printf '%s' "${preview}"
}

csv_escape() {
  local value="$1"
  value="${value//\"/\"\"}"
  printf '"%s"' "${value}"
}

html_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&#39;}"
  printf '%s' "${value}"
}

append_row() {
  local target="$1"
  local xmlrpc_url="$2"
  local endpoint_status="$3"
  local list_methods_status="$4"
  local method_count="$5"
  local multicall_enabled="$6"
  local pingback_enabled="$7"
  local auth_endpoint_exposed="$8"
  local notes="$9"

  SCAN_ROWS+=("${target}${ROW_SEPARATOR}${xmlrpc_url}${ROW_SEPARATOR}${endpoint_status}${ROW_SEPARATOR}${list_methods_status}${ROW_SEPARATOR}${method_count}${ROW_SEPARATOR}${multicall_enabled}${ROW_SEPARATOR}${pingback_enabled}${ROW_SEPARATOR}${auth_endpoint_exposed}${ROW_SEPARATOR}${notes}")
}

write_csv_report() {
  local csv_file="$1"
  local row=""
  local old_ifs="${IFS}"

  {
    printf 'target,xmlrpc_url,endpoint_status,list_methods_status,method_count,multicall_enabled,pingback_enabled,auth_endpoint_exposed,notes\n'
    for row in "${SCAN_ROWS[@]}"; do
      IFS="${ROW_SEPARATOR}" read -r target xmlrpc_url endpoint_status list_methods_status method_count multicall_enabled pingback_enabled auth_endpoint_exposed notes <<EOF
${row}
EOF
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_escape "${target}")" \
        "$(csv_escape "${xmlrpc_url}")" \
        "$(csv_escape "${endpoint_status}")" \
        "$(csv_escape "${list_methods_status}")" \
        "$(csv_escape "${method_count}")" \
        "$(csv_escape "${multicall_enabled}")" \
        "$(csv_escape "${pingback_enabled}")" \
        "$(csv_escape "${auth_endpoint_exposed}")" \
        "$(csv_escape "${notes}")"
    done
  } > "${csv_file}"

  IFS="${old_ifs}"
}

write_html_report() {
  local html_file="$1"
  local generated_at="$2"
  local row=""
  local old_ifs="${IFS}"

  {
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>wp-xmlrpc-recon report</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f4efe6;
      --panel: #fffaf2;
      --ink: #1d1d1b;
      --muted: #5b584f;
      --accent: #8e4b10;
      --border: #d6c6b0;
      --good: #1f6f4a;
      --warn: #8a5a00;
      --bad: #8b1e1e;
    }
    body {
      margin: 0;
      font-family: "IBM Plex Sans", "Avenir Next", sans-serif;
      background: linear-gradient(180deg, #efe2cf 0%, var(--bg) 100%);
      color: var(--ink);
    }
    main {
      max-width: 1200px;
      margin: 0 auto;
      padding: 32px 20px 48px;
    }
    h1 {
      margin-bottom: 8px;
      font-size: 2.2rem;
    }
    p, li {
      color: var(--muted);
      line-height: 1.5;
    }
    .meta, .summary {
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 18px;
      padding: 20px;
      box-shadow: 0 10px 30px rgba(71, 50, 25, 0.08);
    }
    .summary {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
      gap: 12px;
      margin: 20px 0 28px;
    }
    .summary strong {
      display: block;
      font-size: 1.8rem;
      color: var(--accent);
    }
    table {
      width: 100%;
      border-collapse: collapse;
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 18px;
      overflow: hidden;
    }
    th, td {
      padding: 12px 10px;
      border-bottom: 1px solid var(--border);
      text-align: left;
      vertical-align: top;
      font-size: 0.95rem;
    }
    th {
      background: #f0e2cd;
      color: var(--ink);
    }
    tr:last-child td {
      border-bottom: 0;
    }
    .yes {
      color: var(--bad);
      font-weight: 700;
    }
    .no {
      color: var(--good);
      font-weight: 700;
    }
    footer {
      margin-top: 24px;
      text-align: center;
      color: var(--muted);
      font-size: 0.95rem;
    }
    footer a {
      color: var(--accent);
      text-decoration: none;
      font-weight: 700;
    }
  </style>
</head>
<body>
  <main>
    <section class="meta">
      <h1>wp-xmlrpc-recon</h1>
      <p>Generated: $(html_escape "${generated_at}")</p>
      <p>Created by: Sternly Simon</p>
      <p>This report summarizes XML-RPC reconnaissance results gathered in a rate-limited, read-only scan.</p>
    </section>
    <section class="summary">
      <div><span>Total targets</span><strong>${TOTAL_TARGETS}</strong></div>
      <div><span>Exposed endpoints</span><strong>${EXPOSED_ENDPOINTS}</strong></div>
      <div><span>Multicall enabled</span><strong>${MULTICALL_COUNT}</strong></div>
      <div><span>Pingback enabled</span><strong>${PINGBACK_COUNT}</strong></div>
      <div><span>Auth surface exposed</span><strong>${AUTH_EXPOSED_COUNT}</strong></div>
    </section>
    <table>
      <thead>
        <tr>
          <th>Target</th>
          <th>XML-RPC URL</th>
          <th>Endpoint</th>
          <th>Methods</th>
          <th>Count</th>
          <th>Multicall</th>
          <th>Pingback</th>
          <th>Auth</th>
          <th>Notes</th>
        </tr>
      </thead>
      <tbody>
EOF

    for row in "${SCAN_ROWS[@]}"; do
      IFS="${ROW_SEPARATOR}" read -r target xmlrpc_url endpoint_status list_methods_status method_count multicall_enabled pingback_enabled auth_endpoint_exposed notes <<EOF
${row}
EOF
      printf '        <tr>\n'
      printf '          <td>%s</td>\n' "$(html_escape "${target}")"
      printf '          <td>%s</td>\n' "$(html_escape "${xmlrpc_url}")"
      printf '          <td class="%s">%s</td>\n' "$(html_escape "${endpoint_status}")" "$(html_escape "${endpoint_status}")"
      printf '          <td>%s</td>\n' "$(html_escape "${list_methods_status}")"
      printf '          <td>%s</td>\n' "$(html_escape "${method_count}")"
      printf '          <td class="%s">%s</td>\n' "$(html_escape "${multicall_enabled}")" "$(html_escape "${multicall_enabled}")"
      printf '          <td class="%s">%s</td>\n' "$(html_escape "${pingback_enabled}")" "$(html_escape "${pingback_enabled}")"
      printf '          <td class="%s">%s</td>\n' "$(html_escape "${auth_endpoint_exposed}")" "$(html_escape "${auth_endpoint_exposed}")"
      printf '          <td>%s</td>\n' "$(html_escape "${notes}")"
      printf '        </tr>\n'
    done

    cat <<'EOF'
      </tbody>
    </table>
    <footer>
      <p>Powered by <a href="https://www.cyberdevelopment.company">Cyber Development</a></p>
    </footer>
  </main>
</body>
</html>
EOF
  } > "${html_file}"

  IFS="${old_ifs}"
}

write_summary_json() {
  local summary_file="$1"
  local generated_at="$2"
  local csv_file="$3"
  local html_file="$4"

  jq -n \
    --arg generated_at "${generated_at}" \
    --arg csv_report "${csv_file}" \
    --arg html_report "${html_file}" \
    --argjson total_targets "${TOTAL_TARGETS}" \
    --argjson exposed_endpoints "${EXPOSED_ENDPOINTS}" \
    --argjson multicall_enabled "${MULTICALL_COUNT}" \
    --argjson pingback_enabled "${PINGBACK_COUNT}" \
    --argjson auth_surface_exposed "${AUTH_EXPOSED_COUNT}" \
    '{
      generated_at: $generated_at,
      reports: {
        csv: $csv_report,
        html: $html_report
      },
      totals: {
        total_targets: $total_targets,
        exposed_endpoints: $exposed_endpoints,
        multicall_enabled: $multicall_enabled,
        pingback_enabled: $pingback_enabled,
        auth_surface_exposed: $auth_surface_exposed
      }
    }' > "${summary_file}"
}

scan_target() {
  local target="$1"
  local candidate_url=""
  local active_url=""
  local temp_dir="$2"
  local body_file="${temp_dir}/body.xml"
  local error_file="${temp_dir}/curl.stderr"
  local auth_body_file="${temp_dir}/auth_body.xml"
  local auth_error_file="${temp_dir}/auth_curl.stderr"

  local endpoint_status="no"
  local list_methods_status="no"
  local method_count="0"
  local multicall_enabled="no"
  local pingback_enabled="no"
  local auth_endpoint_exposed="no"
  local notes="No XML-RPC response detected"
  local methods=""
  local methods_preview=""
  local http_code=""
  local auth_http_code=""

  log "Scanning ${target}"

  while IFS= read -r candidate_url; do
    [[ -z "${candidate_url}" ]] && continue

    if http_code="$(perform_xmlrpc_request "${candidate_url}" "${LIST_METHODS_PAYLOAD}" "${body_file}" "${error_file}")"; then
      if xml_has_method_response "${body_file}"; then
        endpoint_status="yes"
        active_url="${candidate_url}"
        EXPOSED_ENDPOINTS=$((EXPOSED_ENDPOINTS + 1))
        break
      fi
    fi
  done <<EOF
$(build_candidate_urls "${target}")
EOF

  if [[ "${endpoint_status}" == "yes" ]]; then
    methods="$(extract_methods "${body_file}" || true)"
    method_count="$(printf '%s\n' "${methods}" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [[ "${method_count}" -gt 0 ]] && ! xml_has_fault "${body_file}"; then
      list_methods_status="yes"
      notes="system.listMethods succeeded"
    else
      notes="XML-RPC response observed, but method enumeration was incomplete"
    fi

    if string_in_list "system.multicall" "${methods}"; then
      multicall_enabled="yes"
      MULTICALL_COUNT=$((MULTICALL_COUNT + 1))
    fi

    if string_in_list "pingback.ping" "${methods}"; then
      pingback_enabled="yes"
      PINGBACK_COUNT=$((PINGBACK_COUNT + 1))
    fi

    if string_in_list "wp.getUsersBlogs" "${methods}"; then
      auth_endpoint_exposed="yes"
      AUTH_EXPOSED_COUNT=$((AUTH_EXPOSED_COUNT + 1))
    else
      if auth_http_code="$(perform_xmlrpc_request "${active_url}" "${AUTH_PROBE_PAYLOAD}" "${auth_body_file}" "${auth_error_file}")"; then
        if grep -q 'wp.getUsersBlogs' "${auth_body_file}" || grep -q 'Incorrect username or password' "${auth_body_file}" || (xml_has_method_response "${auth_body_file}" && ! grep -q 'requested method .* does not exist' "${auth_body_file}"); then
          auth_endpoint_exposed="yes"
          AUTH_EXPOSED_COUNT=$((AUTH_EXPOSED_COUNT + 1))
        fi
      fi
    fi

    methods_preview="$(build_methods_preview "${methods}")"
    if [[ -n "${methods_preview}" ]]; then
      notes="${notes}; sample methods: ${methods_preview}"
    fi
  fi

  append_row \
    "${target}" \
    "${active_url}" \
    "${endpoint_status}" \
    "${list_methods_status}" \
    "${method_count}" \
    "${multicall_enabled}" \
    "${pingback_enabled}" \
    "${auth_endpoint_exposed}" \
    "${notes}"
}

main() {
  local timestamp=""
  local scan_dir=""
  local temp_dir=""
  local generated_at=""
  local csv_file=""
  local html_file=""
  local summary_file=""
  local raw_line=""
  local target=""

  require_command bash
  require_command curl
  require_command jq

  while getopts ':i:o:d:t:u:h' option; do
    case "${option}" in
      i) TARGET_FILE="${OPTARG}" ;;
      o) OUTPUT_ROOT="${OPTARG}" ;;
      d) REQUEST_DELAY="${OPTARG}" ;;
      t) REQUEST_TIMEOUT="${OPTARG}" ;;
      u) USER_AGENT="${OPTARG}" ;;
      h)
        usage
        exit 0
        ;;
      :)
        printf 'Option -%s requires an argument.\n' "${OPTARG}" >&2
        usage >&2
        exit 1
        ;;
      \?)
        printf 'Unknown option: -%s\n' "${OPTARG}" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "${TARGET_FILE}" ]]; then
    printf 'An input file is required.\n' >&2
    usage >&2
    exit 1
  fi

  if [[ ! -f "${TARGET_FILE}" ]]; then
    printf 'Input file not found: %s\n' "${TARGET_FILE}" >&2
    exit 1
  fi

  mkdir -p "${OUTPUT_ROOT}"
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  scan_dir="${OUTPUT_ROOT}/scan_${timestamp}"
  temp_dir="${scan_dir}/.tmp"
  mkdir -p "${temp_dir}"

  csv_file="${scan_dir}/xmlrpc_scan.csv"
  html_file="${scan_dir}/xmlrpc_scan.html"
  summary_file="${scan_dir}/scan_summary.json"
  generated_at="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    target="$(trim_line "${raw_line}")"
    [[ -z "${target}" ]] && continue
    [[ "${target}" == \#* ]] && continue
    TOTAL_TARGETS=$((TOTAL_TARGETS + 1))
    scan_target "${target}" "${temp_dir}"
  done < "${TARGET_FILE}"

  if [[ "${TOTAL_TARGETS}" -eq 0 ]]; then
    printf 'No usable targets found in %s\n' "${TARGET_FILE}" >&2
    exit 1
  fi

  write_csv_report "${csv_file}"
  write_html_report "${html_file}" "${generated_at}"
  write_summary_json "${summary_file}" "${generated_at}" "${csv_file}" "${html_file}"

  rm -rf "${temp_dir}"

  log "Loaded ${TOTAL_TARGETS} target(s) from ${TARGET_FILE}"
  log "Scan complete"
  log "CSV report: ${csv_file}"
  log "HTML report: ${html_file}"
  log "Summary JSON: ${summary_file}"
}

main "$@"
