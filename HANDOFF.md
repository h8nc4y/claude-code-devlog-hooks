# Handoff

更新日: 2026-07-27 (JST)

## Canonical scope

この文書は現在地、直近の検証証拠、次の一手だけを保持する。永続的な変更履歴は
`CHANGELOG.md` とmerge済みPR、scannerの境界契約は `SECURITY.md` と
`docs/` を正本とし、ここへ実装経緯を複製しない。

## Traps before touching anything

- 実Vault、実設定、live plugin install、credential、OAuth、実データ、公開・有料操作を
  ローカルfixtureの代わりに使わない。
- 公開fixtureと診断はsyntheticかつ非反射に保ち、secret、ローカル絶対path、raw logを
  commit・PRへ含めない。
- Windows PowerShell 5.1、PowerShell 7、Bash 3.2の既存互換契約を維持する。
- scanner self-testは同じhostで直列実行する。並列実行はtemp isolationを検知して
  fail closedする。

## Current position

- 最新のruntime変更はPR #12で、GitHub-hosted macOS 15 / system Bash 3.2
  検証を統合済み。
- 同変更のmerge後main run
  [30200474950](https://github.com/h8nc4y/claude-code-devlog-hooks/actions/runs/30200474950)
  はWindows、Ubuntu、macOSの全jobが成功。
- 現在の正本に既知の未修正source defectはない。Git / GitHub / CIは外部状態のため、
  次の着手時に必ず再計測する。

## Success metrics

- plugin package、launcher、PowerShell/Bash hook、private-marker scannerの既存検証が成功する。
- CIはWindows、Ubuntu、macOSの各契約を有限時間で完了する。
- public outputへ保護対象を出さず、境界異常は固定・非反射診断でfail closedする。

## Key files

- `hooks/`: PowerShell / Bash hook実装。
- `scripts/test-hooks.ps1`: cross-runtime hook回帰。
- `scripts/validate-oss-readiness.ps1`: repository / workflow exact contract。
- `scripts/test-scan-private-markers.ps1`: hostile scanner回帰。
- `README.md` / `SECURITY.md` / `CHANGELOG.md`: 公開契約と永続履歴。

## Verification commands

- `claude plugin validate . --strict`
- `pwsh -NoProfile -File ./scripts/test-plugin.ps1`
- `bash --noprofile --norc ./scripts/test-plugin-launcher.sh`
- `pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1`
- `pwsh -NoProfile -File ./scripts/test-hooks.ps1`
- `pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1`
- `pwsh -NoProfile -File ./scripts/scan-private-markers.ps1`
- `git diff --check`

## Known boundaries

- live Claude Code plugin install、実Vault書込み、owner環境のmacOS live sessionは未確認。
- GitHub-hosted macOS 15 / system Bash 3.2のsynthetic executionだけを確認済み。

## Do not re-read

- 旧HANDOFFの実装経緯は再構成しない。永続的な結果は `CHANGELOG.md` とmerge済みPRを参照する。

## Next step

新しいissue、PR feedback、CI failureがなければ、現在の公開安全性とcross-runtime契約を
維持したまま、次の最高価値の小さな改善を別branchで選ぶ。
