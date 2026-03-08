# Architecture

## Design

The framework uses Bash as the primary orchestrator and keeps each reconnaissance concern in its own script:

- `wp_scan.sh` drives execution, target fan-out, optional integrations, and summary generation
- `detect_wordpress.sh` establishes the working base URL and WordPress confidence
- `plugin_enum.sh` collects plugin indicators from HTML, JavaScript, `robots.txt`, and REST hints
- `rest_api_scan.sh` maps namespaces, routes, and common public endpoints
- `xmlrpc_scan.sh` inspects XML-RPC reachability and method exposure
- `login_scan.sh` checks the public login surface
- `user_enum.sh` consolidates usernames from multiple passive sources
- `cewl_wordlist.sh` optionally captures public vocabulary when CeWL is installed
- `report_generator.sh` renders per-target JSON, CSV, and HTML reports

## Data Flow

1. The orchestrator reads `targets.txt`.
2. Each target is normalized into a stable directory under `reports/`.
3. WordPress detection runs first and selects the base URL used by the remaining modules.
4. Modules write raw artifacts and structured JSON into the target directory.
5. `report_generator.sh` composes those artifacts into `report.json`, `report.csv`, and `report.html`.
6. `wp_scan.sh` writes `reports/summary.json`, `reports/summary.csv`, and `reports/index.html`.

## Extensibility

New modules can be added without changing the overall pipeline shape:

- accept `base_url` and `output_dir`
- write one structured JSON file plus any module-specific artifacts
- keep request behavior low-impact and deterministic
- let the report generator consume the result file if it should appear in summaries

## Operational Notes

- Shared helper logic lives in `scanner/common.sh`.
- Optional tools are detected dynamically and skipped safely when absent.
- Reports are file-based so they can be consumed by shell tooling, spreadsheets, or downstream automation.
