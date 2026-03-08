#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET_FILE=""
OUTPUT_ROOT="${PROJECT_ROOT}/reports"
RUN_PLUGINS="no"
RUN_XMLRPC="no"
RUN_REST="no"
RUN_LOGIN="no"
RUN_USERS="no"
RUN_CEWL="no"
RUN_WPSCAN="no"
RUN_FULL="no"

usage() {
  cat <<'EOF'
Usage: wp_scan.sh -t <targets.txt> [--plugins] [--xmlrpc] [--rest] [--login] [--users] [--cewl] [--wpscan] [--full]

Options:
  -t, --targets   path to targets file
  -o, --output    report output directory (default: ./reports)
      --plugins   run plugin enumeration
      --xmlrpc    run XML-RPC analysis
      --rest      run REST API analysis
      --login     run login surface checks
      --users     run user enumeration
      --cewl      run CeWL public wordlist capture if available
      --wpscan    run passive WPScan integration if available
      --full      run the full pipeline
  -h, --help      show help
EOF
}

run_passive_wpscan() {
  local base_url="$1"
  local output_dir="$2"
  local status="not_requested"
  local target_host=""
  local timeout_bin=""
  local engine="none"
  local output_dir_abs=""
  local wpscan_image="${WPSCAN_DOCKER_IMAGE:-wpscanteam/wpscan}"

  if [[ "${RUN_WPSCAN}" != "yes" ]]; then
    jq -n --arg status "${status}" --arg engine "${engine}" '{status: $status, engine: $engine}' > "${output_dir}/wpscan.json"
    return
  fi

  target_host="$(printf '%s' "${base_url}" | sed 's#^[[:alpha:]][[:alnum:]+.-]*://##; s#/.*$##; s/:.*$//')"
  if [[ "${target_host}" == "127.0.0.1" || "${target_host}" == "localhost" ]]; then
    jq -n --arg status "skipped_loopback" --arg engine "${engine}" '{status: $status, engine: $engine}' > "${output_dir}/wpscan.json"
    return
  fi

  output_dir_abs="$(abs_path "${output_dir}")"

  if has_command wpscan && command_works wpscan --version; then
    if has_command timeout; then
      timeout_bin="timeout"
    elif has_command gtimeout; then
      timeout_bin="gtimeout"
    fi

    if [[ -n "${timeout_bin}" ]]; then
      if "${timeout_bin}" 60 wpscan --url "${base_url}" --plugins-detection passive --request-timeout 10 --format json -o "${output_dir}/wpscan.json" >/dev/null 2>&1; then
        status="completed"
        engine="native"
      else
        status="error"
        engine="native"
      fi
    elif wpscan --url "${base_url}" --plugins-detection passive --request-timeout 10 --format json -o "${output_dir}/wpscan.json" >/dev/null 2>&1; then
      status="completed"
      engine="native"
    else
      status="error"
      engine="native"
    fi
  elif docker_available; then
    if docker run --rm \
      -v "${output_dir_abs}:/output" \
      "${wpscan_image}" \
      --url "${base_url}" \
      --plugins-detection passive \
      --request-timeout 10 \
      --format json \
      -o /output/wpscan.json >/dev/null 2>&1; then
      status="completed"
      engine="docker"
    else
      status="error"
      engine="docker"
    fi
  else
    status="unavailable"
  fi

  if [[ ! -f "${output_dir}/wpscan.json" ]]; then
    jq -n --arg status "${status}" --arg engine "${engine}" '{status: $status, engine: $engine}' > "${output_dir}/wpscan.json"
  else
    TEMP_FILE="${output_dir}/wpscan.status.json"
    jq --arg status "${status}" --arg engine "${engine}" '. + {status: $status, engine: $engine}' "${output_dir}/wpscan.json" > "${TEMP_FILE}" && mv "${TEMP_FILE}" "${output_dir}/wpscan.json"
  fi
}

