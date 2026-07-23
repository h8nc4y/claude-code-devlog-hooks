# Claude Code Plugin Requirements

## Objective

Package the existing three-hook dev-journal workflow and the root `SKILL.md`
as one Claude Code plugin without changing the hooks' journaling semantics.
This work closes issue #3 at the repository-package level. Marketplace
publication and a live installation are separate release operations.

## Source of truth

The implementation targets Claude Code `2.1.207`, the locally verified
version on 2026-07-23. The schema and runtime contracts come from:

- <https://code.claude.com/docs/en/plugins-reference>
- <https://code.claude.com/docs/en/hooks>
- `claude plugin validate --help`

If these sources change, the current Claude Code documentation and strict
validator take precedence over this document.

## Functional requirements

1. `.claude-plugin/plugin.json` identifies the plugin and exposes optional
   `devlog_dir` and `devlog_lang` `userConfig` values.
2. `hooks/hooks.json` registers exactly one command handler for each existing
   event: `SessionStart`, `UserPromptSubmit`, and `Stop`.
3. Every handler uses Claude Code's `shell: "bash"` selection with the same
   quoted launcher path and retains a 15-second timeout plus a Japanese
   `statusMessage`.
4. The root `SKILL.md` remains the plugin's single automatically discovered
   skill. It must not be duplicated into a second skill tree.
5. Plugin configuration is bridged through Claude Code's exported
   `CLAUDE_PLUGIN_OPTION_DEVLOG_DIR` and
   `CLAUDE_PLUGIN_OPTION_DEVLOG_LANG` environment variables. A non-empty
   plugin option takes priority over the corresponding legacy
   `CLAUDE_DEVLOG_*` variable; an empty option preserves the legacy variable;
   the existing hook default remains the final fallback.
6. Paths containing spaces or valid Windows shell metacharacters must reach the
   selected hook as one value. Before invoking PowerShell from Git Bash, the
   launcher must explicitly convert the fixed hook path with `cygpath -m --`.
7. The launcher selects one runtime only:
   - native Windows under Git Bash: `pwsh`, then Windows PowerShell, then the
     bundled Bash hook as the last supported runtime;
   - macOS, Linux, and WSL: the bundled Bash hook.
8. Unknown events, unknown platforms, a missing runtime, or an unavailable or
   failed Windows path converter must terminate within the hook timeout with a
   fixed, non-sensitive diagnostic. The launcher must not guess, loop, or run
   both implementations.
9. The existing manual `settings.json` setup remains documented and supported
   as the fallback, including Windows installations that have PowerShell but
   no Git Bash launcher.

## Safety and privacy requirements

- Do not interpolate `${user_config.*}` into a shell command. Claude Code
  `2.1.207` rejects that pattern because it can create command injection.
- Read plugin options only from the official exported environment variables.
  Shell-form command text must contain only the fixed, quoted plugin-root
  launcher path and fixed event identifier.
- Do not use `eval`, dynamic script paths, user-selected executables, or
  command construction from configuration values.
- Do not print configuration values, stdin payloads, environment dumps, raw
  logs, secrets, or real journal contents from the launcher.
- Keep all fixtures synthetic and all writes under temporary test roots.
- Make no network request and require no jq, Python, Node.js, package
  installation, authentication, or paid service.

## Compatibility requirements

- PowerShell hook behavior remains covered on PowerShell 7 and Windows
  PowerShell 5.1.
- Bash hook behavior remains covered on Bash, including Ubuntu CI.
- The plugin launcher requires Bash 3.2+. Git for Windows is the supported
  launcher provider on native Windows; the manual PowerShell registration is
  the no-Git-Bash fallback.
- Plugin packaging must pass `claude plugin validate . --strict` on the
  locally verified CLI version.

## Non-goals

- Installing or enabling the plugin in the user's live Claude Code config.
- Adding or publishing a marketplace entry.
- Submitting to an Anthropic marketplace.
- Reading or writing a real Obsidian Vault or dev-journal.
- Replacing the existing manual installation path.
- Changing nudge timing, marker behavior, Stop semantics, or hook messages.
