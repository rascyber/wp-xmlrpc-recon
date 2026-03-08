# wp-xmlrpc-recon

`wp-xmlrpc-recon` is a Bash-first reconnaissance scanner for identifying exposed WordPress XML-RPC endpoints during authorized security testing. It detects reachable `xmlrpc.php` endpoints, enumerates supported methods, checks for `system.multicall`, flags `pingback.ping`, probes `wp.getUsersBlogs`, and exports timestamped CSV and HTML reports.

## Project Overview

The project is designed for fast triage during bug bounty and penetration testing engagements where XML-RPC exposure may expand the attack surface. The scanner favors safe defaults:

- rate-limited requests
- read-only reconnaissance
- portable Bash implementation for Linux and macOS
- timestamped report directories for repeatable engagements

## XML-RPC Security Background

WordPress XML-RPC is a remote procedure call interface historically used for publishing, mobile apps, and integrations. It remains useful operationally, but it also introduces reconnaissance opportunities:

- `system.listMethods` reveals callable XML-RPC methods
- `system.multicall` can amplify authentication attempts if available
- `pingback.ping` can enable reflected network activity
- `wp.getUsersBlogs` indicates whether the authentication surface is exposed

The scanner focuses on identifying those conditions without attempting brute force or disruptive validation.

## Installation

### Prerequisites

- Bash
- `curl`
- `jq`

### Clone

```bash
git clone https://github.com/rascyber/wp-xmlrpc-recon.git
cd wp-xmlrpc-recon
chmod +x scanner/xmlrpc_scanner.sh
```

## Usage

Basic usage:

```bash
./scanner/xmlrpc_scanner.sh -i examples/targets.txt
```

Common options:

```bash
./scanner/xmlrpc_scanner.sh \
  -i examples/targets.txt \
  -o reports \
  -d 1 \
  -t 10
```

Arguments:

- `-i` path to the targets file
- `-o` output root directory for timestamped reports
- `-d` delay in seconds between HTTP requests
- `-t` request timeout in seconds
- `-u` custom user agent
- `-h` show help

Targets can be:

- full URLs such as `https://example.com`
- explicit XML-RPC paths such as `https://example.com/xmlrpc.php`
- hostnames such as `example.com`

When a scheme is omitted, the scanner tries HTTPS first and then HTTP.

## Example Scan

```bash
./scanner/xmlrpc_scanner.sh -i tests/test_targets.txt -o reports
```

Example output:

```text
[2026-03-08 10:00:00] Loaded 2 target(s) from tests/test_targets.txt
[2026-03-08 10:00:00] Scanning http://127.0.0.1:18080
[2026-03-08 10:00:02] Scanning http://127.0.0.1:18081
[2026-03-08 10:00:04] Scan complete
[2026-03-08 10:00:04] CSV report: reports/scan_20260308_100000/xmlrpc_scan.csv
[2026-03-08 10:00:04] HTML report: reports/scan_20260308_100000/xmlrpc_scan.html
```

## Report Explanation

Each scan creates a timestamped directory under the chosen output root:

- `xmlrpc_scan.csv`: tabular output for spreadsheets and tooling
- `xmlrpc_scan.html`: quick human-readable report
- `scan_summary.json`: compact metadata and counts

Key columns:

- `endpoint_status`: whether an XML-RPC response was observed
- `list_methods_status`: whether `system.listMethods` returned a method list
- `method_count`: number of enumerated methods
- `multicall_enabled`: whether `system.multicall` appears exposed
- `pingback_enabled`: whether `pingback.ping` appears exposed
- `auth_endpoint_exposed`: whether `wp.getUsersBlogs` appears callable

See the sample report in [reports/sample_report.html](/Users/sternsleuth/Development/wp-xmlrpc-recon/reports/sample_report.html).

## Ethical Usage Statement

Use this tool only against systems you own or are explicitly authorized to assess. The scanner is intended for defensive security, bug bounty reconnaissance within program rules, and internal validation. Do not use it for credential attacks, denial of service, or unauthorized access.

## Branch Strategy

Recommended repository branches:

- `main`: stable releases
- `dev`: active development
- `scanner-engine`: experimental scanning changes

## Release Strategy

Create a release tag after validation:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Typical bootstrap flow:

```bash
git init
git add .
git commit -m "initial xmlrpc scanner"
git branch dev
git branch scanner-engine
git tag v1.0.0
```

## CI/CD

GitHub Actions validates the Bash script and runs an integration scan against local mock XML-RPC services defined in the workflow at [.github/workflows/ci.yml](/Users/sternsleuth/Development/wp-xmlrpc-recon/.github/workflows/ci.yml).

## Roadmap

- Docker packaging
- Nuclei templates
- Burp integration
- WordPress fingerprinting module
- JSON report mode

## Contributing

Contribution guidelines live in [CONTRIBUTING.md](/Users/sternsleuth/Development/wp-xmlrpc-recon/CONTRIBUTING.md).

## License

Released under the MIT License. See [LICENSE](/Users/sternsleuth/Development/wp-xmlrpc-recon/LICENSE).
