# Contributing

## Scope

Contributions should preserve the project's purpose as a safe reconnaissance utility for authorized security assessments.

## Local Workflow

1. Create a feature branch from `dev`.
2. Keep changes small and reviewable.
3. Validate Bash syntax before opening a pull request.
4. Run the scanner against the local mock workflow targets or a lab instance you control.

## Standards

- Prefer portable Bash compatible with Linux and macOS.
- Keep dependencies limited to `bash`, `curl`, and `jq` unless there is a strong justification.
- Avoid adding behavior that performs credential attacks or disruptive testing.
- Update documentation when behavior changes.

## Branching

- `main` is reserved for stable release history.
- `dev` is the default integration branch.
- `scanner-engine` is intended for experimental scan logic and parser changes.

## Pull Requests

Include:

- a concise problem statement
- the approach taken
- test notes
- any output format changes

## Reporting Issues

When reporting bugs, include:

- operating system and Bash version
- the command used
- sanitized target examples
- relevant error output
