# Handoff

## Current goal

Complete issue #2: ship dependency-free Bash 3.2+ variants of the three
dev-journal hooks for macOS/Linux with PowerShell-equivalent behavior.

## Success metrics

- Shared SessionStart/UserPromptSubmit/Stop invariants remain fail-open,
  fail-silent, raw UTF-8, single-root, localized, double-gated, and
  enforce-once.
- `stop_hook_active` accepts only a top-level JSON boolean.
- Linux/macOS mtime and arbitrary Unix path JSON escaping are covered.
- Windows PowerShell and Ubuntu Bash CI are green.

## Key files

- `hooks/devlog-common.sh`, `hooks/devlog-*.sh`
- `scripts/test-hooks.ps1`
- `.github/workflows/validate.yml`
- `docs/posix-hooks-design.md`, `docs/posix-hooks-test-plan.md`
- `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`

## Decisions

- Bash, not pure POSIX `sh`; Bash 3.2 is the macOS compatibility floor.
- No jq/Python/Node dependency. A bounded AWK parser reads two top-level
  protocol fields; byte-wise Bash escaping produces JSON strings.
- Shared harness: 30 cross-runtime cases; native POSIX Bash adds 3 special
  path cases.
- PowerShell Stop now type-checks `stop_hook_active` because loose equality
  accepted the string `"true"`.

## Verification state

- `bash -n`: passed under WSL Bash 5.3.9.
- Shared pipe tests: 30/30 passed under PowerShell 7.6.2, Windows PowerShell
  5.1, and WSL Bash 5.3.9.
- WSL-native quote/backslash/tab/newline/`0x01` path probes: 3/3 passed.
- OSS readiness, private-marker scan self-test, staged-file marker scan, and
  `git diff --cached --check`: passed.
- Global staged Gitleaks: passed. Global Semgrep: skipped automatically
  because the change contains no supported Python/JavaScript file.
- Ubuntu CI: pending.
- Actual macOS/Bash 3.2 live Claude Code use: unverified by design.

## Next steps

Run every local gate, inspect the focused diff, update this verification
section, then commit/push/PR/CI/merge and confirm issue #2 closure.
