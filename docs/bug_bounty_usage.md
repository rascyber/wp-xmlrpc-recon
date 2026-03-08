# Bug Bounty Usage

## Workflow

A practical WordPress recon flow usually looks like this:

1. identify candidate hosts from scope or subdomain discovery
2. confirm WordPress presence
3. enumerate plugins and public routes
4. inspect XML-RPC and login surfaces
5. collect publicly exposed usernames
6. review the generated report and decide what deserves manual validation

## Recommended Approach

- keep scans rate-limited
- confirm the target is in scope
- start with `--full` to build a broad baseline
- review `reports/index.html` for fast triage
- pivot into a per-target directory when a host looks promising

## CeWL and WPScan

The framework can detect and use CeWL or WPScan when installed, but it treats both as optional recon helpers:

- CeWL captures public vocabulary from the target site
- WPScan integration is passive in this repository

If a program explicitly authorizes deeper authenticated testing, handle that as a separate, program-specific workflow rather than relying on automation here.

## Reporting

Useful bug bounty notes from the framework include:

- WordPress confirmed or not
- plugins discovered
- custom REST namespaces
- XML-RPC methods exposed
- usernames exposed publicly
- login rate-limiting signals

## Ethics

For authorized security testing only.
