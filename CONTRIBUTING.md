# Contributing

Thanks for improving these hooks. This repository is intentionally small:
changes should make the journaling flow safer, clearer, or easier to
verify.

## Before You Start

- Read [SKILL.md](SKILL.md), [docs/hook-engineering.md](docs/hook-engineering.md),
  and the hook sources under [hooks](hooks).
- `SKILL.md` (English) is canonical. When you change it, update
  [docs/SKILL.ja.md](docs/SKILL.ja.md) in the same pull request so the two
  stay in sync. The same applies to the Japanese/English message pairs
  inside the hooks: change both languages together.
- Do not paste tokens, credentials, private keys, OAuth codes, raw logs,
  customer data, private repository names, or internal absolute paths into
  issues, pull requests, commits, or examples. No token or secret value
  ever belongs in this repository.
- Use synthetic placeholders such as `C:/path/to/devlog`,
  `<owner>/<name>`, and `<session-id>` in examples.
- Put personal or organization-specific scan markers in an untracked
  `.private-markers.local` file, not in repository source.

## Hook Invariants (Do Not Break)

Every change to `hooks/*.ps1` must preserve:

1. **Fail-open AND fail-silent**: any error or unjudgeable state allows,
   with nothing on stdout or stderr; every path ends in `exit 0` (the
   structured block JSON is emitted before a normal exit). Hooks set
   `$ErrorActionPreference = 'Stop'` so cmdlet errors become catchable
   instead of leaking to stderr — keep it, and keep degraded states
   disclosed in the injected context rather than invisible.
2. **Raw UTF-8 stdout** via `Write-Utf8Stdout`; never pipe objects or
   strings directly to stdout.
3. **No `Set-StrictMode` in hooks** — the logic relies on absent JSON
   properties evaluating to `$null`; strict mode silently disables the
   hook through the fail-open catch (rationale in
   [docs/hook-engineering.md](docs/hook-engineering.md)).
4. **UTF-8 BOM on hook files** (they contain non-ASCII text and must parse
   under Windows PowerShell 5.1). `validate-oss-readiness.ps1` checks this.
5. **Single-variable configuration**: all paths derive from the devlog
   root; no machine-specific absolute paths.
6. **Enforce-once semantics** for Stop (marker + mtime comparison,
   `stop_hook_active` guard) and the double gate for the nudge.

If a change alters observable behavior, add or adjust a case in
`scripts/test-hooks.ps1` — behavior claims in this repository are backed
by pipe tests, not by assertion.

## Grounding Rules

- Claims about hook/agent behavior should be grounded in something
  observable (a pipe test, a reproducible command sequence, the official
  hooks reference). Mark design-derived-but-unvalidated guidance
  explicitly as unverified.
- Do not remove existing honesty markers ("unverified", "pipe-tested
  only") without evidence that changes their status.

## Development Workflow

1. Create a focused branch.
2. Make the smallest coherent change.
3. Update examples and README text when user-facing guidance changes.
4. Add or adjust a pipe-test case when observable behavior changes.
5. Run the validation commands before opening a pull request.

## Validation

From the repository root:

```powershell
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-hooks.ps1
pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell powershell   # Windows only
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
git diff --check
```

Windows PowerShell can host the scripts too
(`powershell -NoProfile -ExecutionPolicy Bypass -File ...`). On macOS or
Linux, install PowerShell 7 (`pwsh`) and skip the `-HookShell powershell`
run — CI covers it on `windows-latest`.

## Pull Request Expectations

- Explain the problem and the chosen fix.
- Include validation results (which commands, which shell, pass/fail).
- Call out any remaining unknowns.
- If the change touches a hook invariant, describe the failure mode it
  prevents (or the false block/nudge it removes) concretely.

## Maintainer Notes

Prefer documentation and tests that prevent silent hook failure (fail-open
hides bugs) and data exposure. Avoid adding dependencies or network-backed
checks: the hooks' security story is "local, no network, one directory".
