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
  `.private-markers.local` file, not in repository source. The scanner fails
  closed if that file appears in the Git index and never prints matched marker
  values.

## Hook Invariants (Do Not Break)

Every change to `hooks/*.ps1` or `hooks/*.sh` must preserve:

1. **Fail-open AND fail-silent**: any error or unjudgeable state allows,
   with nothing on stdout or stderr; every path ends in `exit 0` (the
   structured block JSON is emitted before a normal exit). Hooks set
   `$ErrorActionPreference = 'Stop'` so cmdlet errors become catchable
   instead of leaking to stderr. Bash entrypoints run `main` behind a
   stderr-suppressing boundary and disable inherited fail-fast shell options.
   Keep degraded states disclosed in the injected context rather than
   invisible.
2. **Raw UTF-8 stdout** via `Write-Utf8Stdout` (PowerShell) or `printf`
   (Bash); never let a console encoding layer rewrite the bytes.
3. **No `Set-StrictMode` in PowerShell hooks** — the logic relies on absent JSON
   properties evaluating to `$null`; strict mode silently disables the
   hook through the fail-open catch (rationale in
   [docs/hook-engineering.md](docs/hook-engineering.md)).
4. **Source encoding by runtime**: UTF-8 BOM on `.ps1` hook files (Windows
   PowerShell 5.1), UTF-8 without BOM on `.sh` files (the shebang must be the
   first bytes). `validate-oss-readiness.ps1` checks both.
5. **Single-variable configuration**: all paths derive from the devlog
   root; no machine-specific absolute paths.
6. **Enforce-once semantics** for Stop (marker + mtime comparison,
   `stop_hook_active` guard) and the double gate for the nudge.
7. **One plugin launcher, one selected runtime**: plugin hooks register one
   `shell: "bash"` launcher per event so Claude Code selects Git Bash rather
   than an unrelated PATH/WSL executable. Do not register PowerShell and Bash
   handlers together or interpolate `${user_config.*}` into command text.
8. **Safe plugin configuration bridge**: read non-empty
   `CLAUDE_PLUGIN_OPTION_*` values as environment data only. Never use them to
   choose an executable, script path, or additional command argument.

If a change alters observable behavior, add or adjust a case in
`scripts/test-hooks.ps1` and run it against both implementations. The shared
30 cases must stay equivalent; POSIX-only filesystem cases may be conditional.
Behavior claims in this repository are backed by pipe tests, not by assertion.

