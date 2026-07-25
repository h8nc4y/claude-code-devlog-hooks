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
- **Plugin launcher**: reads only fixed event arguments plus the official
  `CLAUDE_PLUGIN_OPTION_DEVLOG_DIR` / `CLAUDE_PLUGIN_OPTION_DEVLOG_LANG`
  environment exports, maps non-empty values to the existing hook variables,
  and replaces itself with exactly one checked-in PowerShell or Bash hook.
  It does not interpolate configuration into command text, dump the
  environment, or print hook stdin.
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
best-effort safety net, not a guarantee. It scans regular stage-0 index blobs
and regular tracked worktree files as separate provenance sources for a
curated set of secret prefixes (GitHub, OpenAI, AWS, GCP, Slack, Stripe, PEM
key blocks, and similar), private-looking absolute Windows paths,
non-allowlisted GitHub repository URLs, and configured local markers. Matches
are always redacted. Text candidates include common source/document/config
extensions, extensionless files, dotenv names, `.npmrc`, `.pem`, and `.key`;
unlisted extensions are skipped without text decoding. It does not detect
every possible secret format and is no substitute for keeping real
credentials out of the repository. Treat a passing scan as "no known marker
found," not "definitely safe."

Git-backed enumeration runs in bounded child processes with a cloned,
sanitized environment and isolated configuration. Ambient and future
`GIT_*`, repository/index/object redirection, config injection, hooks,
attributes, excludes, templates, filters, prompts, tracing, replacement
objects, and lazy promisor fetches are not inherited. The scanner never
mutates its caller's environment. It requires the exact repository root and
fails closed on malformed Git output, repository subdirectories, conflicts,
intent-to-add entries, gitlinks, symlinks, reparse points, path escape,
missing or changing worktree files, and tracked `.private-markers.local`.
Non-Git fallback is allowed only when Git proves the path is not a repository
or Git is unavailable with no `.git` marker in the target ancestry; nested
and leaf `.git` controls are excluded.

Process-boundary bootstrap, helper, timeout/output, and isolated-directory
creation/removal failures all return exit code 2 with the same fixed ASCII
stderr line. Repository, temporary, scanner, and helper paths are not included
in either standard stream or propagated exception text.

The first process-helper call is protected by a pure AST policy. It propagates
risk across function/alias/type fixed points and rejects every literal or
dynamic call/dot operator outside the two approved bootstraps, Invoke-like
member dispatch, bare/aliased script paths, ScriptBlock factories and Variable
provider recovery, Alias/Function/Variable provider mutation,
`Set-Content`/`Set-Variable` identity changes, and risky class construction
through `New-Object`, `Activator`, `-as`/other conversion, static-member
provenance, or typed wrappers. The two repository bootstrap dot sources require
one direct top-level root assignment and exact command-resolution-independent
`System.IO.Path` static calls; only those sources and the exact literal native
Git application lookup are allowed before the binary transport fixture.
Dormant function/type bodies are not treated as eager execution. For wrappers
that are actually called, the policy distinguishes definition-local variables
and `[ref]` values with a guaranteed prior local binding from
`script:`/`global:` mutation, verifies the exact
`$ExecutionContext.SessionState.PSVariable` receiver instead of trusting only a
member name, and rejects mutable `PSVariable.Get` handles or PSVariable-table
aliases without rejecting unrelated object `GetValue`/`SetValue` methods.
Parentheses, casts, subexpressions, and single-element array indexing preserve
taint provenance; this does not make every wrapper an approved direct receiver.
If an unsupported command
wrapper still contains the raw PSVariable receiver, the remaining subtree is
treated as tainted rather than allowing the wrapper to erase provenance.
Scope-qualified `$ExecutionContext` receivers are normalized, and
`Get-Variable ExecutionContext`, aliases, or parameters are not treated as
unrelated objects. The raw PSVariable table is exempted from generic
`ExecutionContext` risk only when transparent wrappers terminate at a static
`Get`/`GetValue`/`Set`/`SetValue` receiver. Return, assignment, command-
argument, and multi-element-pipeline escapes remain fail-closed. Casts are not
trusted for this exemption, and an array wrapper must immediately index back to
its sole element. An unused
scriptblock remains dormant only in an
unreferenced local binding; provider recovery, inline use, scope escape, or
later invocation propagates its risk. Index/member mutation is not accepted as
a prior local binding for `[ref]`, and called wrappers cannot persistently
shadow the transport helper through script/global functions or aliases. The
approved `$Path` fallback also requires trusted `$scriptRoot` provenance and an
exact command-resolution-independent `System.IO.Path.GetDirectoryName` call.

