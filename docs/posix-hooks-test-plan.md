# Bash Hooks Test Plan

## Purpose

Prove behavioral equivalence between the PowerShell and Bash hooks, including
fail-silent side effects that an exit-code-only test would miss. All fixtures
are synthetic throwaway directories selected through `CLAUDE_DEVLOG_DIR`.

## Test Matrix

| Target | Host | Command | Expected cases |
| --- | --- | --- | --- |
| PowerShell hooks | Windows, PowerShell 7 | `pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell pwsh` | 65 shared |
| PowerShell hooks | Windows, Windows PowerShell 5.1 | `pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell powershell` | 65 shared |
| Bash hooks | Windows WSL or Git Bash | `pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell bash` | 65 shared |
| Bash hooks | Ubuntu CI | `pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell bash` | 65 shared + 3 POSIX-path cases |
| Bash hooks | macOS 15 CI, system Bash 3.2 | `pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell /bin/bash` | 65 shared + 3 POSIX-path cases |

The Windows Bash run translates only synthetic fixture paths. WSL imports
`CLAUDE_DEVLOG_DIR` and `CLAUDE_DEVLOG_LANG` through a child-only `WSLENV`;
Git Bash uses its bundled `cygpath`. Production hooks have no Windows-path
adapter because their supported runtime is native macOS/Linux.

## Shared Behavioral Coverage

### SessionStart (20)

- writes a near-current ASCII epoch marker and Japanese context;
- prunes an eight-day-old marker while retaining a fresh one;
- accepts an exact 64-character marker-safe session id, rejects 65
  characters, unsafe punctuation, and supplementary scalars; proves `A`/`a`,
  `NUL`/`CON`/`COM1`, and the legacy raw namespace select distinct encoded
  markers; and proves `a/b` or `a?b` cannot consume an `a_b.start` marker;
- injects the fixed Japanese identity warning with no marker side effect when
  `session_id` is missing, empty, or non-string, or stdin is malformed;
- never reflects raw/session/secret-like fixture values into stdout, stderr, or
  marker names;
- rejects a single-element top-level array, an alias-only `SESSION_ID`, an exact
  duplicate, and a case-collision without creating or pruning marker state;
- accepts an exact `session_id` name written with JSON Unicode escaping;
- rejects 22 non-RFC grammar samples across both PowerShell hosts and Bash:
  invalid extension/number forms, uppercase `B/F/N/R/T/U` escapes, and lone
  or mismatched surrogate escapes;
- rejects embedded NUL, five invalid UTF-8 forms, and input above 1,048,576 bytes without
  creating marker state or reflecting the synthetic session sentinel;
- accepts exactly 1,048,576 bytes, a scalar leaf inside depth 128, 256-scalar property names,
  1,024-character numbers, and 4,096 values, while rejecting each next value;
- proves the harness drains 128 KiB stdout while writing 1 MiB stdin under one
  finite deadline, kills a child before closing its timed-out pending stdin
  write, and rejects output above the 1 MiB-per-pipe capture cap even while
  the same child refuses a large stdin;
- accepts distinct escaped Unicode unknown names, rejects a literal/escaped
  exact protocol-name duplicate, and keeps unknown fields inert;
- directly proves `{}` parses successfully as `HasSession=0` and
  `StopActive=0`;
- switches the routine to English; and
- switches the fixed identity warning to English.

### UserPromptSubmit (18)

- stays silent for a young session;
- stays silent after a recent journal update;
- fires when the journal is missing;
- fires when the journal is stale;
- stays silent without a marker;
- stays silent without a session id;
- stays silent with an empty session id;
- stays silent for a non-string session id even when a coercion-collision
  marker exists;
- stays silent on malformed stdin;
- stays silent for a single-element top-level array, an alias-only `SESSION_ID`,
  an exact duplicate, and a case-collision even when a matching stale marker
  exists;
- stays silent for the 22 non-RFC grammar samples and embedded NUL;
- stays silent for a literal/escaped Unicode exact unknown-name duplicate;
- stays silent on non-decimal and leading-zero marker content; and
- switches to English.

### Stop (21)

- allows when top-level `stop_hook_active` is the boolean `true`;
- allows without a session id;
- allows with an empty session id;
- allows for a non-string session id even when a coercion-collision marker
  exists;
