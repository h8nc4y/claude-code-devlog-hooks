# Hook Engineering Notes (PowerShell And Bash)

Field-derived patterns for writing Claude Code hooks in PowerShell and Bash,
and the specific design decisions behind the two implementations of the three
hooks in this repository. Every rule here traces to an observed failure, a
pipe test, or the official hooks reference (field names and event semantics
verified against `https://code.claude.com/docs/en/hooks` on 2026-07-23).

## The Three-Layer Pattern

One behavioral goal ("keep the journal updated, little and often") maps to
three hooks with different pressure levels:

1. **SessionStart — inform.** Inject the routine via
   `hookSpecificOutput.additionalContext` and, only after establishing a
   marker-safe 1-64 character session identity, record state (a session-start marker)
   for the other layers.
2. **UserPromptSubmit — nudge, never block.** High-frequency,
   judgment-based behaviors ("append when something is worth recording")
   must not be enforced with blocks — that becomes a nag that users disable.
   Inject a reminder only when it is probably warranted, and stay silent
   otherwise.
3. **Stop — enforce once.** The minimum guarantee ("at least one journal
   update per session") is enforced with a block, exactly once, and only
   while the condition is actually unmet.

## Stop Fires Every Turn, Not Once Per Session

The Stop event fires at the end of **every** turn. A naive "block when the
journal is stale" Stop hook harasses from the very first turn and never
stops. The **enforce-once pattern** fixes this:

- SessionStart writes the session start time (unix epoch) to a marker file
  keyed by a validated 1-64 character `[A-Za-z0-9_.-]` `session_id`. Each ASCII
  byte is lowercase-hex encoded under `~sid-`, keeping case variants, Windows
  reserved basenames, and legacy raw/sanitized marker names disjoint.
- Stop compares: `daily journal mtime >= session start epoch` means "already
  updated this session" — allow. Otherwise block once with instructions.
- After the journal is written once, every later turn in the session passes
  the comparison, so the hook never blocks again.

Two guards keep this safe:

- **`stop_hook_active`**: when the input JSON carries `stop_hook_active:
  true`, a Stop hook already blocked and the agent is continuing because of
  it. Exit 0 immediately — otherwise you can build an infinite block loop.
- **Missing marker means allow**: if the marker does not exist (hook
  installed mid-session, marker pruned, SessionStart failed, or session
  identity was not established), the state is unjudgeable. Fail open.

## Fail-Open Is Mandatory — And It Hides Bugs

A hook that throws inside Stop or PreToolUse can permanently wedge a
session. Wrap the entire body in `try { } catch { }` and end with `exit 0`;
on any error or unjudgeable state, decide in the direction that does NOT
obstruct the user.

**Non-terminating errors are the hole in naive fail-open.** PowerShell
cmdlet errors are non-terminating by default: they do NOT enter `catch`,
they print to stderr, and execution continues. A hook wrapped entirely in
try/catch can therefore still spray stderr and half-execute on a write
failure. Set `$ErrorActionPreference = 'Stop'` inside the hook so every
cmdlet error becomes a catchable exception — then fail-open is also
fail-SILENT. (Adversarial review of this repository caught exactly this
before v0.1.0: an unwritable devlog root made SessionStart exit 0 while
leaking a `Set-Content` error to stderr, with the Stop layer silently
disarmed. The regression cases in `test-hooks.ps1` now pin the silent
behavior.)

**Disclose degraded enforcement.** When SessionStart cannot write its
marker, the Stop layer is off for the whole session — invisible unless
disclosed, because a silently disarmed Stop hook looks exactly like a
working one on a session where the journal was updated. The hook appends a
⚠ line to the injected context naming the unwritable directory, instead of
degrading invisibly.

The same disclosure applies when SessionStart cannot establish identity from
malformed/oversized/non-UTF-8 stdin, an embedded NUL, a non-object root,
ambiguous top-level duplicates or ASCII case collisions, or a missing, empty,
non-string, unsafe, or oversized `session_id`. It still
injects the routine plus a fixed localized warning, but creates no marker
directory, writes no marker, and performs no pruning. The warning must not
reflect raw stdin, session values, or secret-like values; UserPromptSubmit and
Stop remain silent for the same inputs.

The broader consequence: **fail-open hides bugs.** A broken hook exits 0
and is indistinguishable from a hook that decided to allow. A real incident
behind this repository: a PowerShell cast-precedence bug threw on every
run, the catch swallowed it, and the hook simply "never blocked" — no error
appeared anywhere. Therefore:

- Syntax-checking a hook is not testing it.
- Pipe-test the **behavior**: feed synthetic stdin JSON, then assert on the
  output bytes AND the side effects (marker files created, pruned, etc.).
  See `scripts/test-hooks.ps1` for the full pattern, including capturing
  raw stdout through the .NET Process API — PowerShell's own redirection
  re-decodes the stream and can mask encoding bugs.

```powershell
'{"session_id":"t","stop_hook_active":false}' |
    pwsh -NoProfile -File hooks/devlog-stop.ps1
# assert: exit code, stdout JSON (or emptiness), marker side effects
```

## Output Must Be Raw UTF-8 Bytes

Piping `ConvertTo-Json` output straight to stdout encodes it with the
console code page. Claude Code reads hook stdout as UTF-8, so non-ASCII
text (Japanese, emoji) turns into mojibake. Write bytes directly:

```powershell
function Write-Utf8Stdout([string]$s) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
    $stream = [Console]::OpenStandardOutput()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}
```

Related source-encoding rule: Windows PowerShell 5.1 parses BOM-less
`.ps1` files as ANSI, which corrupts non-ASCII string literals (and can
even cause syntax errors mid-literal). The hooks in this repository carry
non-ASCII message text, so they are stored as **UTF-8 with BOM** — PowerShell
7 accepts the BOM too. ASCII-only scripts (like the test harness) stay
BOM-less and construct non-ASCII needles with `[regex]::Unescape`.

The Bash hooks are UTF-8 **without BOM** so the shebang is the first byte.
`printf '%s' "$json"` emits the script's UTF-8 bytes without a console
re-encoding layer. Both implementations are checked by the same strict UTF-8
byte capture in `scripts/test-hooks.ps1`.

## Bash Portability And Dependency Decisions

The Unix implementation targets Bash 3.2+ on macOS/Linux rather than pure
POSIX `sh`. Bash byte iteration lets the shared helper JSON-escape arbitrary
paths without installing jq, Python, or Node.js. Standard utilities used are
`awk`, `head`, `od`, `iconv`, `date`, `dirname`, `mkdir`, `rm`, and `stat`.

- **Input JSON is not evaluated or normalized.** A byte-preserving,
  1,048,576-byte-bounded reader feeds hexadecimal bytes to the self-contained
  AWK parser. NUL and invalid UTF-8 are rejected before any protocol value is
  exposed. The parser requires RFC JSON grammar and one top-level object,
  reads only the exact-case `session_id` and `stop_hook_active` fields, skips
  nested values, and returns no result on malformed or ambiguous input.
  Top-level names are losslessly decoded: exact Unicode-scalar duplicates and
  ASCII-case-fold collisions make the whole input unjudgeable even when the
  name is otherwise unknown. Distinct non-ASCII case pairs remain distinct,
  avoiding locale-specific behavior. A non-object root, alias-only field, or
  session id outside 1-64 characters of `[A-Za-z0-9_.-]` cannot establish identity and
  therefore fails open without marker side effects.
- **Byte bounds need work bounds.** The shared parser also limits container
  depth to 128, every property name to 256 Unicode scalars, every number token
  to 1,024 characters, and property values plus array elements to 4,096. The
  Bash parser validates large ordinary strings without concatenating them and
  streams number grammar, keeping the exact 1 MiB path linear.
- **Parser result framing is non-whitespace.** Bash collapses adjacent
  whitespace `IFS` delimiters, so a valid no-session result such as
  `0<TAB><TAB>0` loses its empty middle field. The marker-safe alphabet
  excludes `|`; the helper therefore emits and reads `0||0` / `0||1`
  losslessly. Direct helper probes distinguish those valid states from parse
  failure on every runtime.
- **Portable marker keys need their own namespace.** Raw IDs collide under
  Windows case folding and can hit reserved basenames. Lowercase hex is
  injective, while the `~sid-` prefix cannot be emitted by the former accepted
  or sanitized filename scheme. Existing sessions with only a legacy marker
  therefore fail open until the next SessionStart; retention later prunes the
  legacy file.
- **Output path escaping is byte-based.** Quote/backslash are escaped and C0
  controls become `\u00xx`; UTF-8 bytes pass through unchanged. POSIX-only
  tests use synthetic paths containing quote, backslash, tab, newline, and
  `0x01`.
- **Validate path encoding before reflection or mutation.** POSIX environment
  values can contain invalid UTF-8. `iconv -f UTF-8 -t UTF-8` validates the
  selected root while preserving the original value; failure is silent and
  happens before output or filesystem access.
- **`stat` differs by platform.** Linux uses `stat -c %Y`; macOS/BSD uses
  `stat -f %m`. Failure in both forms is unjudgeable and therefore silent.
- **Fail-silent is an outer boundary.** Each entrypoint disables inherited
  `errexit`/`nounset`/`pipefail`, runs `main 2>/dev/null || :`, and ends in
  `exit 0`. Commands that intentionally produce JSON use only `printf`.
- **Keep the directory together.** The three `.sh` entrypoints source
  `devlog-common.sh` relative to `BASH_SOURCE[0]`. The three `.ps1`
  entrypoints use the equivalent shared parser in `devlog-common.ps1`.

The complete architecture and dependency rationale live in
[posix-hooks-design.md](posix-hooks-design.md); the cross-shell matrix lives in
[posix-hooks-test-plan.md](posix-hooks-test-plan.md).

## PowerShell Gotchas That Bit These Hooks

- **Cast precedence**: member access binds tighter than a cast.
  `[DateTimeOffset]$x.ToUnixTimeSeconds()` casts the RESULT of the method
  call (which does not exist on DateTime) instead of casting `$x` first.
  Always parenthesize: `([DateTimeOffset]$dt).ToUnixTimeSeconds()`. This
  exact bug, swallowed by fail-open, silently disabled the Stop hook once.
- **Do not use `ConvertFrom-Json` as a grammar validator.** Besides
  case-insensitive member lookup and single-element-array scalarization,
  PowerShell accepts non-RFC extensions such as unquoted/single-quoted keys,
  leading-zero numbers, `NaN`, and (on PS 7) trailing commas. The shared
  parser reads at most 1,048,576 raw bytes, strictly decodes UTF-8, validates
  the RFC grammar, checks losslessly decoded top-level names, and extracts
  protocol fields with ordinal exact names and explicit `HasSession` /
  `StopActive` state. Production entrypoints still avoid `Set-StrictMode`:
  a new strict-mode error could be swallowed by their fail-open boundary and
  silently disable behavior. Test harnesses and validators remain fail-closed
  under `Set-StrictMode -Version Latest`.
- **Use case-sensitive operators for JSON grammar tokens.** PowerShell's
  `-eq` / `-ne` string comparisons ignore case by default, which can turn
  invalid `\B`, `\F`, `\N`, `\R`, `\T`, or `\U` spellings into valid JSON
  escapes. Escape and literal dispatch therefore use `-ceq` / `-cne`, with
  cross-runtime negative fixtures for uppercase escape letters.
- **Require the protocol boolean type.** PowerShell treats any non-empty
  string as truthy, and even loose `-eq $true` coerces the string `"true"` to
  a boolean. The shared parser exposes the loop guard only when the exact
  `stop_hook_active` property is a real JSON boolean `true`.
- **PS 5.1 turns redirected native stderr into terminating errors** while
  `$ErrorActionPreference = 'Stop'`. Any harness that shells out (git, a
  child PowerShell) with `2>&1` or `2>$null` must scope the preference down
  to `'Continue'` around the call and rely on exit codes.
- **Marker files**: write plain ASCII content (`-Encoding ascii`, epoch
  digits only) so any shell can read them back without BOM or code-page
  concerns. Read only canonical 1-18 byte decimal values, reject multi-digit
  leading zeroes, and avoid whole-file helpers. Bash checks size before and
  after a maximum-19-byte read; PowerShell opens a `FileStream`, checks its
  length, and reads exactly that bounded length.

## Registration (settings.json)

PowerShell:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File C:/path/to/claude-code-devlog-hooks/hooks/devlog-session-start.ps1",
            "timeout": 15,
            "statusMessage": "Checking dev journal routine"
          }
        ]
      }
    ]
  }
}
```

macOS/Linux Bash:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash --noprofile --norc /path/to/claude-code-devlog-hooks/hooks/devlog-session-start.sh",
            "timeout": 15,
            "statusMessage": "Checking dev journal routine"
          }
        ]
      }
    ]
  }
}
```

