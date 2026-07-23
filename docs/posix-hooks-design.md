# Bash Hooks Design

Status: implemented on `feature/posix-hooks`; release status remains
`Unreleased`.

## Objective

Provide macOS and Linux users with the same three-layer journaling behavior as
the PowerShell hooks without requiring PowerShell, jq, Python, Node.js, network
access, or real journal data in tests.

This is a Bash port, not a pure POSIX `sh` port. Bash 3.2 is the compatibility
floor so the scripts can run with the older system Bash still found on macOS.
The implementation uses only Bash features available in 3.2 plus standard
Unix utilities (`awk`, `cat`, `date`, `mkdir`, `rm`, and `stat`).

## Required Behavioral Contract

The Bash and PowerShell variants share these observable invariants:

1. Every path exits `0`. An error or unjudgeable state allows the session to
   continue.
2. Errors produce no stdout or stderr. Structured JSON is the only successful
   stdout.
3. Output is raw UTF-8 with no BOM. Bash `printf` writes the already-encoded
   script bytes directly.
4. `CLAUDE_DEVLOG_DIR` is the only path input. `daily/`, `topics/`, and
   `.devlog-markers/` derive from it.
5. `CLAUDE_DEVLOG_LANG` accepts only `ja` or `en`; any other value falls back
   to the script default.
6. SessionStart writes an ASCII epoch marker and prunes markers older than
   seven days.
7. UserPromptSubmit nudges only when both the session age and journal
   staleness reach 20 minutes.
8. Stop blocks only while the journal mtime is older than the session marker.
   A missing/corrupt marker fails open.
9. Only a top-level JSON boolean `stop_hook_active: true` activates the loop
   guard. Strings and nested fields do not.

## File Architecture

| File | Responsibility |
| --- | --- |
| `hooks/devlog-common.sh` | Top-level input parsing, root/language resolution, JSON escaping, epoch validation, GNU/BSD mtime adapter, marker reads and pruning |
| `hooks/devlog-session-start.sh` | Context injection, marker write, retention pruning, degraded-enforcement warning |
| `hooks/devlog-prompt-nudge.sh` | Session-age gate plus daily-journal staleness gate |
| `hooks/devlog-stop.sh` | Strict boolean loop guard and enforce-once mtime comparison |

The three entrypoints resolve the helper relative to `BASH_SOURCE[0]`, so the
whole `hooks/` directory must stay together. Each entrypoint disables inherited
`errexit`, `nounset`, and `pipefail`, runs `main` with stderr redirected to
`/dev/null`, ignores its status, and ends with `exit 0`.

## Dependency Decision

`jq` would make JSON handling short, but it would add an installation
requirement to hooks that run on every turn. The port therefore does not use
it.

`devlog-common.sh` contains a bounded AWK parser for the top-level JSON object.
It extracts only:

- `session_id`, reduced to the marker filename alphabet
  `[A-Za-z0-9_.-]`; and
- `stop_hook_active`, accepted only when its value is the literal JSON boolean
  `true`.

The parser skips quoted and compound values, so same-named nested fields do not
affect the protocol decision. Malformed input produces no parse result and the
entrypoint follows its existing fail-open behavior (SessionStart uses the
`unknown` marker; nudge and Stop stay silent).

This parser is deliberately not a general JSON API. Protocol fields outside
the two listed above are ignored.

## JSON Output And Path Escaping

Output messages contain the configured devlog path, which Unix permits to
include quotes, backslashes, tabs, newlines, and other C0 controls. Building
JSON with simple interpolation would therefore be invalid or ambiguous.

`devlog_json_escape` iterates bytes in the C locale:

- `"` becomes `\"`;
- `\` becomes `\\`;
- bytes `0x01` through `0x1f` become `\u00xx`; and
- UTF-8 bytes at or above `0x20` pass through unchanged.

NUL needs no branch: Unix environment variables and filenames cannot contain
it, and Bash variables cannot store it. The POSIX-only synthetic tests create
paths containing quote, backslash, tab, newline, and `0x01`, then strictly
decode the hook output as UTF-8 JSON and compare the round-tripped path.

## Portable Time And Filesystem Behavior

- Epoch now: `date -u +%s`.
- Daily filename: `date +%Y-%m-%d`.
- Linux mtime: `stat -c %Y`.
- macOS/BSD mtime: `stat -f %m`.
- Marker content: decimal ASCII epoch with no newline requirement.
- Retention: compare each `*.start` file mtime with
  `now - retention_days * 86400`; deletion is best-effort.

Epoch inputs must contain only digits and fit within 18 decimal digits. Larger
or malformed values are unjudgeable and fail open before Bash arithmetic.

## Failure Matrix

| Failure | SessionStart | UserPromptSubmit | Stop |
| --- | --- | --- | --- |
| Invalid stdin JSON | inject with `unknown` marker | silent allow | silent allow |
| Missing session id | inject with `unknown` marker | silent allow | silent allow |
| Root/marker write failure | inject warning; enforcement off | not applicable | not applicable |
| Missing/corrupt marker | not applicable | silent allow | silent allow |
| `date`/`stat`/read error | silent allow | silent allow | silent allow |
| JSON escaping/helper load error | silent allow | silent allow | silent allow |

## Security And Privacy Boundaries

- Hooks make no network calls.
- Hooks read only stdin, their own helper, the session marker, and today's
  journal mtime. They never read journal content.
- Hooks write only the marker directory under the configured devlog root.
- Examples and tests use synthetic paths and content.
- The helper does not evaluate JSON text, shell code, or path contents.

## Verification And Remaining Unknowns

The shared PowerShell harness runs the same behavioral cases against `.ps1`
and `.sh` entrypoints. On a POSIX host, three additional cases exercise path
JSON escaping. CI adds an `ubuntu-latest` Bash job and syntax check.

Actual macOS/Bash 3.2 execution is not yet verified. Compatibility is
design-derived from the feature set and the BSD `stat` fallback; keep that
limitation explicit until a real macOS run is recorded.