- allows without a marker;
- blocks when the journal is missing;
- blocks when the journal predates session start;
- allows after a current-session journal update;
- allows on 19-byte and 1 MiB marker content without an unbounded read;
- allows on invalid stdin;
- allows when an ignored nested value makes the JSON grammar invalid;
- allows a single-element top-level array instead of scalarizing it;
- ignores alias-only `STOP_HOOK_ACTIVE` and therefore still blocks when the
  normal enforce-once condition is unmet;
- treats exact duplicates and case collisions of `stop_hook_active` as
  unjudgeable and allows silently;
- treats exact duplicates and case collisions of unknown top-level fields as
  unjudgeable and allows silently;
- allows silently for the 22 non-RFC grammar samples and embedded NUL;
- treats a non-ASCII case pair as two distinct inert unknown names and retains
  the ordinary enforce-once block;
- directly proves a null `session_id` plus boolean `stop_hook_active: true`
  parses successfully as `HasSession=0` and `StopActive=1`;
- switches to English (the blocking cases also assert the expected daily path
  in the reason).

### Fail-silent And Defensive Regressions (6)

- an unwritable root leaks no stderr and discloses disabled enforcement;
- a directory occupying the Stop marker path fails open silently;
- a directory occupying the nudge marker path fails open silently;
- string values `"false"` and `"true"` do not activate the boolean loop
  guard; and
- a nested `stop_hook_active: true` does not activate the top-level guard.

The logical total is 65 cases; multiple assertions within a case verify output
shape, language, path, and side effects together.

## POSIX-only JSON Path Coverage (3)

On non-Windows hosts, create a devlog directory whose name contains:

- Japanese multi-byte UTF-8 text;
- a four-byte emoji and a three-byte warning sign;
- a double quote;
- a backslash;
- a tab;
- a newline; and
- control byte `0x01`.

Run SessionStart, UserPromptSubmit, and Stop separately. For each output:

1. assert exit `0` and empty stderr;
2. assert stdout starts directly with `{` (no BOM/prefix);
3. decode bytes using strict UTF-8;
4. parse JSON;
5. compare the decoded message path with the exact fixture path; and
6. for SessionStart, assert the marker side effect under that path.

The SessionStart POSIX case also injects a non-UTF-8 environment path beneath
a throwaway parent and asserts silent allow with no filesystem mutation.

## Static And Repository Gates

- `for script in hooks/*.sh scripts/*.sh; do bash --noprofile --norc -n "$script" || exit 1; done`
- `for script in hooks/*.sh scripts/*.sh; do /bin/bash --noprofile --norc -n "$script" || exit 1; done` on macOS
- `pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1`
- `pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1`
- `pwsh -NoProfile -File ./scripts/scan-private-markers.ps1`
- `git diff --check`
- `git diff --cached --check` after staging

`validate-oss-readiness.ps1` checks both settings examples, the Bash helper
contract, no BOM on Unix shebang files, the Ubuntu workflow, GNU/BSD `stat`
fallbacks, and the strict PowerShell boolean guard. The macOS follow-up extends
that exact workflow contract to require a finite `macos-15` job, a Darwin plus
`/bin/bash` 3.2 canary, explicit `/bin/bash` syntax/launcher/hook commands, and
the plugin/readiness checks. Mutation fixtures must reject removal or
substitution of each required job, runner, shell, and step.

## Acceptance Criteria

- All three shell targets pass the shared 65 cases.
- Ubuntu passes all 68 cases and Bash syntax validation.
- The standard `macos-15` job proves Darwin plus system `/bin/bash` 3.2, then
  passes the plugin package, launcher, all 68 Bash-hook cases, and syntax gate
  within a finite timeout.
- No hook emits stderr in any behavioral case.
- UTF-8 output and path JSON round-trips are exact.
- No real devlog, secret, OAuth value, customer data, or paid service is used.
- PR #12 [Actions run 30199559874](https://github.com/h8nc4y/claude-code-devlog-hooks/actions/runs/30199559874)
  passed all three jobs. The macOS 15.7.7 job used system Bash 3.2.57 and
  passed the canary, readiness, plugin contract, syntax, 13 launcher cases,
  and the then-current 33 hook cases.
- Actual macOS live-session behavior remains outside this synthetic CI scope;
  only the synthetic system-Bash execution above is verified.
- PR #12 predates the current 65/68-case resource-boundary patch. PR #18
  [Actions run 30665994905](https://github.com/h8nc4y/claude-code-devlog-hooks/actions/runs/30665994905)
  passed the current patch on Windows, Ubuntu Bash 5.2.21, and macOS system
  Bash 3.2.57; Ubuntu/macOS each completed all 68 cases and the required gates.