The Bash port intentionally has no jq/Python/Node runtime dependency. Before
adding a dependency to hooks that fire every turn, document the portability
cost and why the standard-tool implementation is insufficient.

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
claude plugin validate . --strict
pwsh -NoProfile -File ./scripts/test-plugin.ps1
bash --noprofile --norc ./scripts/test-plugin-launcher.sh
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-hooks.ps1
pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell powershell   # Windows only
pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell bash
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
for script in ./hooks/*.sh ./scripts/*.sh; do bash --noprofile --norc -n "$script" || exit 1; done
git diff --check
```

The strict Claude CLI validator is a local release check. CI must not install,
authenticate, or enable Claude Code just to obtain it; CI runs deterministic
package-shape tests instead.

Windows PowerShell can host the PowerShell scripts too
(`powershell -NoProfile -ExecutionPolicy Bypass -File ...`). On macOS or
Linux, install PowerShell 7 (`pwsh`) and skip the `-HookShell powershell`
run — CI covers it on `windows-latest`. CI runs Bash behavior and syntax on
Ubuntu 24.04 and on GitHub-hosted macOS 15 with system `/bin/bash` 3.2.

The scanner self-test also runs under both Windows PowerShell hosts and under
PowerShell 7 on Ubuntu 24.04. It uses only disposable synthetic repositories
and local processes. It verifies the sanitized Git child environment, binary
standard streams, index/worktree provenance, final raw index equality,
fail-closed index states, process-tree cleanup, and bounded diagnostics without
contacting an external service or using real credentials. A lower-only test
deadline also proves that an expired scan cannot emit a success result; callers
cannot extend the production 120-second ceiling. Bootstrap, helper,
timeout/output, and isolated-directory failures must emit only the fixed
process-boundary stderr line with exit code 2 and no absolute local path.
Invalid timeout, deadline, or process-boundary test-seam arguments use that same
body-level fixed diagnostic instead of PowerShell parameter-binding output.
The suite also scans a one-million-character adversarial no-match line. Every
production regex must use a finite .NET match timeout under PowerShell 7 and
Windows PowerShell 5.1; a timeout must finish within the bounded process window,
emit only the fixed redacted `regex-timeout` stderr line, and exit 2 without
leaking fixture or repository paths. A 900,000-character safe positive control
must still pass. A git-tracked timeout combined with synthetic isolation cleanup
failure must emit exactly one `process-boundary` line, never both diagnostics.
Readiness parses the scanner AST: it rejects regex operators, casts, shortened
or alternate Regex types, `switch -Regex`, `Select-String`, and dynamic or Regex
`New-Object` types, and pins the sole three-argument constructor to the
`Math.Min(250, scan deadline)`-derived timeout. Mutation fixtures cover each
entry point and timeout-provenance replacement.

The first bounded-process call is guarded structurally with a shared PowerShell
AST policy. It follows direct/transitive local-function calls, scope prefixes,
risky aliases, function-object lookup, stored scriptblocks, and eager
`.Invoke*()` paths. Alias/Function/Variable provider mutation, dynamic dot
sourcing, every other literal/dynamic dot or call operator, bare/aliased script
paths, dynamic or provider-recovered ScriptBlocks, risky
`Set-Content`/`Set-Variable`, target-helper shadowing, `-as` conversion,
static-member risky-type provenance, and unresolved execution paths fail
closed. Only two top-level bootstrap dot sources built from one exact
`System.IO.Path` root/path provenance and the literal
`Get-Command git -CommandType Application` lookup remain allowed. Windows
fixtures also distinguish dormant function/type bodies from eager calls:
function-local assignments, `[ref]` values with a guaranteed prior local
binding, and unrelated object
`GetValue`/`SetValue` methods remain valid, while `script:`/`global:` mutation,
mutable `SessionState.PSVariable.Get` handles, and PSVariable-table aliases fail
closed when their wrapper is called before the bootstrap. Parentheses, casts,
subexpressions, and single-element array indexing do not erase its taint, but
that does not make every wrapper an approved direct receiver.
Unsupported command wrappers retain any raw PSVariable-table provenance found
in their AST subtree; safe command expressions without that provenance stay
allowed. Scope-qualified `$ExecutionContext` receivers and aliases/parameters
derived from that automatic variable, including `Get-Variable`, must not bypass
the receiver check. Treat the raw PSVariable table as direct only when
transparent wrappers lead immediately to a static
`Get`/`GetValue`/`Set`/`SetValue` receiver; reject return, assignment, command-
argument, and multi-element-pipeline escapes. Never trust a cast for this
exemption, and require an array wrapper to index immediately back to its sole
element. Keep unused local scriptblocks dormant, but reject scope escape,
inline consumption, provider recovery, later use, and persistent
script/global helper shadowing. Index/member mutation is not a prior local
binding for `[ref]`. The optional `$Path` fallback must retain its exact
`$PSScriptRoot`/`System.IO.Path.GetDirectoryName` provenance.
Windows fixtures cover exact BOM-less `-File` and native Git bytes, actual Job
membership,
bounded cleanup for failures before assignment/resume, and retained-handle
retry plus direct termination after a synthetic Job-close failure. Repeated
successful launches must also return all transferred standard-stream handles.
Keep the direct native zero-allowance fixture: it must reach the final
pre-`ResumeThread` deadline check after Job assignment, remove the recorded PID,
and leave the target sentinel absent.
POSIX fixtures cover the default external `setsid`, the native fallback, and a
BusyBox-compatible shim. Each must report a PID that is an actual process-group
leader before release, and a delayed handshake must consume the caller deadline
while cleanup still receives one independent finite allowance shared by tree,
stream, and final waits. The late-ready fixture must let its tracked parent exit
before the delayed group appears, then prove that the recovered PID terminates
without target release. Retain a separate normal early-fork fixture whose
tracked launcher exits immediately: the payload must outlive the stream
completion window, publish an atomic completion record, and preserve its
nonzero exit code without a false pipe leak.
Git fixtures include a standard linked worktree whose root `.git` is a gitfile;
on POSIX, only exact lowercase `.git` is metadata and ordinary `.GIT` content
remains scannable.

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
