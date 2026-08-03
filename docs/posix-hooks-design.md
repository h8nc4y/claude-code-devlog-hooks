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
Unix utilities (`awk`, `date`, `dirname`, `head`, `iconv`, `mkdir`, `od`,
`rm`, and `stat`).

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
   seven days only after establishing a 1-64 character session identity in
   `[A-Za-z0-9_.-]`. The identity is encoded into a lowercase-hex `~sid-`
   marker key before filesystem access.
   Unjudgeable identity input injects a fixed warning and changes no marker
   state.
7. UserPromptSubmit nudges only when both the session age and journal
   staleness reach 20 minutes.
8. Stop blocks only while the journal mtime is older than the session marker.
   A missing/corrupt marker fails open.
9. Input is read without a Bash variable through a 1,048,576-byte-bounded
   byte stream. NUL, invalid UTF-8, oversized input, non-RFC grammar, and any
   root other than one object are unjudgeable.
10. Protocol names are compared after lossless escape decoding with exact
    case. Every top-level property name must be unique by Unicode-scalar exact
    identity and ASCII-case-folded identity; exact duplicates or ASCII case
    collisions make the whole input unjudgeable. Non-ASCII case pairs remain
    distinct unknown fields.
11. Only an exact top-level JSON boolean `stop_hook_active: true` activates the
    loop guard. Strings, case aliases, and nested fields do not.
12. Root depth is at most 128, each property name is at most 256 Unicode
    scalars, each number is at most 1,024 characters, and the document has at
    most 4,096 property values plus array elements.
13. The configured devlog root must be valid UTF-8. A non-UTF-8 POSIX
    environment value fails open before output or filesystem mutation.
14. The configured root is the trust anchor, but its `.devlog-markers` child
    and marker leaves must not be symbolic links. Linked state makes
    SessionStart disclose disabled enforcement and makes nudge/Stop allow
    silently. Existing regular or hard-linked marker entries are unlinked and
    exclusively recreated so another hard-link name is never truncated.

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

`devlog-common.sh` converts at most 1,048,577 stdin bytes to a bounded
hexadecimal stream, rejecting the extra byte, NUL, invalid UTF-8, and non-RFC
JSON before protocol extraction. The AWK parser first requires one top-level
object. After lossless JSON escape decoding, it extracts only:

- `session_id`, accepted only as a 1-64 character JSON string in
  `[A-Za-z0-9_.-]`; and
- `stop_hook_active`, accepted only when its value is the literal JSON boolean
  `true`.

Field names are case-sensitive: aliases such as `SESSION_ID` are ignored.
Every top-level property name must be unique under exact Unicode-scalar and
ASCII-case-folded comparison. Literal/escaped exact duplicates and ASCII case
collisions, including unknown fields, make the whole document unjudgeable;
distinct non-ASCII case pairs stay distinct. The parser validates but does not
accumulate ordinary string values or primitive tokens. It accumulates only
bounded top-level property identities and a valid bounded session id, keeping
the 1 MiB path linear rather than quadratic in AWK. Compound values are
otherwise skipped, so same-named nested fields do not affect the protocol
decision. Malformed input,
a non-object root, and missing, empty, or non-string session ids cannot
establish identity. SessionStart injects the routine plus a fixed
non-reflective JA/EN warning but creates/prunes no marker state; nudge and Stop
stay silent.

This parser is deliberately not a general JSON API. Protocol fields outside
the two listed above are ignored.

Raw hook stdin is never emitted into command substitution or captured in a
Bash variable. It flows directly through `head -c`, which caps acquisition at
limit plus one byte, and `od`, which preserves every byte as hex. Only the
three small parser result fields are emitted and captured by command
substitution. That bounded parser subshell enables `pipefail`, so a partial
`head`/`od` failure cannot become an apparently valid object. This prevents
Bash from silently deleting NUL and turning malformed JSON into an enforceable
session.

The result uses `|` as a non-whitespace delimiter. The marker-safe session
alphabet cannot contain `|`, and Bash therefore preserves the empty middle
field in valid states such as `0||0` and `0||1`; whitespace `IFS` would collapse
adjacent separators and incorrectly turn those states into parser failures.

