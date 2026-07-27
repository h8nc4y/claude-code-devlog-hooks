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

### Class M macOS compatibility follow-up

The compatibility increment verifies that existing contract on a standard
GitHub-hosted `macos-15` runner. It must use the system `/bin/bash`, prove that
the host is Darwin and the selected shell is Bash 3.2, then run the existing
synthetic plugin and hook suites. The initial change adds CI coverage and its
exact readiness contract. If that native runner exposes a compatibility gap,
the follow-up may change the shared Bash helper only as needed to restore this
documented behavior; configuration, journal access, and plugin distribution
remain unchanged.

The job must be finite, must not install packages, and must not use a live
Claude Code plugin registration, a real Vault, credentials, OAuth, secrets, or
real user data. Documentation may call macOS/Bash 3.2 verified only after the
GitHub-hosted job completes successfully.

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

- `session_id`, accepted only as a non-empty JSON string and then reduced to
  the marker filename alphabet `[A-Za-z0-9_.-]`; and
- `stop_hook_active`, accepted only when its value is the literal JSON boolean
  `true`.

The parser skips quoted and compound values, so same-named nested fields do not
affect the protocol decision. Malformed input and non-string session ids follow
the existing fail-open behavior (SessionStart uses the `unknown` marker; nudge
and Stop stay silent).

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

The numeric `%d` conversion is entered only after a C-locale control-character
match. Bash 3.2 sign-extends bytes `0x80` through `0xff` when they are passed
to that conversion, so classifying every byte numerically would corrupt
Japanese text and emoji into long `\uffff...` fragments. DEL remains raw, as
before, while C0 controls use the bounded `\u00xx` branch.

NUL needs no branch: Unix environment variables and filenames cannot contain
it, and Bash variables cannot store it. The POSIX-only synthetic tests create
paths containing Japanese text, an emoji, a warning sign, quote, backslash,
tab, newline, and `0x01`, then strictly decode the hook output as UTF-8 JSON
and compare the round-tripped path.

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
JSON escaping. CI runs those checks on `ubuntu-latest` and on a finite
`macos-15` job using the system `/bin/bash`.

PR #12 [Actions run 30199559874](https://github.com/h8nc4y/claude-code-devlog-hooks/actions/runs/30199559874)
verified macOS 15.7.7 and system Bash 3.2.57. The job passed the Darwin/Bash
canary, readiness, plugin contract, all-script syntax gate, 13 launcher cases,
and all 33 hook cases, including exact Japanese/emoji/control-byte JSON
round-trips. Live Claude Code registration and real in-session journal behavior
on macOS remain outside this synthetic CI scope.