Complete three-event examples are
[`examples/hooks-settings.json`](../examples/hooks-settings.json) for
PowerShell and
[`examples/hooks-settings.bash.json`](../examples/hooks-settings.bash.json)
for Bash.

- Use **forward slashes and a space-free path** in `command`: the string
  survives both bash-style and native execution without quoting problems.
- `-NoProfile` keeps startup fast and deterministic; `-ExecutionPolicy
  Bypass` removes a machine-policy dependency.
- Per the official hooks reference: `Stop` and `UserPromptSubmit` have **no
  matcher support** (they always fire — do the filtering inside the
  script), and `SessionStart` matchers (`startup` / `resume` / `clear` /
  `compact`) are optional — registering without a matcher fires on all of
  them, which is what these hooks want.
- **Exit code semantics**: exit 0 + JSON on stdout is the structured path
  used here (`hookSpecificOutput.additionalContext` for
  SessionStart/UserPromptSubmit, `decision: "block"` + `reason` for Stop).
  Exit 2 + stderr is a blunter alternative blocking path; other exit codes
  are non-blocking errors.
- **Config reflection timing**: current Claude Code settings documentation
  says hook changes are watched and reloaded in running sessions. A past event
  is not replayed, so use `/hooks` to review the active registration and start
  a new session for a deterministic SessionStart smoke test.