Accepted identities are not used as raw filenames. `devlog_marker_name`
encodes every ASCII byte as lowercase hex and prefixes `~sid-`. The mapping is
injective even on case-insensitive filesystems, cannot form Windows reserved
basenames, and is disjoint from the former raw/sanitized marker namespace.
During an update, a session with only a legacy marker therefore fails open;
old `*.start` files remain eligible for normal retention pruning.

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

Before any path use, `devlog_resolve_root` passes the selected environment
value through `iconv -f UTF-8 -t UTF-8`. This validates the value without
replacing the original path bytes. A non-UTF-8 value therefore cannot produce
invalid JSON or a path mutation.

## Portable Time And Filesystem Behavior

- Epoch now: `date -u +%s`.
- Daily filename: `date +%Y-%m-%d`.
- Linux mtime: `stat -c %Y`.
- macOS/BSD mtime: `stat -f %m`.
- Marker content: canonical decimal ASCII epoch, 1-18 bytes, no newline, and
  no leading zero on a multi-digit value.
- Marker directory: an ordinary directory, checked before create/write/read/
  prune. Marker leaves must be ordinary files. Refresh removes the existing
  entry and uses Bash noclobber mode for exclusive recreation; the brief
  missing-marker interval follows the existing fail-open contract.
- Retention: compare each `*.start` file mtime with
  `now - retention_days * 86400`; deletion is best-effort.

Marker reads check GNU/BSD file size before and after a `head -c 19` read. The
read byte count must match the stable size, so a newline, concurrent size
change, leading zero, 19-byte value, or larger file is unjudgeable without an
unbounded `cat`. Other epoch inputs must contain only digits and fit within 18
decimal digits before Bash arithmetic.

## Failure Matrix

| Failure | SessionStart | UserPromptSubmit | Stop |
| --- | --- | --- | --- |
| Invalid stdin JSON | inject fixed identity warning; no marker state | silent allow | silent allow |
| Missing/empty/non-string session id | inject fixed identity warning; no marker state | silent allow | silent allow |
| Root/marker write failure | inject warning; enforcement off | not applicable | not applicable |
| Linked marker directory/leaf | inject warning; no write or prune | silent allow | silent allow |
| Missing/corrupt marker | not applicable | silent allow | silent allow |
| `date`/`stat`/read error | silent allow | silent allow | silent allow |
| JSON escaping/helper load error | silent allow | silent allow | silent allow |

## Security And Privacy Boundaries

- Hooks make no network calls.
- Hooks read only stdin, their own helper, the session marker, and today's
  journal mtime. They never read journal content.
- Hooks write only the marker directory under the configured devlog root, and
  only after a valid session identity is established.
- The configured root itself may intentionally be linked. A linked
  `.devlog-markers` child or marker leaf is rejected. Pure Bash 3.2 cannot pin
  a directory handle against a same-user concurrent namespace replacement;
  that actor is outside the hook threat model and the residual is documented
  in `SECURITY.md`.
- Identity warnings are fixed strings and never reflect stdin, session ids, or
  secret-like values.
- Examples and tests use synthetic paths and content.
- The helper does not evaluate JSON text, shell code, or path contents.

## Verification And Remaining Unknowns

The shared PowerShell harness runs the same behavioral cases against `.ps1`
and `.sh` entrypoints. On a POSIX host, three additional cases exercise path
JSON escaping. CI runs those checks on `ubuntu-latest` and on a finite
`macos-15` job using the system `/bin/bash`.

PR #12 [Actions run 30199559874](https://github.com/h8nc4y/claude-code-devlog-hooks/actions/runs/30199559874)
verified the then-current revision on macOS 15.7.7 and system Bash 3.2.57. That
job passed the Darwin/Bash canary, readiness, plugin contract, all-script
syntax gate, 13 launcher cases, and the then-current 33 hook cases. It is
historical evidence for the runner and Bash 3.2 path, not verification of the
then-current 65/68-case resource-boundary patch. PR #18
[Actions run 30665994905](https://github.com/h8nc4y/claude-code-devlog-hooks/actions/runs/30665994905)
then verified that patch on Ubuntu Bash 5.2.21 and macOS system Bash
3.2.57. Ubuntu passed all 68 cases plus readiness, plugin, launcher, syntax,
and private-marker scanner gates. macOS passed all 68 cases plus readiness,
plugin, launcher, and syntax gates; that job does not run the scanner. Live
Claude Code registration and real in-session journal behavior remain unverified.
