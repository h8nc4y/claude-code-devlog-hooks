# Bash Hooks Test Plan

## Purpose

Prove behavioral equivalence between the PowerShell and Bash hooks, including
fail-silent side effects that an exit-code-only test would miss. All fixtures
are synthetic throwaway directories selected through `CLAUDE_DEVLOG_DIR`.

## Test Matrix

| Target | Host | Command | Expected cases |
| --- | --- | --- | --- |
| PowerShell hooks | Windows, PowerShell 7 | `pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell pwsh` | 30 shared |
| PowerShell hooks | Windows, Windows PowerShell 5.1 | `pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell powershell` | 30 shared |
| Bash hooks | Windows WSL or Git Bash | `pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell bash` | 30 shared |
| Bash hooks | Ubuntu CI | `pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell bash` | 30 shared + 3 POSIX-path cases |
| Bash hooks | macOS 15 CI, system Bash 3.2 | `pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell /bin/bash` | 30 shared + 3 POSIX-path cases |

The Windows Bash run translates only synthetic fixture paths. WSL imports
`CLAUDE_DEVLOG_DIR` and `CLAUDE_DEVLOG_LANG` through a child-only `WSLENV`;
Git Bash uses its bundled `cygpath`. Production hooks have no Windows-path
adapter because their supported runtime is native macOS/Linux.

## Shared Behavioral Coverage

### SessionStart (6)

- writes a near-current ASCII epoch marker and Japanese context;
- prunes an eight-day-old marker while retaining a fresh one;
- sanitizes unsafe session-id characters;
- uses `unknown` when `session_id` is absent;
- degrades invalid stdin to `unknown` while still injecting context; and
- switches to English.

### UserPromptSubmit (8)

- stays silent for a young session;
- stays silent after a recent journal update;
- fires when the journal is missing;
- fires when the journal is stale;
- stays silent without a marker;
- stays silent without a session id;
- stays silent on corrupt marker content; and
- switches to English.

### Stop (10)

- allows when top-level `stop_hook_active` is the boolean `true`;
- allows without a session id;
- allows without a marker;
- blocks when the journal is missing;
- blocks when the journal predates session start;
- allows after a current-session journal update;
- allows on corrupt marker content;
- allows on invalid stdin;
- allows when an ignored nested value makes the JSON grammar invalid;
- switches to English (the blocking cases also assert the expected daily path
  in the reason).

### Fail-silent And Defensive Regressions (6)

- an unwritable root leaks no stderr and discloses disabled enforcement;
- a directory occupying the Stop marker path fails open silently;
- a directory occupying the nudge marker path fails open silently;
- string values `"false"` and `"true"` do not activate the boolean loop
  guard; and
- a nested `stop_hook_active: true` does not activate the top-level guard.

The logical total is 30 cases; multiple assertions within a case verify output
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

- All three shell targets pass the shared 30 cases.
- Ubuntu passes all 33 cases and Bash syntax validation.
- The standard `macos-15` job proves Darwin plus system `/bin/bash` 3.2, then
  passes the plugin package, launcher, all 33 Bash-hook cases, and syntax gate
  within a finite timeout.
- No hook emits stderr in any behavioral case.
- UTF-8 output and path JSON round-trips are exact.
- No real devlog, secret, OAuth value, customer data, or paid service is used.
- Actual macOS live-session behavior remains outside this synthetic CI scope.
  Until the new job is green, macOS/Bash 3.2 execution also remains explicitly
  unverified.