## Design Decisions Specific To These Hooks

- **One variable drives all paths.** Everything derives from the devlog
  root (`CLAUDE_DEVLOG_DIR`, falling back to a script-top default in either
  implementation):
  `daily/<date>.md`, `topics/`, and `.devlog-markers/`. No other location
  is read or written.
- **Markers live under the devlog root**, so wiping or moving the root
  never leaves stale state elsewhere, and the hooks stay portable.
- **Marker pruning**: SessionStart fires on startup, resume, and compact,
  so markers accumulate; each run with an established identity prunes markers
  older than `$MarkerRetentionDays` / `MARKER_RETENTION_DAYS` (default 7
  days). Unjudgeable identity input neither creates the directory nor prunes
  prior markers.
- **The double gate for nudges**: nudge only when (session age >=
  threshold) AND (journal staleness >= threshold), both against the same
  `$ThresholdSec` / `THRESHOLD_SEC` (default 20 minutes). One gate alone
  either nags fresh sessions or nags right after a legitimate update.
- **Language switching** (`CLAUDE_DEVLOG_LANG`: `ja` default / `en`) is
  resolved per-run from the environment, with unknown values falling back
  to the script default. Messages are the only localized part; the JSON
  field names are fixed by the hooks contract.

## Known Limitations (By Design)

- **Midnight rollover**: "today's journal" is recomputed at judgment time,
  so a session crossing midnight is judged against the NEW day's file. The
  Stop hook may block once more after midnight even though you wrote an
  entry yesterday evening. Consistent with "little and often", but worth
  knowing.
- **Resume/compact re-arm**: SessionStart fires on resume and compaction
  and refreshes the marker, so a long session that compacts re-arms the
  once-per-session block. The interpretation: if enough happened to fill
  the context window, there is probably something new worth journaling.
- **Same-day multi-session quiet period**: the Stop comparison is per
  session, but the journal file is per day — any session started before the
  most recent journal write is already satisfied.
- **Marker pruning vs. week-long sessions**: a session idle past the marker
  retention window loses its marker; the hooks then fail open (no block, no
  nudge) rather than misjudge.
