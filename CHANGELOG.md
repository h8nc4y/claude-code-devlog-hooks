# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

### Added

- Shared PowerShell protocol parser (`hooks/devlog-common.ps1`) for bounded raw
  stdin, strict UTF-8/RFC JSON validation, exact-case field extraction, and
  lossless duplicate/case-collision rejection without relying on permissive
  `ConvertFrom-Json` or PowerShell member-access semantics.
- A shared bounded-process boundary for hermetic Git execution, binary-safe
  standard streams, finite output/time budgets, and process-tree cleanup on
  Windows and POSIX.
- Full synthetic scanner regression coverage for index/worktree provenance,
  fail-closed Git states, symlink/reparse/TOCTOU boundaries, environment
  isolation, diagnostic redaction, and resource limits.
- A single redacted exit-2 diagnostic for process-boundary bootstrap, helper,
  timeout/output, and Git-isolation failures, without repository, temporary,
  or helper paths in either standard stream.
- Cross-baseline transport and cleanup regressions for a BOM-less Windows
  `-File` child, native Git batch bytes, eager `.Invoke*()` AST classification,
  direct/transitive function calls, scope prefixes, risky aliases,
  Alias/Function/Variable provider mutation (including `Set-Content` and
  `Set-Variable`), literal/dynamic dot and call operators, bare/aliased script
  paths, dynamic ScriptBlock factories, stored ScriptBlock retrieval through
  Variable providers, exact native Git command lookup, command-resolution-
  independent bootstrap root/path provenance, target-helper shadowing,
  function-object lookup, `-as` and static-member risky-class provenance,
  deferred function/type definitions versus eager wrapper calls, definition-
  local bootstrap lookalikes, and exact `SessionState.PSVariable` receiver/scope
  handling across transparent receiver wrappers, with prior-local-binding
  provenance for unqualified `[ref]` and fail-closed raw provenance through
  unsupported command wrappers plus scoped/aliased/parameterized
  `$ExecutionContext` receivers and `Get-Variable` recovery. Raw PSVariable
  tables now retain that risk when returned, assigned, passed as command
  arguments, or sent through multi-element pipelines; only transparent paths
  ending at static `Get`/`GetValue`/`Set`/`SetValue` receivers reach the
  variable-name checks. Casts are excluded and array wrappers must immediately
  index back to their sole element. Unreferenced local scriptblocks remain
  dormant, while scope escape, inline/provider consumption,
  persistent helper shadowing, and index/member pseudo-bindings fail closed;
  optional path initialization now requires trusted `scriptRoot` provenance,
  actual Job membership, failures before Job assignment/resume, and retained-
  handle retry after a synthetic Job-close failure. The suite also covers
  repeated success-path handle disposal, standard linked-worktree gitfiles,
  POSIX case-sensitive `.git` exclusion with ordinary `.GIT` directory/leaf
  scanning, option-free util-linux/BusyBox `setsid`, ready-PID process-group
  verification, handshake-inclusive deadlines with one shared independent
  cleanup allowance across tree/stream/final phases, and tracked-parent-exit
  late-ready group recovery. Released wrappers now atomically publish payload
  completion and exit code so an early-forking external `setsid` parent cannot
  cause premature completion or a false pipe leak. A direct Windows native
  regression also exercises the expired deadline check immediately before
  `ResumeThread`. The suite retains fixed diagnostics for invalid public
  test-seam arguments.
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
- Package-free Bash 3.2+ implementations of all three hooks for
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

- Hardened marker state against root escape through linked children. A linked
  `.devlog-markers` directory or marker leaf now disables enforcement without
  write, read, or retention-prune traversal. Existing ordinary/hard-linked
  marker names are unlinked and exclusively recreated, preserving any other
  hardlink name. Synthetic cross-runtime regressions cover directory links,
  existing and dangling leaf symlinks, and hardlink-safe refresh. Git Bash
  directory-link fixtures use native junctions; file-link fixtures use native
  Windows symlinks with a junction fallback. This avoids MSYS2's
  environment-dependent `winsymlinks:deepcopy` behavior.
- Upgrade all three canonical `actions/checkout` pins from v5.1.0 to v7.0.1
  at the verified official full commit SHA. The executable workflow contract
  also rejects a mutable `@v7` ref, the legacy v5.1.0 pin, and a stale version
  comment while preserving read-only permissions and
  `persist-credentials: false`.
