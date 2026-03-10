#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET="${1:?target is required}"
OUTPUT_DIR="${2:?output directory is required}"

DETECTION_FILE="${OUTPUT_DIR}/wordpress_detection.json"
PLUGINS_FILE="${OUTPUT_DIR}/plugins.txt"
PLUGINS_META_FILE="${OUTPUT_DIR}/plugins.json"
REST_FILE="${OUTPUT_DIR}/rest_endpoints.json"
XMLRPC_FILE="${OUTPUT_DIR}/xmlrpc_summary.json"
LOGIN_FILE="${OUTPUT_DIR}/login_surface.json"
USERS_FILE="${OUTPUT_DIR}/users.txt"
USERS_META_FILE="${OUTPUT_DIR}/users.json"
WORDLIST_FILE="${OUTPUT_DIR}/wordlist.json"
WPSCAN_FILE="${OUTPUT_DIR}/wpscan.json"
TEMP_DIR="$(mktemp -d)"

PLUGINS_JSON="$(json_array_from_lines_file "${PLUGINS_FILE}")"
USERS_JSON="$(json_array_from_lines_file "${USERS_FILE}")"
DETECTION_JSON="$(cat "${DETECTION_FILE}")"
PLUGINS_META_JSON="$(cat "${PLUGINS_META_FILE}")"
REST_JSON="$(cat "${REST_FILE}")"
XMLRPC_JSON="$(cat "${XMLRPC_FILE}")"
LOGIN_JSON="$(cat "${LOGIN_FILE}")"
USERS_META_JSON="$(cat "${USERS_META_FILE}")"
WORDLIST_JSON="$(cat "${WORDLIST_FILE}")"

if [[ -f "${WPSCAN_FILE}" ]]; then
  WPSCAN_JSON="$(cat "${WPSCAN_FILE}")"
else
  WPSCAN_JSON='{"status":"not_requested"}'
fi

