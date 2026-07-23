## Summary / 概要

- <summary>

## Changes / 変更内容

- <change>

## Tests / 検証

- [ ] `pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1`
- [ ] `pwsh -NoProfile -File ./scripts/test-hooks.ps1`
- [ ] `pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell powershell` (on Windows)
- [ ] `pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell bash`
- [ ] `bash --noprofile --norc -n ./hooks/*.sh`
- [ ] `pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1`
- [ ] `pwsh -NoProfile -File ./scripts/scan-private-markers.ps1`
- [ ] `git diff --check`
- [ ] `SKILL.md` and `docs/SKILL.ja.md` still say the same thing (if either changed)

## Review notes / レビュー観点

- <review note>

## Risks / 残リスク

- <risk or none>

## Unknowns / 未確認事項

- <unknown or none>

## Cost impact / 費用影響

- No paid service usage expected.
