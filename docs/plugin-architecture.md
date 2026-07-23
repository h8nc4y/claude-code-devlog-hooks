# Claude Code Plugin Architecture

## Context

Claude Code plugins discover a root `SKILL.md` and `hooks/hooks.json`
automatically. Hook schema has no documented per-operating-system branch.
Registering PowerShell and Bash handlers together would execute both, so the
plugin uses one registered launcher for all three events. On native Windows,
an exec-form command named `bash` can resolve to WSL rather than Claude Code's
detected Git Bash; `shell: "bash"` delegates that choice to Claude Code.

## Component flow

```text
Claude Code event
  -> hooks/hooks.json (Claude-selected Bash shell, one handler)
  -> hooks/devlog-plugin-launcher.sh
       1. validate the fixed event identifier
       2. bridge non-empty plugin options to legacy hook variables
       3. classify the runtime from uname
       4. select exactly one existing hook implementation
  -> hooks/devlog-<event>.ps1 OR hooks/devlog-<event>.sh
  -> existing hook JSON output / marker side effect
```

The launcher is orchestration only. It does not parse hook stdin, inspect the
journal, or reproduce any of the existing hook logic.

## Plugin structure

```text
.claude-plugin/plugin.json       # identity and optional userConfig schema
SKILL.md                         # single root skill, auto-discovered
hooks/hooks.json                 # three event registrations
hooks/devlog-plugin-launcher.sh  # one bounded runtime dispatcher
hooks/devlog-*.ps1               # existing Windows implementation
hooks/devlog-*.sh                # existing Bash implementation
```

No `skills` manifest field is needed. Claude Code loads a root `SKILL.md` as
the single plugin skill when no `skills/` directory or custom skill path is
declared.

## Configuration boundary

Claude Code `2.1.207` exports each `userConfig` value to hook processes as
`CLAUDE_PLUGIN_OPTION_<UPPERCASE_KEY>`. The launcher maps:

| Plugin option | Exported variable | Existing hook variable |
| --- | --- | --- |
| `devlog_dir` | `CLAUDE_PLUGIN_OPTION_DEVLOG_DIR` | `CLAUDE_DEVLOG_DIR` |
| `devlog_lang` | `CLAUDE_PLUGIN_OPTION_DEVLOG_LANG` | `CLAUDE_DEVLOG_LANG` |

For each value independently:

1. non-empty plugin option;
2. existing `CLAUDE_DEVLOG_*` environment variable;
3. existing hook default.

Assignments are quoted environment-variable assignments, never shell source,
`eval`, or command text. This preserves spaces and shell metacharacters as
data.

## Runtime decision

The registration uses `shell: "bash"` and a quoted
`"${CLAUDE_PLUGIN_ROOT}"/...` path, following the official shell-form path
pattern. Bash is already the supported runtime on macOS/Linux. Native Windows
plugin use requires Git Bash, which Claude Code recommends for Bash support.
Using Claude Code's shell selector avoids accidentally spawning a WSL
`bash.exe` found earlier on the generic process `PATH`.

The launcher uses one finite decision:

- `MINGW*`, `MSYS*`, or `CYGWIN*`: first available of `pwsh`,
  `powershell.exe`/`powershell`, or Bash;
- `Darwin`, `Linux`, or a Linux kernel reported by WSL: Bash;
- anything else: fixed diagnostic and exit `64`.

The Windows-family branch first resolves Git Bash's `cygpath` and converts the
fixed PowerShell script path with `cygpath -m --`. This explicit boundary is
required because implicit MSYS argument conversion can fail for otherwise valid
Windows path characters such as `;`, `$()`, `&`, and `[]`. Missing, failed, or
empty conversion fails with the same fixed runtime diagnostic and never invokes
a selected runtime.

Once selected, `exec` replaces the launcher process. It is therefore
impossible for a successful dispatch to execute a second implementation.
Unsupported dispatch is closed: it never guesses a command or falls through
to both hooks. Claude Code treats ordinary non-zero hook errors as
non-blocking for these events, so unsupported plugin hosts surface an error
without trapping the user's session. The manual registration remains the
fallback.

## Trust boundaries

- Hook event identifiers come from the checked-in `hooks.json` argument and
  are accepted only from a fixed allowlist.
- Claude Code uses `CLAUDE_PLUGIN_ROOT` only to locate the checked-in launcher.
  The launcher derives its root from its own normalized `BASH_SOURCE` path,
  then matches fixed filenames. This avoids native-Windows path-format drift
  in an inherited environment variable.
- User configuration may affect the journal root and message language only.
  It cannot choose a runtime, executable, script, or extra argument.
- The launcher forwards stdin byte-for-byte to the selected existing hook and
  emits no success output of its own.
- Failure messages contain no paths, environment values, stdin, or command
  output.
