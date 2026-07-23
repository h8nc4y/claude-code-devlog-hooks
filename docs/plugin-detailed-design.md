# Claude Code Plugin Detailed Design

## Manifest

`.claude-plugin/plugin.json` declares:

- `name`: `claude-code-devlog-hooks`;
- public metadata already represented by this repository;
- `version`: the next minor plugin package version;
- two optional, non-sensitive `userConfig` fields:
  - `devlog_dir` with type `directory`;
  - `devlog_lang` with type `string`.

Both fields remain optional so existing `CLAUDE_DEVLOG_*` environments and
the built-in defaults keep working. The language description constrains
supported values to `ja` and `en`; the existing hooks still normalize any
other value to their default.

## Hook registration

`hooks/hooks.json` contains exactly these top-level events:

| Event | Launcher argument | Timeout | Status |
| --- | --- | --- | --- |
| `SessionStart` | `session-start` | 15 seconds | 開発ログ運用を確認中… |
| `UserPromptSubmit` | `prompt-nudge` | 15 seconds | 開発ログの追記時機を確認中… |
| `Stop` | `stop` | 15 seconds | 開発ログ記入を確認中… |

Each handler uses:

- `shell`: `bash`, so Claude Code selects its configured Git Bash on native
  Windows instead of an unrelated WSL `bash.exe` from `PATH`;
- `command`: the quoted
  `"${CLAUDE_PLUGIN_ROOT}"/hooks/devlog-plugin-launcher.sh` path plus the fixed
  event argument.

No matcher is specified, matching the existing manual configuration. No
`${user_config.*}` placeholder appears in hook command text.
`hooks/devlog-plugin-launcher.sh` and its direct CI test entrypoint retain Git
index mode `100755`; a PowerShell package test checks the index mode so Windows
development cannot silently commit them as non-executable.

## Launcher algorithm

1. Enable bounded Bash error handling without tracing.
2. Map the event argument through a `case` allowlist to one PowerShell and one
   Bash filename. Any other value exits `64` with a fixed diagnostic.
3. Derive the plugin root from the parent of the launcher's own
   `BASH_SOURCE` directory. Claude Code already used `CLAUDE_PLUGIN_ROOT` to
   locate that launcher; reusing the environment value inside Git Bash could
   reintroduce a native-Windows path format.
4. If a plugin option is non-empty, export it under the corresponding legacy
   hook variable. Never modify a legacy value for an empty plugin option.
5. Read `uname -s` once. Do not print it.
6. For the Windows family, resolve `cygpath` and convert the fixed PowerShell
   target with `cygpath -m --`. Missing, failed, or empty conversion exits `64`
   with a fixed diagnostic before any runtime starts.
7. Select one runtime:
   - Windows family: `pwsh`, then `powershell.exe`, then `powershell`, then
     Bash;
   - supported Unix family: Bash;
   - unsupported: fixed diagnostic and exit `64`.
8. Confirm the fixed target file exists.
9. Replace the launcher with exactly one runtime process using `exec`.
   PowerShell receives `-NoProfile -NonInteractive -ExecutionPolicy Bypass
   -File` and the converted native path; Bash receives `--noprofile --norc`.

The launcher does not catch or rewrite the selected hook's stdout, stderr, or
exit code.

## Documentation behavior

README installation order becomes:

1. plugin package path and configuration semantics;
2. explicit statement that marketplace publication/live installation are not
   verified by this change;
3. existing manual settings path as a supported fallback.

The configuration table names both plugin options and legacy variables, with
their priority. Uninstall instructions distinguish disabling/removing a
future installed plugin from removing manual settings.

## CI and validation changes

- Add `scripts/test-plugin.ps1` for manifest and hook-registration assertions.
- Add `scripts/test-plugin-launcher.sh` for runtime-dispatch and environment
  bridge assertions using synthetic executables only.
- Run plugin tests on Windows and Ubuntu.
- Run `claude plugin validate . --strict` locally when the CLI is available.
  CI must not install or authenticate Claude Code merely to obtain the
  validator; deterministic repository tests remain the CI gate.
- Extend OSS readiness checks to require the plugin files, design documents,
  root skill discovery contract, and plugin validation commands in README.
