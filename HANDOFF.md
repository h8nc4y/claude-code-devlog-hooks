# Handoff

## Current goal

Complete issue #3 as Class L: package the three hooks and root skill as a
Claude Code plugin while keeping manual registration as a supported fallback.

## Success metrics

- Strict Claude plugin validation passes on locally verified Claude Code
  2.1.207.
- One handler each registers SessionStart, UserPromptSubmit, and Stop with
  Claude Code's selected Bash shell, a shared launcher, timeout, and status
  message.
- Plugin `userConfig` reaches existing hook variables through official
  `CLAUDE_PLUGIN_OPTION_*` exports without shell interpolation.
- Runtime dispatch executes PowerShell or Bash exactly once; unsupported input
  exits bounded with a non-sensitive diagnostic.
- Existing PowerShell 7, Windows PowerShell 5.1, and Bash behavior remains
  green.

## Key files

- `.claude-plugin/plugin.json`, `hooks/hooks.json`
- `hooks/devlog-plugin-launcher.sh`
- `scripts/test-plugin.ps1`, `scripts/test-plugin-launcher.sh`
- `docs/plugin-*.md`, `README.md`, `CHANGELOG.md`

## Decisions

- Official Claude Code plugin/hook docs and the strict local validator are the
  schema source of truth.
- Hook schema has no documented OS branch; `shell: "bash"` avoids resolving a
  generic PATH `bash` to WSL on Windows, then one launcher selects one core
  runtime. PowerShell-only Windows keeps the manual settings fallback.
- Config priority is non-empty plugin option, legacy environment, hook default.
- Root `SKILL.md` is auto-discovered; no duplicate skill tree.
- Git Bash converts the fixed PowerShell hook path explicitly with
  `cygpath -m --`; missing or failed conversion is fail-closed.
- No live install, marketplace operation, authentication, real Vault access,
  external transmission, or cost.

## Verification state

- Requirements, architecture, detailed design, test plan, manifest, hook
  registration, launcher, tests, and public docs are implemented.
- Red-first package checks failed on missing files, then passed after
  implementation.
- `claude plugin validate . --strict`: passed on Claude Code 2.1.207.
- Plugin contract: passed on PowerShell 7 and Windows PowerShell 5.1.
- Launcher: 13 synthetic/integration cases passed under both WSL Bash 5.3.9
  and Git for Windows Bash; config priority, spaces and Windows shell
  metacharacters, explicit native-path conversion, one-runtime selection, real
  hook bridge, and redacted fail-closed paths covered.
- Existing hook suite: 30/30 passed on pwsh 7.6.2, Windows PowerShell
  5.1.26100.8894, and WSL Bash 5.3.9.
- OSS readiness, Git Bash/WSL Bash syntax, marker scan self-test,
  private-marker scan, Gitleaks directory/staged scans, Semgrep, and
  `git diff --check`: passed. Semgrep first found the mutable checkout tag;
  both jobs now pin the verified v5 SHA. Local `actionlint` is unavailable;
  the workflow remains to be exercised by the PR CI.
- Independent review found one P1 and one P2. The P1 was non-executable Git
  index modes; both shell entrypoints are now `100755` and tested. The P2 was
  Git Bash's failed implicit conversion of a metacharacter-bearing plugin root;
  the launcher now uses explicit `cygpath -m --`, with a real-hook regression
  and missing/failed-converter cases. The P3 deterministic-test gaps for the
  manifest hook path and competing `skills/` directory are also covered.
  The full local review-fix matrix is green; final independent re-review is
  complete at P1/P2/P3 = 0.
- Commit `78dde90` was pushed and PR #5 opened. Its first CI run
  (`30019138135`) exposed two test-fixture portability defects: Ubuntu's
  ambient `/usr/bin/pwsh` invalidated fallback selection, while Git for
  Windows represented synthetic hook arguments in a different MSYS path
  namespace. The fixture now uses an isolated shim-only `PATH`, an explicit
  stdin-capture executable, and host-canonical path comparison. The 13 launcher
  cases pass again on local Git Bash and WSL; independent review and remote CI
  rerun for this test-only fix were completed. Ubuntu passed on run
  `30019850958`; Windows then proved that `/tmp` must be canonicalized into the
  native Windows namespace rather than back into a POSIX mount alias. The
  comparison now uses `cygpath -m -l` for both sides and includes a local native
  path probe. Run `30020175433` exposed the final equivalent-path form:
  `RUNNER~1` versus `runneradmin`. Canonicalization now adds `--long-name`, and
  the local probe starts from an existing hostile-name file converted through
  the DOS short form. This is the third and final same-class fix attempt;
  independent review and one final remote rerun are pending.
- Live Claude plugin registration/install, marketplace publication, and actual
  macOS/Bash 3.2: unverified by scope.

## Next steps

Freeze and independently review the CI fixture fix, then commit and push it to
PR #5. Verify both remote jobs, merge when green, synchronize `main` with
`origin/main`, clean the task branch, rerun the final matrix, and compact this
handoff plus the central development log.