- Stabilized the hosted private-marker self-test without changing production
  process limits: scanner child invocations receive a self-test-only two-second
  stream-drain allowance, and the Windows immediate-child fixture verifies
  bounded removal with a PID/start-time identity and one shared fresh-probe
  budget instead of racing a one-second child artifact. Normal process-exit
  observation races are re-probed, while unknown states fail closed and only a
  verified same instance is cleaned up. Near-limit failures also report fixed
  process-boundary state flags.
- Disabled checkout credential persistence in all three CI jobs and extended
  the exact workflow validator to reject a missing, enabled, misindented, or
  run-literal-spoofed `persist-credentials: false` boundary.
- Bounded parser work independently from raw byte size: container depth 128,
  property names 256 Unicode scalars, number tokens 1,024 characters, and
  values 4,096. Bash ordinary-string and number validation is linear, and the
  pipe harness now drains both output streams while asynchronously writing
  stdin under one finite deadline, kills before closing a timed-out pending
  write, and caps each captured output pipe at 1 MiB.
- Replaced lossy session-id filename mapping with a 1-64 character
  `[A-Za-z0-9_.-]` identity and a reversible lowercase-hex `~sid-` marker key.
  The key is distinct across case-insensitive filesystems, Windows reserved
  names, and the legacy raw/sanitized namespace. Unsafe/non-ASCII/oversized ids
  fail open; legacy-only markers are not consumed during a rolling update.
- Bounded marker reads to canonical 1-18 byte ASCII decimal values and reject
  leading zeroes, newline termination, size changes, and oversized files.
  Bash also validates the configured root as UTF-8 before output or mutation.
- Unified PowerShell 7, Windows PowerShell 5.1, and Bash input parsing around
  strict UTF-8, a 1,048,576-byte cap, RFC JSON grammar, and one top-level
  object. Property names are losslessly compared by Unicode-scalar exact
  identity plus ASCII case folding; exact duplicates and ASCII case
  collisions make the whole input unjudgeable, aliases do not stand in for
  `session_id` or `stop_hook_active`, and unique unknown/non-ASCII case-pair
  fields remain ignored. PowerShell escape-token dispatch is explicitly
  case-sensitive, so uppercase `B/F/N/R/T/U` spellings are rejected in parity
  with Bash. Bash no longer stores raw stdin in command
  substitution, so NUL cannot disappear before validation. Its non-whitespace
  result framing also preserves valid empty-session parser states. The shared
  hook suite now covers 68 cross-runtime cases plus three POSIX-path cases.
- Unified the PowerShell and Bash protocol boundary so only a marker-safe
  1-64 character JSON string `session_id` can establish identity and select
  a marker. Malformed stdin and missing, empty, non-string, unsafe, or oversized ids now create/prune no
  marker state; SessionStart adds a fixed non-reflective JA/EN warning that
  enforcement is off, while nudge/Stop fail open silently.
- Compacted `HANDOFF.md` to the current observable repository state, immediate
  next step, and verification boundaries; durable history and contract details
  stay owned by this changelog, the focused contract documents, and merged
  pull requests.
- Hardened private-marker scanning to inspect regular stage-0 index blobs and
  tracked worktree files independently, reject unsafe or changing repository
  states, and preserve the existing repository URL and local marker contracts.
- Added a finite, PowerShell 5.1-compatible .NET match timeout to every
  production scanner regex. Regex timeouts now fail closed with one fixed
  redacted exit-2 diagnostic, backed by a one-million-character adversarial
  no-match regression, a near-limit safe positive control, an AST mutation
  gate, and a combined Git-cleanup failure regression on Windows (PowerShell 7
  and Windows PowerShell 5.1) and Ubuntu (PowerShell 7).
- Expanded scanner CI to PowerShell 7 and Windows PowerShell 5.1 on Windows and
  PowerShell 7 on Ubuntu 24.04, with exact readiness guards for job ownership,
  workflow triggers, permissions, job IDs, runner, timeout, step shell, and
  command. Active top-level and job-ID indentation is fully consumed, including
  quoted/flow YAML keys.
- Made plugin packaging the preferred future distribution path while retaining
  manual `settings.json` registration as a supported fallback, including
  PowerShell-only Windows hosts.
- Extended Windows and Ubuntu CI with deterministic plugin package and
  launcher checks. The strict Claude CLI validator remains a local release
  gate and passed on Claude Code 2.1.207.
- Isolated launcher runtime fixtures from ambient CI executables and
  canonicalized Git Bash virtual-temp and 8.3 aliases into long native paths
  before exact full-target comparison.
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
