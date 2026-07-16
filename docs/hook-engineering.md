# Hook Engineering Notes (PowerShell, Windows-first)

Field-derived patterns for writing Claude Code hooks in PowerShell, and the
specific design decisions behind the three hooks in this repository. Every
rule here traces to an observed failure or to the official hooks reference
(field names and event semantics verified against
`https://code.claude.com/docs/en/hooks` on 2026-07-16).

## The Three-Layer Pattern

One behavioral goal ("keep the journal updated, little and often") maps to
three hooks with different pressure levels:

1. **SessionStart — inform.** Inject the routine via
   `hookSpecificOutput.additionalContext` and record state (a session-start
   marker) for the other layers.
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
  keyed by `session_id`.
- Stop compares: `daily journal mtime >= session start epoch` means "already
  updated this session" — allow. Otherwise block once with instructions.
- After the journal is written once, every later turn in the session passes
  the comparison, so the hook never blocks again.

Two guards keep this safe:

- **`stop_hook_active`**: when the input JSON carries `stop_hook_active:
  true`, a Stop hook already blocked and the agent is continuing because of
  it. Exit 0 immediately — otherwise you can build an infinite block loop.
- **Missing marker means allow**: if the marker does not exist (hook
  installed mid-session, marker pruned, SessionStart failed), the state is
  unjudgeable. Fail open.

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

## PowerShell Gotchas That Bit These Hooks

- **Cast precedence**: member access binds tighter than a cast.
  `[DateTimeOffset]$x.ToUnixTimeSeconds()` casts the RESULT of the method
  call (which does not exist on DateTime) instead of casting `$x` first.
  Always parenthesize: `([DateTimeOffset]$dt).ToUnixTimeSeconds()`. This
  exact bug, swallowed by fail-open, silently disabled the Stop hook once.
- **No `Set-StrictMode` inside hooks.** The hook logic relies on absent
  JSON properties evaluating to `$null` (`$data.stop_hook_active` on input
  that lacks the field). Under strict mode that access throws, the fail-open
  catch eats it, and the hook is silently disabled — strictness makes the
  hook LESS correct. Test harnesses and validation scripts, which fail
  closed, should keep `Set-StrictMode -Version Latest`. Note this is a
  different axis from `$ErrorActionPreference = 'Stop'`, which the hooks DO
  set: EAP governs how cmdlet errors surface (catchable vs stderr leak),
  StrictMode governs whether absent variables/properties are errors.
- **Compare protocol booleans explicitly.** PowerShell treats any non-empty
  string as truthy, so `if ($data.stop_hook_active)` would treat a
  defensive string value `"false"` as true and skip enforcement. Use
  `($data.stop_hook_active -eq $true)` for fields the spec defines as
  booleans.
- **PS 5.1 turns redirected native stderr into terminating errors** while
  `$ErrorActionPreference = 'Stop'`. Any harness that shells out (git, a
  child PowerShell) with `2>&1` or `2>$null` must scope the preference down
  to `'Continue'` around the call and rely on exit codes.
- **Marker files**: write plain ASCII content (`-Encoding ascii`, epoch
  digits only) so any shell can read them back without BOM or code-page
  concerns.

## Registration (settings.json)

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
- **Config reflection timing**: hooks added to `settings.json` mid-session
  may not fire in the already-running session. They reliably apply from the
  next session (or after reviewing `/hooks`). Plan verification accordingly.

## Design Decisions Specific To These Hooks

- **One variable drives all paths.** Everything derives from the devlog
  root (`CLAUDE_DEVLOG_DIR`, falling back to a script-top default):
  `daily/<date>.md`, `topics/`, and `.devlog-markers/`. No other location
  is read or written.
- **Markers live under the devlog root**, so wiping or moving the root
  never leaves stale state elsewhere, and the hooks stay portable.
- **Marker pruning**: SessionStart fires on startup, resume, and compact,
  so markers accumulate; each run prunes markers older than
  `$MarkerRetentionDays` (default 7 days).
- **The double gate for nudges**: nudge only when (session age >=
  threshold) AND (journal staleness >= threshold), both against the same
  `$ThresholdSec` (default 20 minutes). One gate alone either nags fresh
  sessions or nags right after a legitimate update.
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
