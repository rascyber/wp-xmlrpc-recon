# Methodology

## What XML-RPC Is

XML-RPC is a remote procedure call protocol that uses XML-formatted requests over HTTP. In WordPress it historically supported remote publishing clients, mobile applications, trackbacks, and integration workflows. The endpoint is commonly exposed at `/xmlrpc.php`.

## Why `system.multicall` Matters

`system.multicall` allows a client to package multiple XML-RPC calls into a single request. In legitimate use it reduces overhead. In security testing it matters because exposed multicall support can increase attack efficiency for credential-based operations if other controls are weak. That makes it a high-value reconnaissance signal even when no active exploitation is attempted.

## Pingback Reflection Risks

`pingback.ping` enables one site to notify another about linked content. Historically, exposed pingback behavior has been abused for reflected traffic and internal reachability testing. During recon, the question is not whether to trigger it broadly, but whether the capability appears present so it can be documented for remediation or bounty reporting.

## Authentication Endpoints

WordPress XML-RPC includes authenticated methods such as `wp.getUsersBlogs`. Even when invalid credentials are used, a distinct method response can confirm that the authentication surface is reachable through XML-RPC. This tool only performs a benign exposure check with placeholder credentials and does not attempt brute force or account validation.

## Bug Bounty Methodology

Recommended workflow:

1. Confirm that XML-RPC exposure is in scope for the target program.
2. Collect candidate hosts from program assets, subdomain discovery, or owned inventories.
3. Run the scanner with conservative rate limits.
4. Review `system.listMethods`, `system.multicall`, `pingback.ping`, and `wp.getUsersBlogs` findings.
5. Validate impact manually against the program rules before reporting.
6. Report only authorized, reproducible findings with clear remediation guidance.

## Safety Notes

- Keep scan rates low.
- Avoid brute force logic.
- Do not use against assets without permission.
- Treat XML-RPC exposure as one signal within a broader WordPress attack surface review.