build_repository_summary() {
  local summary_csv="${OUTPUT_ROOT}/summary.csv"
  local summary_json="${OUTPUT_ROOT}/summary.json"
  local summary_html="${OUTPUT_ROOT}/index.html"
  local first_row="yes"
  local report_file=""
  local -a report_files

  : > "${summary_csv}"
  report_files=("${OUTPUT_ROOT}"/*/report.json)

  for report_file in "${report_files[@]}"; do
    [[ ! -f "${report_file}" ]] && continue
    if [[ "${first_row}" == "yes" ]]; then
      sed -n '1,2p' "${report_file%report.json}report.csv" > "${summary_csv}"
      first_row="no"
    else
      sed -n '2p' "${report_file%report.json}report.csv" >> "${summary_csv}"
    fi
  done

  if [[ -f "${report_files[0]:-}" ]]; then
    jq -s '.' "${report_files[@]}" > "${summary_json}"
  else
    printf '[]\n' > "${summary_json}"
  fi

  {
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>wp-attack-surface-scanner summary</title>
  <style>
    :root {
      --bg: #f3ede2;
      --panel: rgba(255, 251, 244, 0.92);
      --ink: #1d1d1b;
      --muted: #5b584f;
      --accent: #8e4b10;
      --border: #d6c6b0;
      --good: #1d6a4f;
      --shadow: 0 16px 40px rgba(66, 47, 22, 0.08);
    }
    * { box-sizing: border-box; }
    body {
      font-family: "IBM Plex Sans", "Avenir Next", sans-serif;
      margin: 0;
      background:
        radial-gradient(circle at top left, rgba(142, 75, 16, 0.16), transparent 28%),
        linear-gradient(180deg, #efe2cf 0%, var(--bg) 100%);
      color: var(--ink);
    }
    main { max-width: 1240px; margin: 0 auto; padding: 32px 20px 48px; }
    .card {
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 22px;
      padding: 22px;
      box-shadow: var(--shadow);
      backdrop-filter: blur(8px);
    }
    .hero {
      display: grid;
      grid-template-columns: minmax(0, 2fr) minmax(280px, 1fr);
      gap: 18px;
      margin-bottom: 18px;
    }
    .hero h1 { margin: 0 0 10px; font-size: 2.3rem; line-height: 1.05; }
    .hero p { margin: 6px 0; color: var(--muted); overflow-wrap: anywhere; }
    .eyebrow {
      margin: 0 0 8px;
      font-size: 0.82rem;
      text-transform: uppercase;
      letter-spacing: 0.12em;
      color: var(--accent);
      font-weight: 700;
    }
    .hero-note {
      padding: 16px;
      border-radius: 18px;
      background: linear-gradient(135deg, rgba(142, 75, 16, 0.14), rgba(255, 247, 238, 0.8));
      border: 1px solid rgba(142, 75, 16, 0.14);
    }
    .table-wrap {
      overflow-x: auto;
      border-radius: 18px;
      border: 1px solid rgba(214, 198, 176, 0.9);
      background: rgba(255, 255, 255, 0.5);
    }
    table { width: 100%; border-collapse: collapse; min-width: 920px; }
    th, td {
      padding: 12px 10px;
      border-bottom: 1px solid #d6c6b0;
      text-align: left;
      vertical-align: top;
      overflow-wrap: anywhere;
    }
    th {
      background: rgba(142, 75, 16, 0.08);
      color: var(--muted);
      font-size: 0.86rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    tr:last-child td { border-bottom: 0; }
    .good { color: var(--good); font-weight: 700; }
    .muted { color: var(--muted); }
    footer { margin-top: 24px; text-align: center; color: #5b584f; }
    footer a { color: #8e4b10; text-decoration: none; font-weight: 700; }
    @media (max-width: 840px) {
      .hero { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <main>
    <section class="hero">
      <article class="card">
        <p class="eyebrow">Assessment Overview</p>
        <h1>WordPress Recon Summary</h1>
        <p>Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')</p>
        <p>Created by: Sternly Simon</p>
        <p>This summary consolidates all per-target report data generated by the v2 attack-surface scanner run.</p>
      </article>
      <aside class="card hero-note">
        <p class="eyebrow">Review Guidance</p>
        <p>Use this view to prioritize targets with confirmed WordPress exposure, rich user enumeration, or XML-RPC functionality before drilling into each target-specific report.</p>
      </aside>
    </section>
    <section class="card">
      <p class="eyebrow">Targets</p>
      <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Target</th>
            <th>Base URL</th>
            <th>WordPress</th>
            <th>Plugins</th>
            <th>Users</th>
            <th>XML-RPC</th>
            <th>Multicall</th>
            <th>Login</th>
          </tr>
        </thead>
        <tbody>
EOF
    for report_file in "${report_files[@]}"; do
      [[ ! -f "${report_file}" ]] && continue
      printf '          <tr>\n'
      printf '            <td>%s</td>\n' "$(html_escape "$(jq -r '.target' "${report_file}")")"
      printf '            <td>%s</td>\n' "$(html_escape "$(jq -r '.base_url' "${report_file}")")"
      printf '            <td class="%s">%s</td>\n' "$( [[ "$(jq -r '.wordpress_detected' "${report_file}")" == "yes" ]] && printf 'good' || printf 'muted' )" "$(html_escape "$(jq -r '.wordpress_detected' "${report_file}")")"
      printf '            <td>%s</td>\n' "$(html_escape "$(jq -r '.plugins | length' "${report_file}")")"
      printf '            <td>%s</td>\n' "$(html_escape "$(jq -r '.users | length' "${report_file}")")"
      printf '            <td class="%s">%s</td>\n' "$( [[ "$(jq -r '.xmlrpc.xmlrpc_detected' "${report_file}")" == "yes" ]] && printf 'good' || printf 'muted' )" "$(html_escape "$(jq -r '.xmlrpc.xmlrpc_detected' "${report_file}")")"
      printf '            <td>%s</td>\n' "$(html_escape "$(jq -r '.xmlrpc.multicall' "${report_file}")")"
      printf '            <td>%s</td>\n' "$(html_escape "$(jq -r '.login.login_page_present' "${report_file}")")"
      printf '          </tr>\n'
    done
    cat <<'EOF'
        </tbody>
      </table>
      </div>
      <footer>
        <p>Powered by <a href="https://www.cyberdevelopment.company">Cyber Development</a></p>
      </footer>
    </section>
  </main>
</body>
</html>
EOF
  } > "${summary_html}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--targets)
      TARGET_FILE="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --plugins)
      RUN_PLUGINS="yes"
      shift
      ;;
    --xmlrpc)
      RUN_XMLRPC="yes"
      shift
      ;;
    --rest)
      RUN_REST="yes"
      shift
      ;;
    --login)
      RUN_LOGIN="yes"
      shift
      ;;
    --users)
      RUN_USERS="yes"
      shift
      ;;
    --cewl)
      RUN_CEWL="yes"
      shift
      ;;
    --wpscan)
      RUN_WPSCAN="yes"
      shift
      ;;
    --full)
      RUN_FULL="yes"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${TARGET_FILE}" || ! -f "${TARGET_FILE}" ]]; then
  printf 'A valid target file is required.\n' >&2
  usage >&2
  exit 1
fi

require_command bash
require_command curl
require_command jq
mkdir -p "${OUTPUT_ROOT}"

if [[ "${RUN_FULL}" == "yes" ]]; then
  RUN_PLUGINS="yes"
  RUN_XMLRPC="yes"
  RUN_REST="yes"
  RUN_LOGIN="yes"
  RUN_USERS="yes"
  RUN_CEWL="yes"
  RUN_WPSCAN="yes"
fi

if [[ "${RUN_PLUGINS}" == "no" && "${RUN_XMLRPC}" == "no" && "${RUN_REST}" == "no" && "${RUN_LOGIN}" == "no" && "${RUN_USERS}" == "no" && "${RUN_CEWL}" == "no" && "${RUN_WPSCAN}" == "no" ]]; then
  RUN_PLUGINS="yes"
  RUN_XMLRPC="yes"
  RUN_REST="yes"
  RUN_LOGIN="yes"
  RUN_USERS="yes"
fi

while IFS= read -r raw_target || [[ -n "${raw_target}" ]]; do
  target="$(trim_line "${raw_target}")"
  [[ -z "${target}" ]] && continue
  [[ "${target}" == \#* ]] && continue

  target_slug="$(slugify_target "${target}")"
  target_dir="${OUTPUT_ROOT}/${target_slug}"
  mkdir -p "${target_dir}"

  log "Scanning ${target}"
  "${SCRIPT_DIR}/detect_wordpress.sh" "${target}" "${target_dir}"
  base_url="$(jq -r '.base_url' "${target_dir}/wordpress_detection.json")"

  if [[ "${RUN_PLUGINS}" == "yes" ]]; then
    "${SCRIPT_DIR}/plugin_enum.sh" "${base_url}" "${target_dir}"
  else
    : > "${target_dir}/plugins.txt"
    jq -n '{plugin_count: 0, plugins: []}' > "${target_dir}/plugins.json"
  fi

  if [[ "${RUN_REST}" == "yes" ]]; then
    "${SCRIPT_DIR}/rest_api_scan.sh" "${base_url}" "${target_dir}"
  else
    jq -n '{custom_endpoints: [], namespaces: [], users_exposed: "no", posts_exposed: "no", drafts_exposed: "no"}' > "${target_dir}/rest_endpoints.json"
  fi

  if [[ "${RUN_XMLRPC}" == "yes" ]]; then
    "${SCRIPT_DIR}/xmlrpc_scan.sh" "${base_url}" "${target_dir}"
  else
    : > "${target_dir}/xmlrpc_methods.xml"
    : > "${target_dir}/xmlrpc_methods.txt"
    jq -n '{xmlrpc_detected: "no", method_count: 0, methods: [], multicall: "no", pingback: "no", auth_endpoint_exposed: "no"}' > "${target_dir}/xmlrpc_summary.json"
  fi

  if [[ "${RUN_LOGIN}" == "yes" ]]; then
    "${SCRIPT_DIR}/login_scan.sh" "${base_url}" "${target_dir}"
  else
    jq -n '{login_page_present: "no", invalid_login_response: "no", rate_limiting_signals: "no", wp_admin_endpoint: "no"}' > "${target_dir}/login_surface.json"
  fi

  if [[ "${RUN_USERS}" == "yes" ]]; then
    "${SCRIPT_DIR}/user_enum.sh" "${base_url}" "${target_dir}"
  else
    : > "${target_dir}/users.txt"
    jq -n '{user_count: 0, users: []}' > "${target_dir}/users.json"
  fi

  if [[ "${RUN_CEWL}" == "yes" ]]; then
    "${SCRIPT_DIR}/cewl_wordlist.sh" "${base_url}" "${target_dir}"
  else
    : > "${target_dir}/wordlist.txt"
    jq -n '{status: "not_requested", word_count: 0}' > "${target_dir}/wordlist.json"
  fi

  run_passive_wpscan "${base_url}" "${target_dir}"
  "${SCRIPT_DIR}/report_generator.sh" "${target}" "${target_dir}"
done < "${TARGET_FILE}"

build_repository_summary
log "Completed scan run for $(find "${OUTPUT_ROOT}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') target(s)"
