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

- Claude Code with hooks support.
- Choose one hook runtime:
  - PowerShell: `pwsh` (PowerShell 7, any platform) or Windows PowerShell 5.1.
  - macOS/Linux: Bash 3.2+ plus standard Unix `awk`, `cat`, `date`, `mkdir`,
    `rm`, and `stat`.
- No network access and no jq, Python, Node.js, or package installation.

## Install

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

1. Remove the three hook entries (`SessionStart`, `UserPromptSubmit`,
   `Stop`) and the `CLAUDE_DEVLOG_DIR` / `CLAUDE_DEVLOG_LANG` env entries
   from your `settings.json`.
2. Optionally delete `<devlog root>/.devlog-markers/` — the only state the
   hooks write outside your journal entries.
3. Your journal (`daily/`, `topics/`) is yours; nothing else was touched.

## Configuration

| Setting | Where | Default | Meaning |
| --- | --- | --- | --- |
| `CLAUDE_DEVLOG_DIR` | environment variable | `~/claude-devlog` | Devlog root; `daily/`, `topics/`, `.devlog-markers/` all live under it |
| `CLAUDE_DEVLOG_LANG` | environment variable | `ja` | Message language: `ja` or `en`. Anything else falls back to the script default |
| `$DefaultDevlogDir` / `DEFAULT_DEVLOG_DIR` | PowerShell / Bash entrypoints | `~/claude-devlog` | Fallback when the env var is unset |
| `$DefaultLang` / `DEFAULT_LANG` | PowerShell / Bash entrypoints | `ja` | Fallback message language |
| `$ThresholdSec` / `THRESHOLD_SEC` | prompt-nudge entrypoint | `1200` (20 min) | Both nudge gates: minimum session age and minimum journal staleness |
| `$MarkerRetentionDays` / `MARKER_RETENTION_DAYS` | session-start entrypoint | `7` | Marker files older than this are pruned at session start |

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

## Journal Layout Convention

```text
<devlog root>/
├── daily/YYYY-MM-DD.md   # one file per day; hooks judge only its mtime
├── topics/<slug>.md      # distilled evergreen notes (never touched by hooks)
└── .devlog-markers/      # session-start markers (auto-created, auto-pruned)
```

The discipline for writing entries — format, "little and often", the
daily-to-topics distillation rule — is in [SKILL.md](SKILL.md) /
[docs/SKILL.ja.md](docs/SKILL.ja.md). To have Claude follow it as a skill,
copy it under your skills directory (for example
`~/.claude/skills/claude-code-devlog-hooks/SKILL.md`).

## How It Works / Design Notes

The mechanics — enforce-once markers, the nudge double gate, fail-open plus
pipe-testing, raw UTF-8 byte output, PowerShell 5.1 compatibility, Bash JSON
escaping, and GNU/BSD `stat` portability — are documented with rationale in
[docs/hook-engineering.md](docs/hook-engineering.md). The focused Bash
architecture and matrix are in
[docs/posix-hooks-design.md](docs/posix-hooks-design.md) and
[docs/posix-hooks-test-plan.md](docs/posix-hooks-test-plan.md).

## Verified Against

- Hook I/O contract (`hookSpecificOutput.additionalContext`,
  `decision: "block"` + `reason`, `stop_hook_active`, matcher semantics,
  exit codes) checked against the official hooks reference at
  `code.claude.com/docs/en/hooks` on 2026-07-23.
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
- No Claude Code plugin packaging yet — also tracked as an issue.
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
選べます。インストールは上記 Install の各 settings.json 例(3イベント登録+env
1変数)をマージし、`/hooks` で確認後、新しいセッションで SessionStart を確認
してください。アンインストールは登録を外して `.devlog-markers/` を消すだけです。

強制層は Claude Code 専用ですが、記録規律そのもの(こまめに書く・daily→topics
蒸留・secret を書かない)はツール非依存です: [docs/SKILL.ja.md](docs/SKILL.ja.md)
を Codex などの `AGENTS.md` に貼れば、機械的な強制なしで同じ運用ができます。
hook 設計の定石(enforce-once・二重ゲート・フェイルオープンと pipe-test・UTF-8
バイト出力・PS 5.1 互換・Bash の JSON escaping / GNU-BSD `stat` 差異)は
[docs/hook-engineering.md](docs/hook-engineering.md) に英語でまとめています。

## Validation

From the repository root:

```powershell
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-hooks.ps1
pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell powershell   # Windows only
pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell bash
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
bash --noprofile --norc -n ./hooks/*.sh
git diff --check
```

Windows PowerShell 5.1 can also host the scripts
(`powershell -NoProfile -ExecutionPolicy Bypass -File ...`). The GitHub
Actions workflow runs repository validation, the PowerShell 7 / Windows
PowerShell 5.1 / Bash pipe-test targets, Bash syntax, the scan self-test, the
private-marker scan, and a whitespace check on pull requests and pushes to
`main`.

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
