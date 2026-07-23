# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

### Added

- Claude Code plugin package:
  - `.claude-plugin/plugin.json` with optional `devlog_dir` and `devlog_lang`
    `userConfig`;
  - `hooks/hooks.json` with one Claude-selected Bash-shell registration each for
    `SessionStart`, `UserPromptSubmit`, and `Stop`;
  - a single bounded runtime launcher that bridges official
    `CLAUDE_PLUGIN_OPTION_*` exports to the existing hook configuration and
    selects exactly one PowerShell or Bash implementation;
  - automatic root `SKILL.md` discovery without a duplicate skill tree.
- Plugin package and launcher test suites covering registration shape,
  timeout/status messages, config priority, space- and metacharacter-containing
  paths, explicit Git Bash-to-Windows path conversion, PowerShell 7 / Windows
  PowerShell / Bash selection, one-runtime-only execution, executable Git
  index modes, root-skill/hook wiring, and non-sensitive failure output.
- Class L plugin requirements, architecture, detailed design, and test plan.
- Dependency-free Bash 3.2+ implementations of all three hooks for
  macOS/Linux:
  - `hooks/devlog-session-start.sh`
  - `hooks/devlog-prompt-nudge.sh`
  - `hooks/devlog-stop.sh`
- Shared Bash helper (`hooks/devlog-common.sh`) with a bounded top-level JSON
  parser, strict boolean `stop_hook_active` handling, JSON string escaping for
  arbitrary Unix paths, epoch validation, marker retention, and GNU/BSD
  `stat` compatibility. No jq/Python/Node runtime dependency.
- Bash settings example (`examples/hooks-settings.bash.json`), focused design
  and test-plan documents, and an Ubuntu CI job with syntax plus pipe tests.

### Changed

- Made plugin packaging the preferred future distribution path while retaining
  manual `settings.json` registration as a supported fallback, including
  PowerShell-only Windows hosts.
- Extended Windows and Ubuntu CI with deterministic plugin package and
  launcher checks. The strict Claude CLI validator remains a local release
  gate and passed on Claude Code 2.1.207.
- Isolated launcher runtime fixtures from ambient CI executables and
  canonicalized Git Bash path representations before exact target comparison.
- Pinned both `actions/checkout` uses to the verified v5 commit after Semgrep
  flagged the mutable major-version tag.
- Expanded `scripts/test-hooks.ps1` from 27 to 30 cross-runtime cases:
  defensive string/nested `stop_hook_active` inputs must not activate the
  top-level boolean loop guard, and malformed nested JSON must fail open.
  Native POSIX Bash runs add three synthetic quote/backslash/control-character
  path JSON cases (33 total).
- Tightened the PowerShell Stop guard to require an actual JSON boolean;
  PowerShell loose equality previously accepted the string `"true"`.
- Updated installation, validation, contribution, and engineering guidance
  for the PowerShell/Bash dual runtime and current hook-settings reload
  behavior.

## 0.1.0 - 2026-07-16

### Added

- Three-layer dev-journal hooks for Claude Code (PowerShell):
  - `hooks/devlog-session-start.ps1` — injects the journaling routine via
    `hookSpecificOutput.additionalContext`, records the session start time
    as a marker file, prunes markers older than 7 days.
  - `hooks/devlog-prompt-nudge.ps1` — double-gated non-blocking nudge
    (session age ≥ threshold AND journal staleness ≥ threshold, default
    20 minutes each); silent in every other case.
  - `hooks/devlog-stop.ps1` — enforce-once turn-end block
    (`decision: "block"`) until today's journal mtime reaches the session
    start marker; `stop_hook_active` loop prevention.
- Single-variable configuration: everything derives from the devlog root
  (`CLAUDE_DEVLOG_DIR` environment variable, falling back to a script-top
  default), with `daily/`, `topics/`, and `.devlog-markers/` as the
  conventional layout.
- Japanese (default) and English message sets, switchable via
  `CLAUDE_DEVLOG_LANG` or a script-top default.
- Fail-open AND fail-silent design throughout (any error or unjudgeable
  state allows with nothing on stderr; cmdlet errors promoted to
  terminating via `$ErrorActionPreference = 'Stop'`), raw UTF-8 byte
  output (mojibake prevention), UTF-8 BOM on hook sources for Windows
  PowerShell 5.1 compatibility.
- Degraded-enforcement disclosure: when the session marker cannot be
  written (for example an unwritable devlog root), SessionStart still
  injects the routine plus a visible ⚠ notice that Stop enforcement and
  nudges are off for the session.
- Pipe-test suite (`scripts/test-hooks.ps1`, 27 cases) asserting exit
  codes, raw output bytes (strict UTF-8, JSON shape, field values,
  language switching), and side effects (marker creation, pruning,
  sanitized filenames), including fail-silent regression cases for
  unwritable roots and unreadable markers; runs under both PowerShell 7
  and Windows PowerShell 5.1 in CI.
- Journaling discipline skill (`SKILL.md`, English canonical) and Japanese
  full version (`docs/SKILL.ja.md`).
- Hook engineering notes (`docs/hook-engineering.md`): enforce-once
  markers, nudge double gate, fail-open + pipe-testing, UTF-8 byte output,
  PowerShell cast precedence, no-StrictMode rationale, registration and
  matcher facts checked against the official hooks reference, known
  limitations (midnight rollover, resume/compact re-arm, config timing).
- Examples: `settings.json` registration snippet
  (`examples/hooks-settings.json`) and journal entry templates
  (`examples/journal-entry-template.md`).
- Private-marker scan for common secret prefixes, private-looking absolute
  paths, and non-allowlisted GitHub repository URLs, with a self-test and
  local marker support through `.private-markers.local` or the
  `CLAUDE_CODE_DEVLOG_HOOKS_PRIVATE_MARKERS` environment variable.
- OSS readiness validation script (required files, README sections, skill
  frontmatter, hook parameterization / BOM / fail-open checks, example
  settings JSON validity).
- GitHub Actions workflow (`windows-latest`) running validation, both
  pipe-test shells, the scan self-test, the private-marker scan, and a
  whitespace check.
- Issue and pull request templates with sanitized-report guidance,
  contributor / security / code-of-conduct documentation, MIT license.
