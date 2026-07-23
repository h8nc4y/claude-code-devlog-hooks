# Security Policy

This repository ships PowerShell and Bash scripts that Claude Code executes
automatically on session events. That warrants an explicit threat model, even
though the scripts are small.

## Threat Model

What the hooks do — and everything they do:

- **Execution**: run locally, spawned by Claude Code on `SessionStart`,
  `UserPromptSubmit`, and `Stop` events (the Stop hook runs at the end of
  every turn). No scheduled or background execution.
- **Network**: none. The hooks make no network calls of any kind.
- **Filesystem reads**: the hook source/helper, stdin JSON provided by Claude
  Code, session marker files, and the mtime of today's journal file. Runtime
  state stays under the configured devlog root (`CLAUDE_DEVLOG_DIR`).
- **Filesystem writes**: marker files under `<devlog root>/.devlog-markers/`
  (plus creating that directory, and the devlog root itself on first run).
  The hooks never write journal content and never touch paths outside the
  devlog root.
- **Environment**: read `CLAUDE_DEVLOG_DIR` and `CLAUDE_DEVLOG_LANG` only.
- **Failure direction**: fail-open. Any error allows the session to
  proceed silently; the hooks are designed to never block work on their
  own failure. The trade-off (fail-open hides bugs) is countered by the
  pipe-test suite, not by failing closed.
- **Injection surface**: `session_id` from stdin is used in a filename
  after replacing every character outside `[A-Za-z0-9_.-]`; the pipe tests
  cover this. Message text is static apart from interpolated paths derived
  from the devlog root. The Bash implementation parses only validated JSON
  values and JSON-escapes quote, backslash, and C0 control bytes in paths; it
  never evaluates input or path text as shell code.

**Before installing, read the three entrypoints and their shared helper in
`hooks/`.** Anything that asks Claude Code to execute a script on every turn
deserves that scrutiny, including this repository.

## Supported Versions

The `main` branch is the supported version. Tagged releases receive fixes
through new tags on `main`.

## Reporting A Vulnerability

Use GitHub private vulnerability reporting for:

- A real secret, credential, or private identifier accidentally committed
  to this repository.
- A way to make the hooks read or write outside the devlog root, execute
  attacker-controlled content, or exfiltrate data.
- Guidance or defaults that could cause agents to lose user work, leak
  private data, or block sessions permanently (a fail-open violation).
- A validation gap that allows unsafe public examples.

Do not open a public issue containing tokens, credentials, private keys,
OAuth material, customer data, raw secret-bearing logs, or private
repository names and internal paths.

## Public Issue Safety

Public issues may include:

- Symptom class, such as "Stop hook blocks repeatedly" or "nudge never
  fires".
- Sanitized pipe-test transcripts using placeholder paths such as
  `C:/path/to/devlog`.
- PowerShell or Bash and Claude Code version numbers.

Public issues must not include:

- Secret values or secret-bearing command output.
- Private repository names, internal absolute paths, hostnames, or
  customer data.
- Raw agent transcripts or journal contents that contain any of the above.

## Scanner Coverage

The private-marker scanner (`scripts/scan-private-markers.ps1`) is a
best-effort safety net, not a guarantee. It scans git-tracked text files
for a curated set of secret prefixes (GitHub, OpenAI, AWS, GCP, Slack,
Stripe, PEM key blocks, and similar), private-looking absolute Windows
paths, non-allowlisted GitHub repository URLs, and configured local
markers, and it redacts any matched value. It does not detect every
possible secret format and is no substitute for keeping real credentials
out of the repository in the first place. Treat a passing scan as "no
known marker found," not "definitely safe."

## Response Expectations

Maintainers should acknowledge actionable security reports when available,
remove or redact unsafe public material, and prefer guidance that reduces
data-exposure and work-loss risk. If real exposure is possible, rotate the
affected secret outside this public repository and document only the
remediation status.
