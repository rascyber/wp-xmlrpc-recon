# Changelog

All notable changes to this project are documented here.

## [2.0.0] - 2026-03-08

- replaced the single-purpose XML-RPC scanner with a modular WordPress attack-surface framework
- added WordPress detection, plugin enumeration, REST API analysis, login checks, and user enumeration modules
- added optional CeWL public-wordlist capture and passive WPScan integration
- added a cross-platform dependency installer and Docker fallbacks for CeWL and WPScan
- added per-target HTML, JSON, and CSV report generation plus repository summaries
- added architecture, methodology, and bug bounty workflow documentation
- updated CI to validate all modules against local mock WordPress services
