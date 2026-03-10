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
  local wpscan_bin=""
  local container_bin=""

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

  if wpscan_bin="$(tool_path wpscan 2>/dev/null)" && tool_works wpscan --version; then
    if has_command timeout; then
      timeout_bin="timeout"
    elif has_command gtimeout; then
      timeout_bin="gtimeout"
    fi

    if [[ -n "${timeout_bin}" ]]; then
      if "${timeout_bin}" 60 "${wpscan_bin}" --url "${base_url}" --plugins-detection passive --request-timeout 10 --format json -o "${output_dir}/wpscan.json" >/dev/null 2>&1; then
        status="completed"
        engine="native"
      else
        status="error"
        engine="native"
      fi
    elif "${wpscan_bin}" --url "${base_url}" --plugins-detection passive --request-timeout 10 --format json -o "${output_dir}/wpscan.json" >/dev/null 2>&1; then
      status="completed"
      engine="native"
    else
      status="error"
      engine="native"
    fi
  elif container_bin="$(container_runtime 2>/dev/null)"; then
    if "${container_bin}" run --rm \
      -v "${output_dir_abs}:/output" \
      "${wpscan_image}" \
      --url "${base_url}" \
      --plugins-detection passive \
      --request-timeout 10 \
      --format json \
      -o /output/wpscan.json >/dev/null 2>&1; then
      status="completed"
      engine="${container_bin}"
    else
      status="error"
      engine="${container_bin}"
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
  local report_file=""
  local report_dir=""
  local temp_dir=""
  local temp_json=""
  local -a report_files

  temp_dir="$(mktemp -d)"
  printf 'target,base_url,wordpress_detected,plugin_count,user_count,xmlrpc_detected,xmlrpc_method_count,multicall,pingback,login_page_present,rate_limiting_signals,wordlist_status,wpscan_status\n' > "${summary_csv}"
  report_files=("${OUTPUT_ROOT}"/*/report.json)

  for report_file in "${report_files[@]}"; do
    [[ ! -f "${report_file}" ]] && continue
    sed -n '2p' "${report_file%report.json}report.csv" >> "${summary_csv}"
    report_dir="$(basename "$(dirname "${report_file}")")"
    temp_json="${temp_dir}/${report_dir}.json"
    jq \
      --arg report_dir "${report_dir}" \
      '. + {
        artifact_paths: {
          directory: $report_dir,
          report_html: ($report_dir + "/report.html"),
          report_json: ($report_dir + "/report.json"),
          report_csv: ($report_dir + "/report.csv"),
          xmlrpc_methods_xml: ($report_dir + "/xmlrpc_methods.xml")
        }
      }' "${report_file}" > "${temp_json}"
  done

  if compgen -G "${temp_dir}/*.json" >/dev/null; then
    jq -s '.' "${temp_dir}"/*.json > "${summary_json}"
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
      --panel: rgba(255, 251, 244, 0.94);
      --ink: #1d1d1b;
      --muted: #5b584f;
      --accent: #8e4b10;
      --border: #d6c6b0;
      --good: #1d6a4f;
      --warn: #8a5a00;
      --bad: #8b1e1e;
      --info: #315f8f;
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
    main { max-width: 1400px; margin: 0 auto; padding: 32px 20px 48px; }
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
    .metric-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
      gap: 12px;
      margin-bottom: 18px;
    }
    .metric {
      padding: 16px;
      border-radius: 18px;
      background: rgba(255, 255, 255, 0.56);
      border: 1px solid rgba(214, 198, 176, 0.9);
    }
    .metric strong {
      display: block;
      font-size: 2rem;
      line-height: 1;
      margin-bottom: 10px;
    }
    .metric span {
      color: var(--muted);
      font-size: 0.92rem;
    }
    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: center;
      margin-bottom: 18px;
    }
    .toolbar input {
      flex: 1 1 280px;
      min-width: 0;
      border: 1px solid var(--border);
      border-radius: 999px;
      padding: 12px 16px;
      background: rgba(255, 255, 255, 0.8);
      color: var(--ink);
      font: inherit;
    }
    .toolbar button {
      border: 0;
      border-radius: 999px;
      padding: 12px 10px;
      background: var(--accent);
      color: #fffaf4;
      font: inherit;
      font-weight: 700;
      cursor: pointer;
    }
    .dashboard {
      display: grid;
      grid-template-columns: minmax(320px, 410px) minmax(0, 1fr);
      gap: 18px;
      align-items: start;
    }
    .target-list {
      display: grid;
      gap: 12px;
      max-height: 980px;
      overflow: auto;
      padding-right: 4px;
    }
    .target-item {
      width: 100%;
      text-align: left;
      border: 1px solid rgba(214, 198, 176, 0.9);
      background: rgba(255, 255, 255, 0.6);
      border-radius: 18px;
      padding: 16px;
      cursor: pointer;
      transition: transform 120ms ease, border-color 120ms ease, box-shadow 120ms ease;
    }
    .target-item:hover,
    .target-item.active {
      transform: translateY(-1px);
      border-color: rgba(142, 75, 16, 0.4);
      box-shadow: 0 12px 24px rgba(66, 47, 22, 0.08);
    }
    .target-item h3 {
      margin: 0 0 8px;
      font-size: 1rem;
      line-height: 1.3;
      overflow-wrap: anywhere;
    }
    .target-item p {
      margin: 0 0 10px;
      color: var(--muted);
      font-size: 0.92rem;
      overflow-wrap: anywhere;
    }
    .mini-stats,
    .badge-row,
    .detail-links,
    .mitre-row {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }
    .mini-stat,
    .token {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      max-width: 100%;
      padding: 7px 10px;
      border-radius: 12px;
      background: rgba(142, 75, 16, 0.08);
      color: var(--ink);
      font-size: 0.85rem;
      overflow-wrap: anywhere;
      word-break: break-word;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      padding: 6px 11px;
      border-radius: 999px;
      font-weight: 700;
      font-size: 0.8rem;
      letter-spacing: 0.02em;
      border: 1px solid transparent;
      text-transform: uppercase;
    }
    .badge-yes,
    .badge-completed,
    .badge-generated,
    .badge-medium {
      background: rgba(29, 106, 79, 0.12);
      color: var(--good);
      border-color: rgba(29, 106, 79, 0.22);
    }
    .badge-no,
    .badge-skipped,
    .badge-skipped_loopback,
    .badge-not_requested,
    .badge-unavailable,
    .badge-info {
      background: rgba(91, 88, 79, 0.1);
      color: var(--muted);
      border-color: rgba(91, 88, 79, 0.14);
    }
    .badge-error,
    .badge-high {
      background: rgba(139, 30, 30, 0.1);
      color: var(--bad);
      border-color: rgba(139, 30, 30, 0.18);
    }
    .badge-warn {
      background: rgba(138, 90, 0, 0.12);
      color: var(--warn);
      border-color: rgba(138, 90, 0, 0.2);
    }
    .detail-panel {
      min-height: 980px;
    }
    .detail-head {
      display: flex;
      flex-wrap: wrap;
      align-items: flex-start;
      justify-content: space-between;
      gap: 14px;
      margin-bottom: 18px;
    }
    .detail-head h2 {
      margin: 0 0 8px;
      font-size: 2rem;
      line-height: 1.05;
      overflow-wrap: anywhere;
    }
    .detail-head p {
      margin: 4px 0;
      color: var(--muted);
      overflow-wrap: anywhere;
    }
    .detail-links a,
    .mitre-row a {
      color: var(--info);
      text-decoration: none;
      font-weight: 700;
      overflow-wrap: anywhere;
    }
    .detail-grid,
    .finding-grid,
    .surface-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
      gap: 14px;
      margin-top: 14px;
    }
    .detail-card,
    .surface-card,
    .finding-card {
      border: 1px solid rgba(214, 198, 176, 0.9);
      border-radius: 18px;
      padding: 16px;
      background: rgba(255, 255, 255, 0.56);
    }
    .detail-card h3,
    .surface-card h3,
    .finding-card h3 {
      margin: 0 0 10px;
      font-size: 1rem;
    }
    .detail-card p,
    .surface-card p,
    .finding-card p {
      margin: 0 0 10px;
      color: var(--muted);
      line-height: 1.5;
    }
    .token-wrap {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      max-height: 240px;
      overflow: auto;
    }
    .empty-state {
      color: var(--muted);
      padding: 24px 0;
    }
    .module-table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 18px;
      table-layout: fixed;
    }
    .module-table th,
    .module-table td {
      border-bottom: 1px solid var(--border);
      text-align: left;
      vertical-align: top;
      padding: 10px 8px;
      overflow-wrap: anywhere;
    }
    .module-table th {
      color: var(--muted);
      width: 32%;
    }
    footer { margin-top: 24px; text-align: center; color: #5b584f; }
    footer a { color: #8e4b10; text-decoration: none; font-weight: 700; }
    @media (max-width: 840px) {
      .hero { grid-template-columns: 1fr; }
      .dashboard { grid-template-columns: 1fr; }
      .detail-panel { min-height: 0; }
      .target-list,
      .token-wrap { max-height: none; }
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
        <p>Use the target list to pivot between findings. Each detail view exposes plugins, users, author POE, login paths, REST routes, XML-RPC methods, and ATT&amp;CK-informed recon tags.</p>
      </aside>
    </section>
    <section class="card">
      <div id="app">
        <div class="metric-grid" id="metrics"></div>
        <div class="toolbar">
          <input id="targetFilter" type="search" placeholder="Filter targets, plugins, users, endpoints, or ATT&CK IDs">
          <button type="button" id="clearFilter">Clear Filter</button>
        </div>
        <div class="dashboard">
          <section class="target-list" id="targetList" aria-label="Targets"></section>
          <section class="detail-panel card" id="detailPanel">
            <p class="empty-state">Select a target to view findings.</p>
          </section>
        </div>
      </div>
      <script id="report-data" type="application/json">
EOF
    cat "${summary_json}"
    cat <<'EOF'
      </script>
      <script>
        const reports = JSON.parse(document.getElementById("report-data").textContent);
        const metricsEl = document.getElementById("metrics");
        const listEl = document.getElementById("targetList");
        const detailEl = document.getElementById("detailPanel");
        const filterEl = document.getElementById("targetFilter");
        const clearEl = document.getElementById("clearFilter");
        let activeIndex = 0;
        let filteredReports = reports.slice();

        function escapeHtml(value) {
          return String(value ?? "")
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;");
        }

        function badgeClass(value) {
          const normalized = String(value ?? "unknown").toLowerCase().replace(/[^a-z0-9_]+/g, "_");
          return `badge-${normalized}`;
        }

        function renderBadge(value) {
          return `<span class="badge ${badgeClass(value)}">${escapeHtml(value)}</span>`;
        }

        function renderTokens(values, emptyMessage) {
          if (!values || values.length === 0) {
            return `<div class="token-wrap"><span class="token">${escapeHtml(emptyMessage)}</span></div>`;
          }
          return `<div class="token-wrap">${values.map((value) => `<span class="token">${escapeHtml(value)}</span>`).join("")}</div>`;
        }

        function metricCard(label, value) {
          return `<div class="metric"><strong>${escapeHtml(value)}</strong><span>${escapeHtml(label)}</span></div>`;
        }

        function attackSurfaceMarkup(items) {
          if (!items || items.length === 0) {
            return `<p class="empty-state">No attack-surface findings were generated for this target.</p>`;
          }
          return `<div class="surface-grid">${items.map((item) => `
            <article class="surface-card">
              <div class="badge-row">
                ${renderBadge(item.priority || "info")}
                ${(item.mitre || []).map((entry) => `<a href="${escapeHtml(entry.url)}" target="_blank" rel="noreferrer">${escapeHtml(entry.id)}</a>`).join("")}
              </div>
              <h3>${escapeHtml(item.area)}</h3>
              <p>${escapeHtml(item.summary)}</p>
              ${renderTokens(item.evidence || [], "No evidence captured")}
              <div class="mitre-row">
                ${(item.mitre || []).map((entry) => `<a href="${escapeHtml(entry.url)}" target="_blank" rel="noreferrer">${escapeHtml(entry.id)} ${escapeHtml(entry.name)}</a>`).join("")}
              </div>
            </article>
          `).join("")}</div>`;
        }

        function collectionCard(title, values, emptyMessage) {
          return `
            <article class="finding-card">
              <h3>${escapeHtml(title)}</h3>
              <p>${escapeHtml(String(values ? values.length : 0))} captured item(s)</p>
              ${renderTokens(values || [], emptyMessage)}
            </article>
          `;
        }

        function updateMetrics(items) {
          const totals = items.reduce((acc, report) => {
            acc.targets += 1;
            if (report.wordpress_detected === "yes") acc.wordpress += 1;
            if (report.xmlrpc && report.xmlrpc.xmlrpc_detected === "yes") acc.xmlrpc += 1;
            if (report.rest && report.rest.users_exposed === "yes") acc.restUsers += 1;
            acc.plugins += (report.plugins || []).length;
            acc.users += (report.users || []).length;
            return acc;
          }, {targets: 0, wordpress: 0, xmlrpc: 0, restUsers: 0, plugins: 0, users: 0});

          metricsEl.innerHTML = [
            metricCard("Targets in view", totals.targets),
            metricCard("WordPress detected", totals.wordpress),
            metricCard("XML-RPC exposed", totals.xmlrpc),
            metricCard("REST users exposed", totals.restUsers),
            metricCard("Plugins identified", totals.plugins),
            metricCard("Users discovered", totals.users)
          ].join("");
        }

        function renderList() {
          if (filteredReports.length === 0) {
            listEl.innerHTML = `<p class="empty-state">No targets match the current filter.</p>`;
            detailEl.innerHTML = `<p class="empty-state">No target selected.</p>`;
            return;
          }

          if (activeIndex >= filteredReports.length) {
            activeIndex = 0;
          }

          listEl.innerHTML = filteredReports.map((report, index) => `
            <button class="target-item ${index === activeIndex ? "active" : ""}" type="button" data-index="${index}">
              <h3>${escapeHtml(report.target)}</h3>
              <p>${escapeHtml(report.base_url)}</p>
              <div class="mini-stats">
                <span class="mini-stat">plugins ${escapeHtml((report.plugins || []).length)}</span>
                <span class="mini-stat">users ${escapeHtml((report.users || []).length)}</span>
                <span class="mini-stat">xmlrpc ${escapeHtml(report.xmlrpc?.method_count ?? 0)}</span>
              </div>
              <div class="badge-row">
                ${renderBadge(report.wordpress_detected)}
                ${renderBadge(report.xmlrpc?.xmlrpc_detected || "no")}
                ${renderBadge(report.login?.login_page_present || "no")}
              </div>
            </button>
          `).join("");

          listEl.querySelectorAll(".target-item").forEach((button) => {
            button.addEventListener("click", () => {
              activeIndex = Number(button.dataset.index || 0);
              renderList();
              renderDetail(filteredReports[activeIndex]);
            });
          });

          renderDetail(filteredReports[activeIndex]);
        }

        function renderDetail(report) {
          const authorEvidence = report.user_enumeration?.evidence?.author_archives || [];
          const userVectors = report.user_enumeration?.vectors || [];
          const loginPaths = report.login?.login_paths || [];
          const restEndpoints = report.rest?.custom_endpoints || [];
          const xmlrpcMethods = report.xmlrpc?.methods || [];
          const detailRows = [
            ["WordPress signals", (report.detection?.signals || []).join(", ") || "None"],
            ["Plugin sources", (report.plugin_discovery?.sources || []).join(", ") || "None"],
            ["User vectors", userVectors.join(", ") || "None"],
            ["REST namespaces", (report.rest?.namespaces || []).join(", ") || "None"],
            ["Login paths", loginPaths.join(", ") || "None"],
            ["XML-RPC URL", report.xmlrpc?.xmlrpc_url || "None"],
            ["Wordlist status", report.wordlist?.status || "not_requested"],
            ["WPScan status", report.wpscan?.status || "not_requested"]
          ];

          detailEl.innerHTML = `
            <div class="detail-head">
              <div>
                <p class="eyebrow">Target Findings</p>
                <h2>${escapeHtml(report.target)}</h2>
                <p>${escapeHtml(report.base_url)}</p>
                <div class="badge-row">
                  ${renderBadge(report.wordpress_detected)}
                  ${renderBadge(report.xmlrpc?.xmlrpc_detected || "no")}
                  ${renderBadge(report.login?.login_page_present || "no")}
                  ${renderBadge(report.wordlist?.status || "not_requested")}
                  ${renderBadge(report.wpscan?.status || "not_requested")}
                </div>
              </div>
              <div class="detail-links">
                <a href="${escapeHtml(report.artifact_paths?.report_html || "#")}">Open full report</a>
                <a href="${escapeHtml(report.artifact_paths?.report_json || "#")}">Open JSON</a>
                <a href="${escapeHtml(report.artifact_paths?.report_csv || "#")}">Open CSV</a>
              </div>
            </div>
            <div class="detail-grid">
              <article class="detail-card">
                <h3>High-Level Counts</h3>
                <div class="mini-stats">
                  <span class="mini-stat">plugins ${escapeHtml((report.plugins || []).length)}</span>
                  <span class="mini-stat">users ${escapeHtml((report.users || []).length)}</span>
                  <span class="mini-stat">xmlrpc methods ${escapeHtml(report.xmlrpc?.method_count ?? 0)}</span>
                  <span class="mini-stat">rest endpoints ${escapeHtml(restEndpoints.length)}</span>
                </div>
              </article>
              <article class="detail-card">
                <h3>Authentication Surface</h3>
                <div class="badge-row">
                  ${renderBadge(report.login?.login_page_present || "no")}
                  ${renderBadge(report.login?.invalid_login_response || "no")}
                  ${renderBadge(report.login?.rate_limiting_signals || "no")}
                </div>
                ${renderTokens(loginPaths, "No login paths captured")}
              </article>
              <article class="detail-card">
                <h3>User POE</h3>
                <p>Evidence of public user discovery via REST, authors, sitemap, or feed output.</p>
                ${renderTokens([
                  ...(report.user_enumeration?.evidence?.rest_users || []).map((item) => `rest-user:${item}`),
                  ...authorEvidence.map((item) => `author:${item}`),
                  ...(report.user_enumeration?.evidence?.sitemap_authors || []).map((item) => `sitemap-author:${item}`),
                  ...(report.user_enumeration?.evidence?.feed_authors || []).map((item) => `feed-creator:${item}`)
                ], "No user evidence captured")}
              </article>
            </div>
            <section>
              <p class="eyebrow">ATT&CK-Informed Exposure Map</p>
              ${attackSurfaceMarkup(report.attack_surface)}
            </section>
            <section>
              <p class="eyebrow">Detailed Findings</p>
              <div class="finding-grid">
                ${collectionCard("Plugins", report.plugins || [], "No plugin identifiers captured")}
                ${collectionCard("Users", report.users || [], "No users captured")}
                ${collectionCard("User Enumeration Vectors", userVectors, "No user enumeration vectors captured")}
                ${collectionCard("Author Archive POE", authorEvidence, "No author archive evidence captured")}
                ${collectionCard("REST Custom Endpoints", restEndpoints, "No custom endpoints captured")}
                ${collectionCard("XML-RPC Methods", xmlrpcMethods, "No XML-RPC methods captured")}
              </div>
            </section>
            <table class="module-table">
              <tbody>
                ${detailRows.map(([label, value]) => `<tr><th>${escapeHtml(label)}</th><td>${escapeHtml(value)}</td></tr>`).join("")}
              </tbody>
            </table>
          `;
        }

        function reportHaystack(report) {
          return JSON.stringify({
            target: report.target,
            base_url: report.base_url,
            plugins: report.plugins,
            users: report.users,
            user_vectors: report.user_enumeration?.vectors,
            author_poe: report.user_enumeration?.evidence,
            rest: report.rest,
            xmlrpc: report.xmlrpc,
            login: report.login,
            attack_surface: report.attack_surface?.map((item) => ({
              area: item.area,
              summary: item.summary,
              evidence: item.evidence,
              mitre: item.mitre?.map((entry) => `${entry.id} ${entry.name}`)
            }))
          }).toLowerCase();
        }

        function applyFilter() {
          const term = filterEl.value.trim().toLowerCase();
          filteredReports = term
            ? reports.filter((report) => reportHaystack(report).includes(term))
            : reports.slice();
          activeIndex = 0;
          updateMetrics(filteredReports);
          renderList();
        }

        clearEl.addEventListener("click", () => {
          filterEl.value = "";
          applyFilter();
        });
        filterEl.addEventListener("input", applyFilter);

        updateMetrics(filteredReports);
        renderList();
      </script>
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
    jq -n '{plugin_count: 0, plugins: [], sources: [], custom_namespaces: [], plugin_api_status: "not_requested"}' > "${target_dir}/plugins.json"
  fi

  if [[ "${RUN_REST}" == "yes" ]]; then
    "${SCRIPT_DIR}/rest_api_scan.sh" "${base_url}" "${target_dir}"
  else
    jq -n '{custom_endpoints: [], namespaces: [], endpoints: {root: "not_requested", users: "not_requested", posts: "not_requested"}, users_exposed: "no", posts_exposed: "no", drafts_exposed: "no"}' > "${target_dir}/rest_endpoints.json"
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
    jq -n '{login_page_present: "no", invalid_login_response: "no", rate_limiting_signals: "no", wp_admin_endpoint: "no", login_paths: []}' > "${target_dir}/login_surface.json"
  fi

  if [[ "${RUN_USERS}" == "yes" ]]; then
    "${SCRIPT_DIR}/user_enum.sh" "${base_url}" "${target_dir}"
  else
    : > "${target_dir}/users.txt"
    jq -n '{user_count: 0, users: [], vectors: [], evidence: {rest_users: [], author_archives: [], sitemap_authors: [], feed_authors: []}, sources: {rest_api: "not_requested", sitemap: "not_requested", feed: "not_requested"}}' > "${target_dir}/users.json"
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
