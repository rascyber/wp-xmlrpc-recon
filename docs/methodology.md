# Methodology

## WordPress Attack Surface

WordPress deployments expose a mix of public content endpoints, administrative interfaces, and application-specific extensions. Reconnaissance focuses on identifying those exposed paths before any deeper validation is attempted.

## Detection Strategy

WordPress presence is inferred from multiple low-impact signals:

- `wp-content` and `wp-includes` references
- `wp-json` availability
- generator tags
- login page markers

Using multiple signals reduces false positives from CDN behavior or custom theming.

## Plugin Risk Signals

Plugins frequently expand the public attack surface. Discovery matters because plugin-specific REST routes, JavaScript bundles, and content references can reveal:

- third-party code exposure
- administrative functionality exposed through custom endpoints
- versioning clues
- potential high-value manual follow-up targets

## REST API Exposure

The REST API is useful for both WordPress features and plugin extensions. Public user and post endpoints can reveal:

- usernames
- content metadata
- custom namespaces
- plugin-defined routes

The scanner records route and namespace exposure without attempting privileged operations.

## XML-RPC Exposure

XML-RPC remains relevant in older and mixed WordPress estates. Recon output records:

- `xmlrpc.php` reachability
- `system.listMethods`
- `system.multicall`
- `pingback.ping`
- authentication RPC surface indicators

These signals help prioritize follow-up without automating credential attacks.

## Login Surface

The framework checks `wp-login.php` and `wp-admin/` to determine:

- whether the login endpoint is exposed
- whether invalid submissions return recognizable responses
- whether rate-limiting indicators appear in headers or body content

## User Enumeration

Usernames are collected passively from:

- REST API responses
- author archive links
- user sitemaps
- RSS feeds

The goal is visibility into exposure, not account interaction.
