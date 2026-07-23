# Claude Code Plugin Test Plan

## Strategy

Plugin packaging can fail while every underlying hook remains correct. Tests
therefore cover three layers independently:

1. static package/schema contract;
2. launcher selection and configuration bridge;
3. unchanged hook behavior on every existing runtime.

All launcher fixtures use synthetic executables and throwaway directories.
They do not load a plugin into Claude Code or touch a real journal.

## Red-first package cases

`scripts/test-plugin.ps1` must initially fail until the package exists, then
assert:

1. manifest and `hooks/hooks.json` parse as JSON;
2. manifest name, version, and both `userConfig` definitions are present;
3. the root `SKILL.md` exists and no redundant custom `skills` path is set;
4. no `skills/` directory exists and the manifest points to the reviewed
   `./hooks/hooks.json`;
5. the launcher and its direct CI test have Git index mode `100755`;
6. exactly three expected events are registered;
7. each event has exactly one command handler;
8. every handler uses `shell: "bash"` and the same quoted launcher path;
9. fixed event arguments map one-to-one;
10. timeout is `15` and `statusMessage` is non-empty for all three;
11. no handler contains an `args` field that could resolve a generic PATH
   `bash` instead of Claude Code's selected shell;
12. neither JSON file contains `${user_config.*}`, a local absolute path,
    secret-like fixture, or a second runtime handler.

## Launcher cases

`scripts/test-plugin-launcher.sh` runs the real launcher with synthetic
`uname`, `pwsh`, `powershell`, and `bash` executables:

| Case | Expected selected runtime |
| --- | --- |
| Windows with `pwsh` available | `pwsh` only |
| Windows without `pwsh` | Windows PowerShell only |
| Windows without PowerShell | Bash only |
| Linux | Bash only |
| macOS | Bash only |
| unknown platform | none; fixed exit `64` |
| unknown event | none; fixed exit `64` |
| missing bundled hook | none; fixed exit `66` |
| missing Windows `cygpath` | none; fixed exit `64` |
| failed Windows path conversion | none; fixed exit `64` |

For each of the three valid events, the selected synthetic runtime must receive
the expected fixed hook filename and the exact stdin payload. Trace output
must contain one runtime invocation only.

Configuration cases:

- plugin directory option overrides legacy directory;
- blank plugin directory option preserves the legacy directory;
- plugin language option overrides legacy language;
- blank plugin language option preserves the legacy language;
- a path containing spaces remains one exact environment value;
- a native Git Bash plugin root containing valid shell metacharacters reaches
  the real PowerShell hook through an explicit Windows-path conversion;
- missing and failed Windows path conversion both fail closed before the
  PowerShell runtime is invoked;
- neither a secret-looking environment value nor a synthetic raw-log payload
  appears in launcher stdout/stderr on unsupported input.

## Existing behavior matrix

Run `scripts/test-hooks.ps1` unchanged against:

- PowerShell 7 (`pwsh`);
- Windows PowerShell 5.1 (`powershell`);
- Bash (`bash`), with Ubuntu running the extra POSIX-path cases.

This proves that the dispatcher does not substitute for behavior coverage of
the selected hooks.

## Required verification

```text
claude plugin validate . --strict
pwsh -NoProfile -File ./scripts/test-plugin.ps1
bash --noprofile --norc ./scripts/test-plugin-launcher.sh
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell pwsh
pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell powershell
pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell bash
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
bash --noprofile --norc -n ./hooks/*.sh ./scripts/*.sh
git diff --check
```

Also run staged Gitleaks and Semgrep through the host security guard. A live
plugin installation, marketplace publication, real Vault access, and actual
macOS/Bash 3.2 execution remain explicitly unverified.