Unique index blobs share one binary-safe `git cat-file --batch` exchange.
Immediately before reporting, raw `ls-files -z --stage` and
`ls-files -z --stage --debug` snapshots must match their initial bytes
exactly, including flags. A scan-wide deadline and independent
process-stream, entry, per-file byte, total byte, line, regex-match, per-file
finding, total finding, and diagnostic-width limits bound hostile input. The
complete finding table uses explicit LF, is encoded once, and must fit within
64 KiB of actual UTF-8 bytes before any row is emitted. After serialization,
the scan-wide deadline is checked again immediately before failure output;
the clean path performs the same check immediately before success output.
Every production regular expression is constructed with the PowerShell
5.1-compatible three-argument .NET constructor and a finite match timeout,
capped at 250 ms and clamped to the configured scan deadline. A timeout at any
`Match`, `IsMatch`, or `NextMatch` boundary is retained until Git isolation
cleanup finishes. A timeout alone emits only the fixed redacted `regex-timeout`
integrity diagnostic and exits 2; neither input nor pattern content is replayed.
If cleanup also fails, its single `process-boundary` diagnostic takes precedence
so the two failures cannot emit two stderr lines.
Timeout, deadline, and process-boundary test-seam values are parsed and bounded
inside the script so invalid input cannot fall back to path-bearing PowerShell
parameter-binding diagnostics.

On Windows, each child is created suspended with a three-handle
stdin/stdout/stderr inheritance allowlist, assigned to a per-command
kill-on-close Job, and resumed only after assignment. This closes the
start-before-assignment descendant race. On POSIX, each child enters a
dedicated session/process group before its first instruction. External `setsid`
uses only the portable program operand shared by util-linux and BusyBox; the
native fallback uses the same gated wrapper. The wrapper reports its PID, and
the parent requires `getpgid(pid) == pid` before releasing target code. The
operation deadline begins before preparation, start, and handshake, while
cleanup has an independent finite total allowance. If an external `setsid`
implementation forks before the deadline failure is observed, cleanup watches
for a late ready PID within that allowance and signals the verified group.
For a released payload, the wrapper atomically publishes its completion and
actual exit code. The caller therefore does not mistake an early-exiting
tracked `setsid` parent for payload completion, and it does not shorten the
stream window into a false pipe-leak decision. Tree stop, stream drain, and
final cleanup all consume the same remaining allowance. Cleanup signals the
whole group with `kill(2)` and accepts only success or `ESRCH`; permission and
other signal failures remain fail closed.

Windows launch failures before Job assignment or before resume terminate the
still-suspended target, wait for its disappearance within a finite budget, and
aggregate cleanup errors with the original launch error. The regression suite
checks the resumed target's Job membership and injects both failure phases
without allowing target code to run. It also invokes the native boundary with
an expired launch allowance after Job assignment, proving that the final
pre-`ResumeThread` deadline check removes the PID while target code remains
suspended. A Job-close failure retains the native handle, directly terminates
the target, and retries the same handle from a later stop or disposal path.
Successful Windows launches transfer stdin/stdout/stderr ownership to the
contained process, and the wrapper explicitly disposes that owner on every
return path. A repeated-launch regression checks that native handles do not
grow linearly.

The exact Git root accepts both a normal `.git` directory and the standard
linked-worktree `.git` gitfile. POSIX fallback treats only exact lowercase
`.git` as repository metadata; case-distinct `.GIT` paths remain ordinary scan
candidates.

Before output, control/format characters, bidi controls, zero-width
characters, and Unicode line/paragraph separators in diagnostic fields are
escaped. Missing or otherwise unresolvable user paths emit only a fixed code,
without the supplied path or raw PowerShell error framing. Process byte
limits count actual stdin/stdout/stderr bytes, including prefixes and the
platform newline. The first bounded call uses a BOM-less `-File` child, and a
native Git batch fixture checks complete binary output with no UTF-8 preamble.

## Response Expectations

Maintainers should acknowledge actionable security reports when available,
remove or redact unsafe public material, and prefer guidance that reduces
data-exposure and work-loss risk. If real exposure is possible, rotate the
affected secret outside this public repository and document only the
remediation status.
