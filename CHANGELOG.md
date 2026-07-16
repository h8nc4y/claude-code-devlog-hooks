# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

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
