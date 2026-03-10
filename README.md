# wp-attack-surface-scanner

`wp-attack-surface-scanner` is a modular WordPress reconnaissance framework for authorized bug bounty and penetration testing workflows. It maps the public attack surface of WordPress deployments by chaining detection, plugin discovery, REST API analysis, XML-RPC testing, login surface checks, user enumeration, optional public-content wordlist generation with CeWL, and optional passive WPScan integration.

## Overview

The framework is Bash-first and organized as composable modules under `scanner/`. Each target gets its own report directory with raw artifacts and a rendered HTML/JSON/CSV summary.

Capabilities:

- WordPress detection using content paths, `wp-json`, generator tags, and login markers
- Plugin enumeration from HTML, JavaScript references, `robots.txt`, and REST hints
- REST API discovery for users, posts, and custom namespaces
- XML-RPC attack-surface inspection including `system.listMethods`, `system.multicall`, and `pingback.ping`
- Login surface checks for `wp-login.php` and `wp-admin/`
- User enumeration from REST, author paths, sitemaps, and feeds
- Optional target-specific public vocabulary capture with CeWL
- Optional passive WPScan integration when `wpscan` is installed
- Structured HTML, JSON, and CSV reports

## Safety

For authorized security testing only.

This repository is intentionally recon-focused. It does not automate password attacks or brute force workflows. The CeWL helper captures public-site vocabulary only, and the WPScan integration stays passive so the framework is usable in day-to-day recon without crossing into high-risk behavior by default.

## Installation

Requirements:

- Bash
- `curl`
- `jq`
- Ruby plus Bundler for native CeWL/WPScan installs, or Docker/Podman for container fallback

Optional tools:

- `cewl`
- `wpscan`

Clone and run:

```bash
git clone https://github.com/rascyber/wp-attack-surface-scanner.git
cd wp-attack-surface-scanner
chmod +x scanner/*.sh
chmod +x scripts/install_dependencies.sh
```

Recommended dependency bootstrap:

```bash
./scripts/install_dependencies.sh
```

What the installer does:

- installs repo-local CeWL and WPScan runtimes under `.tools/`
- prefers Homebrew Ruby on macOS so WPScan is not tied to the system Ruby
- clones the official CeWL project and bundles it locally
- installs WPScan locally with a writable project-scoped cache/database home
- pulls the official container fallback images for CeWL and WPScan when a runtime is available

Container fallback requires a running Docker or Podman runtime, not just the CLI.

Tool selection order at runtime:

- CeWL: repo-local wrapper, system binary, then Docker/Podman fallback, otherwise `unavailable`
- WPScan: repo-local wrapper, healthy system binary, then Docker/Podman fallback, otherwise `unavailable`

If you only want the container fallbacks:

```bash
./scripts/install_dependencies.sh --docker
```

## Usage

Main entrypoint:

```bash
./scanner/wp_scan.sh -t examples/targets.txt --full
```

Common examples:

```bash
./scanner/wp_scan.sh -t examples/targets.txt --full
./scanner/wp_scan.sh -t tests/test_targets.txt --xmlrpc --rest --users
./scanner/wp_scan.sh -t examples/targets.txt --plugins --login --cewl
```

Options:

- `-t`, `--targets` path to target list
- `-o`, `--output` report root directory, default `./reports`
- `--plugins` run plugin enumeration
- `--xmlrpc` run XML-RPC analysis
- `--rest` run REST API analysis
- `--login` run login surface checks
- `--users` run user enumeration
- `--cewl` run public vocabulary capture if CeWL is installed
- `--wpscan` run passive WPScan integration if installed
- `--full` run the full recon pipeline
- `-h`, `--help` show help

`--full` includes the optional CeWL and WPScan stages. Those stages now use repo-local or system-native tools when healthy and automatically fall back to Docker/Podman when available.

## Output

The scanner writes one directory per target under `reports/`:

```text
reports/
  example_com/
    plugins.txt
    users.txt
    xmlrpc_methods.xml
    rest_endpoints.json
    wordlist.txt
    report.html
    report.json
    report.csv
```

Repository-level summaries are also produced:

- `reports/summary.csv`
- `reports/summary.json`
- `reports/index.html`

## Modules

- `scanner/detect_wordpress.sh`
- `scanner/plugin_enum.sh`
- `scanner/rest_api_scan.sh`
- `scanner/xmlrpc_scan.sh`
- `scanner/login_scan.sh`
- `scanner/user_enum.sh`
- `scanner/cewl_wordlist.sh`
- `scanner/report_generator.sh`
- `scanner/wp_scan.sh`

## Dependency Bootstrap

- `scripts/install_dependencies.sh`

Examples:

```bash
./scripts/install_dependencies.sh
./scripts/install_dependencies.sh --docker
./scripts/install_dependencies.sh --wpscan
./scripts/install_dependencies.sh --cewl --docker
```

## CI/CD

GitHub Actions validates Bash syntax and runs the orchestrator against local mock WordPress targets. See `.github/workflows/ci.yml`.

## Documentation

- `docs/architecture.md`
- `docs/methodology.md`
- `docs/bug_bounty_usage.md`

## Branches

- `main` stable releases
- `dev` integration branch
- `scanner-engine` experimental scanner changes

## Release

```bash
git tag v2.0.0
git push origin v2.0.0
```

## License

MIT License. See `LICENSE`.
