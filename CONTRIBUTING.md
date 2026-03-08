# Contributing

## Scope

Contributions should improve reconnaissance quality, reporting clarity, and operational stability for authorized WordPress security assessments.

## Principles

- Keep the framework modular and Bash-first.
- Preserve Linux and macOS portability.
- Prefer passive or low-impact techniques.
- Do not add brute force, password spraying, or destructive testing logic.
- Document behavior changes in the README or docs when user-facing behavior changes.

## Development Flow

1. Branch from `dev`.
2. Keep changes focused and reviewable.
3. Run `bash -n scanner/*.sh`.
4. Run the orchestrator against `tests/test_targets.txt`.
5. Update docs and examples if the output format changes.

## Pull Requests

Include:

- problem statement
- approach
- test notes
- sample output impact

## Branch Model

- `main`: stable releases
- `dev`: integration
- `scanner-engine`: experimental work

## Ethics

This project is for authorized security testing only. Pull requests that add automated credential attacks or abusive traffic patterns should not be merged.