jq -n \
  --arg target "${TARGET}" \
  --argjson detection "${DETECTION_JSON}" \
  --argjson plugins "${PLUGINS_JSON}" \
  --argjson plugin_meta "${PLUGINS_META_JSON}" \
  --argjson rest "${REST_JSON}" \
  --argjson xmlrpc "${XMLRPC_JSON}" \
  --argjson login "${LOGIN_JSON}" \
  --argjson users "${USERS_JSON}" \
  --argjson user_meta "${USERS_META_JSON}" \
  --argjson wordlist "${WORDLIST_JSON}" \
  --argjson wpscan "${WPSCAN_JSON}" \
  '{
    target: $target,
    base_url: $detection.base_url,
    wordpress_detected: $detection.wordpress_detected,
    detection: $detection,
    plugins: $plugins,
    plugin_discovery: $plugin_meta,
    rest: $rest,
    xmlrpc: $xmlrpc,
    login: ($login + {login_paths: ($login.login_paths // [])}),
    users: $users,
    user_enumeration: $user_meta,
    wordlist: $wordlist,
    wpscan: $wpscan
  }
  | .attack_surface = [
      if .wordpress_detected == "yes" then {
        area: "WordPress Fingerprinting",
        priority: "info",
        summary: "Public fingerprints confirm a WordPress deployment and establish the platform baseline for follow-on review.",
        evidence: ((.detection.signals // []) | unique),
        mitre: [
          {
            id: "T1595",
            name: "Active Scanning",
            url: "https://attack.mitre.org/techniques/T1595"
          },
          {
            id: "T1592.002",
            name: "Gather Victim Host Information: Software",
            url: "https://attack.mitre.org/techniques/T1592/002/"
          }
        ]
      } else empty end,
      if (.plugins | length) > 0 then {
        area: "Plugin Exposure",
        priority: "medium",
        summary: "Public plugin identifiers and namespaces expose the WordPress software stack and likely extension surface.",
        evidence: ([
          (.plugins[]?),
          (.plugin_discovery.custom_namespaces[]?)
        ] | map(select(length > 0)) | unique),
        mitre: [
          {
            id: "T1592.002",
            name: "Gather Victim Host Information: Software",
            url: "https://attack.mitre.org/techniques/T1592/002/"
          }
        ]
      } else empty end,
      if ((.users | length) > 0 or (.user_enumeration.vectors | length) > 0 or .rest.users_exposed == "yes") then {
        area: "User Enumeration",
        priority: (if .rest.users_exposed == "yes" then "high" else "medium" end),
        summary: "Usernames or author identities are externally discoverable through public WordPress paths, feeds, or API responses.",
        evidence: ([
          (.user_enumeration.vectors[]?),
          (if .rest.users_exposed == "yes" then "/wp-json/wp/v2/users" else empty end),
          (.user_enumeration.evidence.rest_users[]? | "rest-user:" + .),
          (.user_enumeration.evidence.author_archives[]? | "author:" + .),
          (.user_enumeration.evidence.sitemap_authors[]? | "sitemap-author:" + .),
          (.user_enumeration.evidence.feed_authors[]? | "feed-creator:" + .)
        ] | map(select(length > 0)) | unique),
        mitre: [
          {
            id: "T1589",
            name: "Gather Victim Identity Information",
            url: "https://attack.mitre.org/techniques/T1589"
          },
          {
            id: "T1595",
            name: "Active Scanning",
            url: "https://attack.mitre.org/techniques/T1595"
          }
        ]
      } else empty end,
      if ((.rest.custom_endpoints | length) > 0 or (.rest.namespaces | length) > 0 or .rest.users_exposed == "yes" or .rest.posts_exposed == "yes" or .rest.drafts_exposed == "yes") then {
        area: "REST API Surface",
        priority: (if .rest.drafts_exposed == "yes" then "high" else "medium" end),
        summary: "Public REST namespaces and routes reveal application features, user data paths, and plugin-specific endpoints.",
        evidence: ([
          (.rest.namespaces[]?),
          (.rest.custom_endpoints[]?),
          (if .rest.users_exposed == "yes" then "users endpoint exposed" else empty end),
          (if .rest.posts_exposed == "yes" then "posts endpoint exposed" else empty end),
          (if .rest.drafts_exposed == "yes" then "draft content exposed" else empty end)
        ] | map(select(length > 0)) | unique),
        mitre: [
          {
            id: "T1590",
            name: "Gather Victim Network Information",
            url: "https://attack.mitre.org/techniques/T1590/"
          },
          {
            id: "T1592.002",
            name: "Gather Victim Host Information: Software",
            url: "https://attack.mitre.org/techniques/T1592/002/"
          }
        ]
      } else empty end,
      if .xmlrpc.xmlrpc_detected == "yes" then {
        area: "XML-RPC Surface",
        priority: (if (.xmlrpc.multicall == "yes" or .xmlrpc.auth_endpoint_exposed == "yes" or .xmlrpc.pingback == "yes") then "high" else "medium" end),
        summary: "The XML-RPC interface is reachable and exposes callable methods that expand the remote application surface.",
        evidence: ([
          .xmlrpc.xmlrpc_url,
          (if .xmlrpc.multicall == "yes" then "system.multicall enabled" else empty end),
          (if .xmlrpc.pingback == "yes" then "pingback.ping enabled" else empty end),
          (if .xmlrpc.auth_endpoint_exposed == "yes" then "wp.getUsersBlogs exposed" else empty end),
          (.xmlrpc.methods[]?)
        ] | map(select(length > 0)) | unique),
        mitre: [
          {
            id: "T1595",
            name: "Active Scanning",
            url: "https://attack.mitre.org/techniques/T1595"
          },
          {
            id: "T1592.002",
            name: "Gather Victim Host Information: Software",
            url: "https://attack.mitre.org/techniques/T1592/002/"
          }
        ]
      } else empty end,
      if (.login.login_page_present == "yes" or .login.wp_admin_endpoint == "yes") then {
        area: "Authentication Surface",
        priority: (if .login.invalid_login_response == "yes" then "medium" else "info" end),
        summary: "Public login and administration paths disclose the authentication surface and observable response behavior.",
        evidence: ([
          (.login.login_paths[]?),
          (if .login.invalid_login_response == "yes" then "invalid-login response observed" else empty end),
          (if .login.rate_limiting_signals == "yes" then "rate-limiting signal observed" else empty end)
        ] | map(select(length > 0)) | unique),
        mitre: [
          {
            id: "T1595",
            name: "Active Scanning",
            url: "https://attack.mitre.org/techniques/T1595"
          },
          {
            id: "T1589",
            name: "Gather Victim Identity Information",
            url: "https://attack.mitre.org/techniques/T1589"
          }
        ]
      } else empty end
    ]' > "${OUTPUT_DIR}/report.json"

render_collection_html() {
  local title="$1"
  local source_file="$2"
  local empty_message="$3"
  local class_name="${4:-collection}"
  local item=""

  printf '<section class="collection-card %s">\n' "${class_name}"
  printf '  <div class="collection-head"><h3>%s</h3><span>%s</span></div>\n' "$(html_escape "${title}")" "$(wc -l < "${source_file}" | tr -d ' ')"
  printf '  <div class="token-wrap">\n'

  if [[ -s "${source_file}" ]]; then
    while IFS= read -r item; do
      [[ -z "${item}" ]] && continue
      printf '    <span class="token">%s</span>\n' "$(html_escape "${item}")"
    done < "${source_file}"
  else
    printf '    <span class="token muted">%s</span>\n' "$(html_escape "${empty_message}")"
  fi

  printf '  </div>\n'
  printf '</section>\n'
}

render_attack_surface_html() {
  local report_file="$1"
  local item_json=""
  local area=""
  local priority=""
  local summary=""
  local evidence_text=""
  local mitre_links=""
  local evidence_count=""

  while IFS= read -r item_json; do
    [[ -z "${item_json}" ]] && continue
    area="$(jq -r '.area' <<<"${item_json}")"
    priority="$(jq -r '.priority' <<<"${item_json}")"
    summary="$(jq -r '.summary' <<<"${item_json}")"
    evidence_count="$(jq -r '.evidence | length' <<<"${item_json}")"
    evidence_text="$(jq -r '.evidence[]?' <<<"${item_json}" | sed '/^$/d' | while IFS= read -r value; do
      printf '<span class="token">%s</span>' "$(html_escape "${value}")"
    done)"
    mitre_links="$(jq -c '.mitre[]?' <<<"${item_json}" | while IFS= read -r mitre_item; do
      printf '<a href="%s" target="_blank" rel="noreferrer">%s</a>' \
        "$(html_escape "$(jq -r '.url' <<<"${mitre_item}")")" \
        "$(html_escape "$(jq -r '.id + " " + .name' <<<"${mitre_item}")")"
    done)"

    printf '<article class="attack-card priority-%s">\n' "$(html_escape "${priority}")"
    printf '  <div class="attack-head"><div><p class="attack-kicker">%s</p><h3>%s</h3></div><span class="badge badge-%s">%s</span></div>\n' \
      "ATT&CK-Informed Exposure" \
      "$(html_escape "${area}")" \
      "$(html_escape "${priority}")" \
      "$(html_escape "${priority}")"
    printf '  <p class="attack-summary">%s</p>\n' "$(html_escape "${summary}")"
    printf '  <div class="attack-meta"><strong>Evidence:</strong> %s</div>\n' "$(html_escape "${evidence_count}")"
    printf '  <div class="token-wrap token-wrap-tight">%s</div>\n' "${evidence_text:-<span class=\"token muted\">No evidence captured</span>}"
    printf '  <div class="mitre-links">%s</div>\n' "${mitre_links}"
    printf '</article>\n'
  done < <(jq -c '.attack_surface[]?' "${report_file}")
}

jq -r '.plugins[]?' "${OUTPUT_DIR}/report.json" > "${TEMP_DIR}/plugins.txt"
jq -r '.users[]?' "${OUTPUT_DIR}/report.json" > "${TEMP_DIR}/users.txt"
jq -r '.user_enumeration.vectors[]?' "${OUTPUT_DIR}/report.json" > "${TEMP_DIR}/user_vectors.txt"
jq -r '.login.login_paths[]?' "${OUTPUT_DIR}/report.json" > "${TEMP_DIR}/login_paths.txt"
jq -r '.rest.custom_endpoints[]?' "${OUTPUT_DIR}/report.json" > "${TEMP_DIR}/rest_endpoints.txt"
jq -r '.xmlrpc.methods[]?' "${OUTPUT_DIR}/report.json" > "${TEMP_DIR}/xmlrpc_methods.txt"
jq -r '.user_enumeration.evidence.author_archives[]?' "${OUTPUT_DIR}/report.json" > "${TEMP_DIR}/author_archives.txt"

XMLRPC_DETECTED="$(jq -r '.xmlrpc.xmlrpc_detected' "${OUTPUT_DIR}/report.json")"
AUTH_EXPOSED="$(jq -r '.xmlrpc.auth_endpoint_exposed' "${OUTPUT_DIR}/report.json")"
LOGIN_ERROR_RESPONSE="$(jq -r '.login.invalid_login_response' "${OUTPUT_DIR}/report.json")"
REST_USERS_EXPOSED="$(jq -r '.rest.users_exposed' "${OUTPUT_DIR}/report.json")"
REST_POSTS_EXPOSED="$(jq -r '.rest.posts_exposed' "${OUTPUT_DIR}/report.json")"
REST_DRAFTS_EXPOSED="$(jq -r '.rest.drafts_exposed' "${OUTPUT_DIR}/report.json")"
WP_ADMIN_ENDPOINT="$(jq -r '.login.wp_admin_endpoint' "${OUTPUT_DIR}/report.json")"

{
  printf 'target,base_url,wordpress_detected,plugin_count,user_count,xmlrpc_detected,xmlrpc_method_count,multicall,pingback,login_page_present,rate_limiting_signals,wordlist_status,wpscan_status\n'
  jq -r '[
    .target,
    .base_url,
    .wordpress_detected,
    (.plugins | length),
    (.users | length),
    .xmlrpc.xmlrpc_detected,
    .xmlrpc.method_count,
    .xmlrpc.multicall,
    .xmlrpc.pingback,
    .login.login_page_present,
    .login.rate_limiting_signals,
    .wordlist.status,
    (.wpscan.status // "not_requested")
  ] | @csv' "${OUTPUT_DIR}/report.json"
} > "${OUTPUT_DIR}/report.csv"

GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"
BASE_URL_VALUE="$(jq -r '.base_url' "${OUTPUT_DIR}/report.json")"
WORDPRESS_DETECTED="$(jq -r '.wordpress_detected' "${OUTPUT_DIR}/report.json")"
PLUGIN_COUNT="$(jq -r '.plugins | length' "${OUTPUT_DIR}/report.json")"
USER_COUNT="$(jq -r '.users | length' "${OUTPUT_DIR}/report.json")"
XMLRPC_METHOD_COUNT="$(jq -r '.xmlrpc.method_count' "${OUTPUT_DIR}/report.json")"
MULTICALL="$(jq -r '.xmlrpc.multicall' "${OUTPUT_DIR}/report.json")"
PINGBACK="$(jq -r '.xmlrpc.pingback' "${OUTPUT_DIR}/report.json")"
LOGIN_PRESENT="$(jq -r '.login.login_page_present' "${OUTPUT_DIR}/report.json")"
RATE_LIMITING="$(jq -r '.login.rate_limiting_signals' "${OUTPUT_DIR}/report.json")"
WORDLIST_STATUS="$(jq -r '.wordlist.status' "${OUTPUT_DIR}/report.json")"
WPSCAN_STATUS="$(jq -r '.wpscan.status // "not_requested"' "${OUTPUT_DIR}/report.json")"

{
  cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>wp-attack-surface-scanner report</title>
  <style>
    :root {
      --bg: #f3ede2;
      --panel: rgba(255, 251, 244, 0.94);
      --ink: #1d1d1b;
      --muted: #5b584f;
      --accent: #8e4b10;
      --accent-soft: #f2dcc1;
      --border: #d6c6b0;
      --good: #1d6a4f;
      --warn: #8a5a00;
      --bad: #8b1e1e;
      --info: #315f8f;
      --shadow: 0 16px 40px rgba(66, 47, 22, 0.08);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "IBM Plex Sans", "Avenir Next", sans-serif;
      background:
        radial-gradient(circle at top left, rgba(142, 75, 16, 0.16), transparent 28%),
        radial-gradient(circle at top right, rgba(70, 54, 30, 0.08), transparent 22%),
        linear-gradient(180deg, #efe2cf 0%, var(--bg) 100%);
      color: var(--ink);
    }
    main {
      max-width: 1260px;
      margin: 0 auto;
      padding: 32px 20px 48px;
    }
    .card {
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 22px;
      padding: 22px;
      margin-bottom: 18px;
      box-shadow: var(--shadow);
      backdrop-filter: blur(8px);
    }
    .hero {
      display: grid;
      grid-template-columns: minmax(0, 2fr) minmax(320px, 1fr);
      gap: 18px;
      align-items: stretch;
    }
    .hero h1 {
      margin: 0 0 10px;
      font-size: 2.4rem;
      line-height: 1.02;
    }
    .hero p {
      margin: 6px 0;
      color: var(--muted);
      overflow-wrap: anywhere;
    }
    .hero-meta {
      display: grid;
      gap: 14px;
    }
    .hero-note {
      padding: 16px;
      border-radius: 18px;
      background: linear-gradient(135deg, rgba(142, 75, 16, 0.14), rgba(255, 247, 238, 0.8));
      border: 1px solid rgba(142, 75, 16, 0.14);
    }
    .eyebrow {
      margin: 0 0 8px;
      font-size: 0.82rem;
      text-transform: uppercase;
      letter-spacing: 0.12em;
      color: var(--accent);
      font-weight: 700;
    }
    .metric-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(145px, 1fr));
      gap: 12px;
    }
    .metric {
      padding: 16px;
      border-radius: 18px;
      background: rgba(255, 255, 255, 0.55);
      border: 1px solid rgba(214, 198, 176, 0.9);
      min-height: 104px;
    }
    .metric strong {
      display: block;
      font-size: 1.9rem;
      line-height: 1;
      margin-bottom: 10px;
    }
    .metric span {
      display: block;
      color: var(--muted);
      font-size: 0.92rem;
      overflow-wrap: anywhere;
    }
    .status-grid,
    .collections-grid,
    .attack-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 16px;
    }
    .status-list {
      display: grid;
      gap: 10px;
    }
    .status-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 14px;
      padding: 12px 14px;
      border-radius: 16px;
      background: rgba(255, 255, 255, 0.56);
      border: 1px solid rgba(214, 198, 176, 0.9);
    }
    .status-row span:first-child {
      color: var(--muted);
      font-size: 0.95rem;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      padding: 6px 11px;
      border-radius: 999px;
      font-weight: 700;
      font-size: 0.84rem;
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
    .collection-card,
    .attack-card {
      padding: 18px;
      border-radius: 18px;
      background: rgba(255, 255, 255, 0.56);
      border: 1px solid rgba(214, 198, 176, 0.9);
      min-height: 280px;
      display: flex;
      flex-direction: column;
      gap: 14px;
    }
    .priority-high { border-color: rgba(139, 30, 30, 0.25); }
    .priority-medium { border-color: rgba(29, 106, 79, 0.25); }
    .priority-info { border-color: rgba(91, 88, 79, 0.18); }
    .collection-head,
    .attack-head {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 12px;
    }
    .collection-head h3,
    .attack-head h3 {
      margin: 0;
      font-size: 1.05rem;
    }
    .collection-head span,
    .attack-kicker {
      color: var(--muted);
      font-size: 0.9rem;
      margin: 0 0 6px;
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }
    .attack-summary,
    .attack-meta {
      margin: 0;
      color: var(--muted);
      line-height: 1.5;
    }
    .token-wrap {
      display: flex;
      flex-wrap: wrap;
      align-content: flex-start;
      gap: 8px;
      max-height: 320px;
      overflow: auto;
      padding-right: 4px;
    }
    .token-wrap-tight {
      max-height: 170px;
    }
    .token {
      display: inline-flex;
      max-width: 100%;
      padding: 8px 10px;
      border-radius: 12px;
      background: var(--accent-soft);
      color: var(--ink);
      font-size: 0.88rem;
      line-height: 1.35;
      overflow-wrap: anywhere;
      word-break: break-word;
    }
    .token.muted {
      background: rgba(91, 88, 79, 0.08);
      color: var(--muted);
    }
    .mitre-links {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
    }
    .mitre-links a {
      color: var(--info);
      text-decoration: none;
      font-weight: 700;
      overflow-wrap: anywhere;
    }
    .module-table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
    }
    .module-table th,
    .module-table td {
      padding: 12px 10px;
      border-bottom: 1px solid var(--border);
      text-align: left;
      vertical-align: top;
      overflow-wrap: anywhere;
    }
    .module-table th {
      width: 34%;
      color: var(--muted);
      font-weight: 600;
    }
    .module-table td:last-child {
      font-family: "IBM Plex Mono", "SFMono-Regular", monospace;
      font-size: 0.88rem;
    }
    .module-table tr:last-child th,
    .module-table tr:last-child td {
      border-bottom: 0;
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
    @media (max-width: 840px) {
      .hero {
        grid-template-columns: 1fr;
      }
      .collection-card,
      .attack-card {
        min-height: auto;
      }
      .token-wrap {
        max-height: none;
      }
      .module-table {
        table-layout: auto;
      }
    }
  </style>
</head>
<body>
  <main>
    <section class="hero">
      <article class="card">
        <p class="eyebrow">Assessment Snapshot</p>
        <h1>WordPress Attack Surface Report</h1>
        <p>Target: $(html_escape "${TARGET}")</p>
        <p>Base URL: $(html_escape "${BASE_URL_VALUE}")</p>
        <p>Generated: $(html_escape "${GENERATED_AT}")</p>
        <p>Created by: Sternly Simon</p>
      </article>
      <aside class="hero-meta">
        <section class="card hero-note">
          <p class="eyebrow">Executive Summary</p>
          <p>WordPress detection is <strong>$(html_escape "${WORDPRESS_DETECTED}")</strong>. This report consolidates public plugin signals, exposed users, REST surface, XML-RPC capability, login paths, and ATT&CK-informed operator notes into a single review view.</p>
        </section>
        <section class="card hero-note">
          <p class="eyebrow">Operator Notes</p>
          <p>The ATT&amp;CK labels below are analyst-side reconnaissance mappings for prioritization. They are not claims of target compromise or adversary attribution.</p>
        </section>
      </aside>
    </section>

    <section class="card">
      <p class="eyebrow">High-Level Metrics</p>
      <div class="metric-grid">
        <div class="metric"><strong>${PLUGIN_COUNT}</strong><span>Plugins identified</span></div>
        <div class="metric"><strong>${USER_COUNT}</strong><span>Users exposed</span></div>
        <div class="metric"><strong>${XMLRPC_METHOD_COUNT}</strong><span>XML-RPC methods</span></div>
        <div class="metric"><strong>${MULTICALL}</strong><span>Multicall available</span></div>
        <div class="metric"><strong>${PINGBACK}</strong><span>Pingback available</span></div>
        <div class="metric"><strong>${LOGIN_PRESENT}</strong><span>Login surface present</span></div>
        <div class="metric"><strong>${RATE_LIMITING}</strong><span>Rate-limiting signal</span></div>
        <div class="metric"><strong>${WORDLIST_STATUS}</strong><span>CeWL status</span></div>
        <div class="metric"><strong>${WPSCAN_STATUS}</strong><span>WPScan status</span></div>
      </div>
    </section>

    <section class="card">
      <p class="eyebrow">Module Status</p>
      <div class="status-grid">
        <div class="status-list">
          <div class="status-row"><span>WordPress detected</span><span class="badge badge-$(html_escape "${WORDPRESS_DETECTED}")">$(html_escape "${WORDPRESS_DETECTED}")</span></div>
          <div class="status-row"><span>REST users exposed</span><span class="badge badge-$(html_escape "${REST_USERS_EXPOSED}")">$(html_escape "${REST_USERS_EXPOSED}")</span></div>
          <div class="status-row"><span>REST posts exposed</span><span class="badge badge-$(html_escape "${REST_POSTS_EXPOSED}")">$(html_escape "${REST_POSTS_EXPOSED}")</span></div>
          <div class="status-row"><span>REST drafts exposed</span><span class="badge badge-$(html_escape "${REST_DRAFTS_EXPOSED}")">$(html_escape "${REST_DRAFTS_EXPOSED}")</span></div>
          <div class="status-row"><span>XML-RPC detected</span><span class="badge badge-$(html_escape "${XMLRPC_DETECTED}")">$(html_escape "${XMLRPC_DETECTED}")</span></div>
          <div class="status-row"><span>XML-RPC auth endpoint</span><span class="badge badge-$(html_escape "${AUTH_EXPOSED}")">$(html_escape "${AUTH_EXPOSED}")</span></div>
        </div>
        <div class="status-list">
          <div class="status-row"><span>Login page present</span><span class="badge badge-$(html_escape "${LOGIN_PRESENT}")">$(html_escape "${LOGIN_PRESENT}")</span></div>
          <div class="status-row"><span>Login error response</span><span class="badge badge-$(html_escape "${LOGIN_ERROR_RESPONSE}")">$(html_escape "${LOGIN_ERROR_RESPONSE}")</span></div>
          <div class="status-row"><span>Rate limiting</span><span class="badge badge-$(html_escape "${RATE_LIMITING}")">$(html_escape "${RATE_LIMITING}")</span></div>
          <div class="status-row"><span>WP-Admin endpoint</span><span class="badge badge-$(html_escape "${WP_ADMIN_ENDPOINT}")">$(html_escape "${WP_ADMIN_ENDPOINT}")</span></div>
          <div class="status-row"><span>CeWL wordlist</span><span class="badge badge-$(html_escape "${WORDLIST_STATUS}")">$(html_escape "${WORDLIST_STATUS}")</span></div>
          <div class="status-row"><span>WPScan</span><span class="badge badge-$(html_escape "${WPSCAN_STATUS}")">$(html_escape "${WPSCAN_STATUS}")</span></div>
        </div>
      </div>
    </section>

    <section class="card">
      <p class="eyebrow">ATT&CK-Informed Exposure Map</p>
      <div class="attack-grid">
$(render_attack_surface_html "${OUTPUT_DIR}/report.json")
      </div>
    </section>

    <section class="card">
      <p class="eyebrow">Collections</p>
      <div class="collections-grid">
$(render_collection_html "Plugins" "${TEMP_DIR}/plugins.txt" "No plugin identifiers captured")
$(render_collection_html "Users" "${TEMP_DIR}/users.txt" "No users captured")
$(render_collection_html "User Enumeration Vectors" "${TEMP_DIR}/user_vectors.txt" "No user enumeration vectors captured")
$(render_collection_html "Login Paths" "${TEMP_DIR}/login_paths.txt" "No login paths captured")
$(render_collection_html "Author Archive POE" "${TEMP_DIR}/author_archives.txt" "No author archive evidence captured")
$(render_collection_html "REST Custom Endpoints" "${TEMP_DIR}/rest_endpoints.txt" "No custom endpoints captured")
$(render_collection_html "XML-RPC Methods" "${TEMP_DIR}/xmlrpc_methods.txt" "No XML-RPC methods captured")
      </div>
    </section>

    <section class="card">
      <p class="eyebrow">Module Details</p>
      <table class="module-table">
        <tbody>
          <tr><th>WordPress signals</th><td>$(jq -r '.detection.signals | if length > 0 then join(", ") else "None" end' "${OUTPUT_DIR}/report.json")</td></tr>
          <tr><th>Plugin discovery sources</th><td>$(jq -r '.plugin_discovery.sources | if length > 0 then join(", ") else "None" end' "${OUTPUT_DIR}/report.json")</td></tr>
          <tr><th>REST namespaces</th><td>$(jq -r '.rest.namespaces | if length > 0 then join(", ") else "None" end' "${OUTPUT_DIR}/report.json")</td></tr>
          <tr><th>User vectors</th><td>$(jq -r '.user_enumeration.vectors | if length > 0 then join(", ") else "None" end' "${OUTPUT_DIR}/report.json")</td></tr>
          <tr><th>Login paths</th><td>$(jq -r '.login.login_paths | if length > 0 then join(", ") else "None" end' "${OUTPUT_DIR}/report.json")</td></tr>
          <tr><th>XML-RPC URL</th><td>$(jq -r '.xmlrpc.xmlrpc_url' "${OUTPUT_DIR}/report.json")</td></tr>
          <tr><th>Wordlist output</th><td>$(jq -r '.wordlist.output_file // "Not generated"' "${OUTPUT_DIR}/report.json")</td></tr>
          <tr><th>WPScan status</th><td>$(jq -r '.wpscan.status // "not_requested"' "${OUTPUT_DIR}/report.json")</td></tr>
        </tbody>
      </table>
    </section>
    <footer>
      <p>Powered by <a href="https://www.cyberdevelopment.company">Cyber Development</a></p>
    </footer>
  </main>
</body>
</html>
EOF
} > "${OUTPUT_DIR}/report.html"
