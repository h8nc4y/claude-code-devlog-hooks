# claude-code-devlog-hooks

[![Validate](https://github.com/h8nc4y/claude-code-devlog-hooks/actions/workflows/validate.yml/badge.svg)](https://github.com/h8nc4y/claude-code-devlog-hooks/actions/workflows/validate.yml)

Three-layer Claude Code hooks that build a daily dev-journal habit:
**SessionStart** injects the journaling routine into context, **UserPromptSubmit**
nudges (without blocking) when today's log goes stale, and **Stop** blocks the
end of a turn once — and only until today's journal is updated. PowerShell on
Windows or Bash on macOS/Linux, fail-open by design, with messages in Japanese
(default) or English.

The problem these hooks attack: agents (and humans) always plan to "write up
the session at the end," and then nothing gets written. The three layers turn
journaling into something the session itself keeps asking for — little and
often — with exactly one hard backstop per session.

| Layer | Hook event | Behavior |
| --- | --- | --- |
| Routine | `SessionStart` | Injects the journaling discipline; records session start time as a marker (auto-pruned after 7 days) |
| Reminder | `UserPromptSubmit` | Double-gated: only when the session is ≥ 20 min old AND today's journal is ≥ 20 min stale, injects a gentle nudge. Otherwise silent. Never blocks |
| Backstop | `Stop` | If today's journal was not touched since session start, blocks turn-end once with instructions (enforce-once via marker + mtime comparison; `stop_hook_active` prevents loops) |

## Scope And Positioning (Honest Version)

- **The enforcement layer is Claude Code specific.** Hooks are a Claude Code
  mechanism; other agent CLIs (for example Codex) do not have one.
- **The journaling discipline is tool-agnostic.** [SKILL.md](SKILL.md)
  (English canonical; Japanese full version at
  [docs/SKILL.ja.md](docs/SKILL.ja.md)) describes the routine itself — for
  agents without hooks, paste it into standing instructions such as
  `AGENTS.md` and you keep the habit structure without the mechanical
  backstop.
- **The hooks never write journal content.** They inject instructions, nudge,
  and block once; the agent (or you) writes the entries.

## Requirements

- Plugin package:
  - Claude Code 2.1.207+ (the version used to validate the current
    `userConfig` environment-variable contract).
  - Bash 3.2+ for the single plugin launcher. On native Windows, install Git
    for Windows so `bash` is available; PowerShell-only Windows can use the
    manual fallback below.
- Manual settings fallback: choose one hook runtime:
  - PowerShell: `pwsh` (PowerShell 7, any platform) or Windows PowerShell 5.1.
  - macOS/Linux: Bash 3.2+ plus standard Unix `awk`, `cat`, `date`, `mkdir`,
    `rm`, and `stat`.
- No network access and no jq, Python, Node.js, or package installation at
  hook runtime.

## Install

### Plugin package

This repository is a strict-validator-clean Claude Code plugin package. Once a
trusted marketplace publishes it, installation and configuration are one
command:

```text
claude plugin install claude-code-devlog-hooks@<marketplace> --config devlog_dir="/path/to/devlog" --config devlog_lang=ja
```

The marketplace publication itself is **not part of this repository change
and is not currently verified**. Maintainers can validate a checkout without
installing or enabling it:

```text
claude plugin validate . --strict
```

The plugin supplies all three hooks from `hooks/hooks.json` and automatically
discovers the root [SKILL.md](SKILL.md). Each event enters through Claude
Code's selected Bash shell and one quoted launcher path. The launcher reads
Claude Code's official
`CLAUDE_PLUGIN_OPTION_DEVLOG_DIR` and
`CLAUDE_PLUGIN_OPTION_DEVLOG_LANG` exports, then selects exactly one existing
PowerShell or Bash implementation. It never interpolates `${user_config.*}`
into shell command text.

On native Windows, `shell: "bash"` deliberately uses Claude Code's Git Bash
selection instead of resolving a generic `bash.exe` from `PATH` (which may be
WSL). The launcher explicitly converts its fixed PowerShell hook path with
Git Bash's `cygpath`, preserving spaces and valid Windows shell metacharacters
as data. If Git Bash or that converter is unavailable, keep using the manual
PowerShell registration below; it remains a first-class supported path.

### Manual settings fallback

Read the three event entrypoints for your chosen runtime in [hooks/](hooks)
(and `devlog-common.sh` for Bash) first — you are about to run them on every
session event.

1. Clone the repository to a **space-free path** (spaces would complicate
   the `command` strings below):

   ```bash
   git clone https://github.com/h8nc4y/claude-code-devlog-hooks.git
   ```

2. Pick a devlog root — the one variable everything derives from. An
   Obsidian vault subfolder works well (wikilinks resolve natively), any
   Markdown folder works. The hooks will create it on first run if needed.

3. Merge one runtime example into your Claude Code `settings.json` (user scope:
   `~/.claude/settings.json`, or `$CLAUDE_CONFIG_DIR/settings.json` if you
   set that variable). Ready-to-adapt copies:

   - PowerShell:
     [examples/hooks-settings.json](examples/hooks-settings.json)
   - macOS/Linux Bash:
     [examples/hooks-settings.bash.json](examples/hooks-settings.bash.json)

   Replace the two placeholder paths and use forward slashes. The complete
   PowerShell form is shown here:

   ```json
   {
     "env": {
       "CLAUDE_DEVLOG_DIR": "C:/path/to/your/devlog"
     },
     "hooks": {
       "SessionStart": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File C:/path/to/claude-code-devlog-hooks/hooks/devlog-session-start.ps1",
               "timeout": 15,
               "statusMessage": "開発ログ運用を確認中…"
             }
           ]
         }
       ],
       "UserPromptSubmit": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File C:/path/to/claude-code-devlog-hooks/hooks/devlog-prompt-nudge.ps1",
               "timeout": 15,
               "statusMessage": "開発ログの追記時機を確認中…"
             }
           ]
         }
       ],
       "Stop": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File C:/path/to/claude-code-devlog-hooks/hooks/devlog-stop.ps1",
               "timeout": 15,
               "statusMessage": "開発ログ記入を確認中…"
             }
           ]
         }
       ]
     }
   }
   ```

   For macOS/Linux, the event structure is identical; use these three Bash
   commands in the corresponding entries:

   | Event | `command` |
   | --- | --- |
   | `SessionStart` | `bash --noprofile --norc /path/to/claude-code-devlog-hooks/hooks/devlog-session-start.sh` |
   | `UserPromptSubmit` | `bash --noprofile --norc /path/to/claude-code-devlog-hooks/hooks/devlog-prompt-nudge.sh` |
   | `Stop` | `bash --noprofile --norc /path/to/claude-code-devlog-hooks/hooks/devlog-stop.sh` |

   Notes:

   - The `env` block applies to every session and to subprocesses Claude
     Code spawns — including these hooks (per the official settings
     reference). Alternatives: set `CLAUDE_DEVLOG_DIR` as an OS user
      environment variable, or edit `$DefaultDevlogDir` (PowerShell) /
      `DEFAULT_DEVLOG_DIR` (Bash) at the top of each entrypoint.
   - `Stop` and `UserPromptSubmit` take no matcher (they always fire; the
     scripts do their own filtering). Registering `SessionStart` without a
     matcher fires it on startup, resume, clear, and compact — intended here.
   - On Windows without PowerShell 7, replace `pwsh` with `powershell`.
   - Merge, do not overwrite: keep your existing settings and validate the
     JSON afterwards.

4. Review `/hooks`, then start a **new** Claude Code session for a deterministic
   SessionStart check. Current Claude Code watches and reloads hook settings,
   but an event that already happened is not replayed.

5. Smoke-test outside Claude Code (uses a throwaway root):

   ```powershell
   $env:CLAUDE_DEVLOG_DIR = Join-Path ([IO.Path]::GetTempPath()) 'devlog-smoke'
   '{"session_id":"smoke"}' | pwsh -NoProfile -File ./hooks/devlog-session-start.ps1
   '{"session_id":"smoke"}' | pwsh -NoProfile -File ./hooks/devlog-stop.ps1   # expect a block JSON
   Remove-Item -Recurse -Force $env:CLAUDE_DEVLOG_DIR
   Remove-Item Env:CLAUDE_DEVLOG_DIR
   ```

   macOS/Linux Bash:

   ```bash
   smoke_root="$(mktemp -d)"
   export CLAUDE_DEVLOG_DIR="$smoke_root"
   printf '%s' '{"session_id":"smoke"}' | bash --noprofile --norc ./hooks/devlog-session-start.sh
   printf '%s' '{"session_id":"smoke"}' | bash --noprofile --norc ./hooks/devlog-stop.sh   # expect block JSON
   rm -rf -- "$smoke_root"
   unset CLAUDE_DEVLOG_DIR
   ```

## Uninstall

- Plugin installation: remove the qualified plugin from the same scope where
  it was installed:

  ```text
  claude plugin uninstall claude-code-devlog-hooks@<marketplace>
  ```

- Manual fallback: remove the three hook entries (`SessionStart`,
  `UserPromptSubmit`, `Stop`) and the `CLAUDE_DEVLOG_DIR` /
  `CLAUDE_DEVLOG_LANG` env entries from your `settings.json`.
- Either route: optionally delete
  `<devlog root>/.devlog-markers/` — the only state the hooks write outside
  journal entries. The journal (`daily/`, `topics/`) remains yours.

## Configuration

| Setting | Where | Default | Meaning |
| --- | --- | --- | --- |
| `devlog_dir` | plugin `userConfig` | unset | Devlog root for plugin installs; exported by Claude Code as `CLAUDE_PLUGIN_OPTION_DEVLOG_DIR` |
| `devlog_lang` | plugin `userConfig` | unset | Plugin message language (`ja` or `en`); exported as `CLAUDE_PLUGIN_OPTION_DEVLOG_LANG` |
| `CLAUDE_DEVLOG_DIR` | legacy/manual environment variable | `~/claude-devlog` | Devlog root; `daily/`, `topics/`, `.devlog-markers/` all live under it |
| `CLAUDE_DEVLOG_LANG` | legacy/manual environment variable | `ja` | Message language: `ja` or `en`. Anything else falls back to the script default |
| `$DefaultDevlogDir` / `DEFAULT_DEVLOG_DIR` | PowerShell / Bash entrypoints | `~/claude-devlog` | Fallback when the env var is unset |
| `$DefaultLang` / `DEFAULT_LANG` | PowerShell / Bash entrypoints | `ja` | Fallback message language |
| `$ThresholdSec` / `THRESHOLD_SEC` | prompt-nudge entrypoint | `1200` (20 min) | Both nudge gates: minimum session age and minimum journal staleness |
| `$MarkerRetentionDays` / `MARKER_RETENTION_DAYS` | session-start entrypoint | `7` | Marker files older than this are pruned at session start |

For each configurable value, the priority is: non-empty plugin option,
existing legacy environment variable, then the existing hook default. This
lets plugin configuration override an old manual environment intentionally;
leaving the plugin option blank preserves the old environment.

### Switching Message Language

Default messages are Japanese. For English, add to the same `env` block:

```json
"CLAUDE_DEVLOG_LANG": "en"
```

or set it as an OS environment variable, or change `$DefaultLang = 'en'`
(PowerShell) / `DEFAULT_LANG=en` (Bash) at the top of each entrypoint. The
`statusMessage` strings in `settings.json` are yours to localize freely —
English suggestions: "Checking dev journal routine", "Checking journal
staleness", "Checking journal entry".

For a marketplace plugin install, set `--config devlog_lang=en` instead.

## Journal Layout Convention

```text
<devlog root>/
├── daily/YYYY-MM-DD.md   # one file per day; hooks judge only its mtime
├── topics/<slug>.md      # distilled evergreen notes (never touched by hooks)
└── .devlog-markers/      # session-start markers (auto-created, auto-pruned)
```

The discipline for writing entries — format, "little and often", the
daily-to-topics distillation rule — is in [SKILL.md](SKILL.md) /
[docs/SKILL.ja.md](docs/SKILL.ja.md). The plugin auto-discovers the root
skill. For the manual fallback, copy it under your skills directory (for example
`~/.claude/skills/claude-code-devlog-hooks/SKILL.md`).

## How It Works / Design Notes

The mechanics — enforce-once markers, the nudge double gate, fail-open plus
pipe-testing, raw UTF-8 byte output, PowerShell 5.1 compatibility, Bash JSON
escaping, and GNU/BSD `stat` portability — are documented with rationale in
[docs/hook-engineering.md](docs/hook-engineering.md). The focused Bash
architecture and matrix are in
[docs/posix-hooks-design.md](docs/posix-hooks-design.md) and
[docs/posix-hooks-test-plan.md](docs/posix-hooks-test-plan.md). Plugin
requirements, architecture, detailed design, and verification are in
[docs/plugin-requirements.md](docs/plugin-requirements.md),
[docs/plugin-architecture.md](docs/plugin-architecture.md),
[docs/plugin-detailed-design.md](docs/plugin-detailed-design.md), and
[docs/plugin-test-plan.md](docs/plugin-test-plan.md).

## Verified Against

- Hook I/O contract (`hookSpecificOutput.additionalContext`,
  `decision: "block"` + `reason`, `stop_hook_active`, matcher semantics,
  exit codes) checked against the official hooks reference at
  `code.claude.com/docs/en/hooks` on 2026-07-23.
- Plugin manifest, root-skill discovery, shell-selected hook registration, and
  `userConfig` environment export checked against the official plugin and
  hooks references on 2026-07-23. `claude plugin validate . --strict` passed
  with Claude Code 2.1.207.
- Plugin package tests cover the three registrations, timeout/status text,
  configuration priority, paths containing spaces and Windows shell
  metacharacters, explicit native-path conversion, one-runtime-only dispatch,
  a real hook bridge, and non-sensitive unsupported-host/missing-file
  diagnostics. The 13-case launcher suite passed under both WSL Bash 5.3.9 and
  Git for Windows Bash; live Claude Code registration remains unverified.
- Behavior is verified by the shared pipe-test suite
  (`scripts/test-hooks.ps1`): 30 cross-runtime cases, plus three Bash-only
  POSIX path-escaping cases on `ubuntu-latest`. Windows CI covers PowerShell
  7 and Windows PowerShell 5.1; Ubuntu CI covers Bash and `bash -n`.
- The pre-parameterization ancestors of these hooks (same logic, hardcoded
  paths) have run in daily Claude Code use on Windows since 2026-06-15,
  most recently on Claude Code 2.1.207. The parameterized scripts in this
  repository are verified by the pipe-test suite; their live in-session
  registration was not separately re-exercised at release time.
- The Bash hooks are pipe-tested on Linux. Live Claude Code registration on
  macOS/Linux and actual macOS/Bash 3.2 execution remain unverified.

## Known Limitations

- **Midnight rollover**: "today's journal" is recomputed at judgment time;
  a session crossing midnight is judged against the new day's file and may
  be blocked once more after midnight.
- **Resume/clear/compact re-arm**: SessionStart fires on resume, `/clear`,
  and compaction, refreshing the marker — so those events re-arm the
  once-per-session block. Read as "a context window's worth of work
  deserves an entry".
- **Config timing**: settings reload during a running session, but events that
  already happened are not replayed. Review `/hooks`; use a new session for a
  deterministic SessionStart check.
- **Plugin distribution**: this checkout is a validated plugin package, but no
  marketplace publication, live installation, or marketplace identifier was
  exercised by this change.
- **Windows plugin launcher**: the plugin route enters through Bash and
  therefore requires Git Bash on native Windows. PowerShell-only Windows
  remains supported through the manual settings fallback.
- **The Stop layer relies on the marker**: without it (mid-session install,
  pruned marker) the hooks fail open — no block, no nudge — rather than
  guess.
- **Unwritable devlog root**: SessionStart still injects the routine but
  appends a visible ⚠ notice that enforcement is off for the session (the
  marker could not be written); nothing is leaked to stderr.

Details and rationale: [docs/hook-engineering.md](docs/hook-engineering.md).

## Non-Goals

- No pure POSIX `sh` port. Bash 3.2+ is the portability floor so JSON path
  escaping stays dependency-free.
- No marketplace publication, submission, authentication, or live plugin
  installation.
- No automatic journal writing. The hooks enforce the habit; the content is
  the agent's (or your) job.

## 日本語概要 (Japanese Overview)

Claude Code で「開発日誌を毎セッション・こまめに書く」習慣を作る 3層 hook です。

- **SessionStart** … 日誌運用の指示をコンテキストへ注入し、セッション開始時刻を
  マーカー保存(7日で自動掃除)。
- **UserPromptSubmit** … 二重ゲート(セッション経過 ≥ 20分 かつ 当日ログ未更新
  ≥ 20分)が成立したときだけ、ブロックせずそっと追記を促す。普段は無音。
- **Stop** … 当日ログ未更新のままターンを終えようとすると一度だけブロック
  (マーカーと mtime の比較による enforce-once。`stop_hook_active` で無限ループ
  防止)。記入済みなら邪魔しない。

全 hook がフェイルオープン(エラー時は必ず許可・無音)で、出力は UTF-8 バイト
直書き(文字化け防止)。メッセージは日本語が既定で、`CLAUDE_DEVLOG_LANG=en` で
英語に切替できます。設定は devlog ルート1変数(`CLAUDE_DEVLOG_DIR`)だけ。
Windows は PowerShell、macOS/Linux は追加パッケージ不要の Bash 3.2+ 版を
選べます。plugin package は3 hookとroot `SKILL.md`を同梱し、`userConfig`を
公式の`CLAUDE_PLUGIN_OPTION_*`環境変数で安全に渡します。marketplace公開とlive
installは未確認です。手動導入はfallbackとして維持しており、各settings.json例を
マージし、`/hooks`で確認後、新しいsessionでSessionStartを確認できます。

強制層は Claude Code 専用ですが、記録規律そのもの(こまめに書く・daily→topics
蒸留・secret を書かない)はツール非依存です: [docs/SKILL.ja.md](docs/SKILL.ja.md)
を Codex などの `AGENTS.md` に貼れば、機械的な強制なしで同じ運用ができます。
hook 設計の定石(enforce-once・二重ゲート・フェイルオープンと pipe-test・UTF-8
バイト出力・PS 5.1 互換・Bash の JSON escaping / GNU-BSD `stat` 差異)は
[docs/hook-engineering.md](docs/hook-engineering.md) に英語でまとめています。

## Validation

From the repository root:

```powershell
claude plugin validate . --strict
pwsh -NoProfile -File ./scripts/test-plugin.ps1
bash --noprofile --norc ./scripts/test-plugin-launcher.sh
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-hooks.ps1
pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell powershell   # Windows only
pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell bash
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
bash --noprofile --norc -n ./hooks/*.sh ./scripts/*.sh
git diff --check
```

Windows PowerShell 5.1 can also host the scripts
(`powershell -NoProfile -ExecutionPolicy Bypass -File ...`). The GitHub
Actions workflow runs repository validation, the PowerShell 7 / Windows
PowerShell 5.1 / Bash pipe-test targets, Bash syntax, the scan self-test, the
private-marker scan, plugin package/launcher tests, and a whitespace check on
pull requests and pushes to `main`. The strict Claude CLI validator is a local
release check because CI does not install or authenticate Claude Code.

The pipe-test suite verifies behavior, not just exit codes: output bytes
are captured raw (strict UTF-8 decode, JSON shape, field values) and side
effects (marker creation, pruning) are asserted — because fail-open hooks
otherwise hide their own bugs.

## Contributing

Contributions are welcome when they make the hooks safer, clearer, or
easier to verify. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. Keep all
examples synthetic: no tokens, credentials, private repository names,
internal absolute paths, or customer data.

For local-only private markers, create an untracked `.private-markers.local`
file with one literal marker per line, or set
`CLAUDE_CODE_DEVLOG_HOOKS_PRIVATE_MARKERS` with newline-separated markers.
The scanner reads these values but never prints matched content.

## Security

The hooks run locally on every session event, make no network calls, and
read/write only under the configured devlog root. Threat model, scanner
coverage, and private reporting instructions: [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
