# Handoff

更新日: 2026-07-28 (JST)

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

- SessionStartは空でないJSON stringの`session_id`を確立できた場合だけmarkerを
  書込み・pruneする。不正stdin、欠落、空文字、非文字列ではmarker stateを変更せず、
  通常contextへ固定・非反射のJA/EN警告を追加する。nudge/Stopは同じ入力を無音allowする。
- `scripts/test-hooks.ps1`は上記4境界、side effect不在、raw/session/secret-like sentinel
  非反射を含む38共有ケースを持つ。POSIX hostではpath escaping 3件を加えた41件になる。
- 直前のruntime境界PR #14（merge
  `c320fd45c06ab6394715d8608929567b3d296e82`）とhandoff同期PR #15の3 OS CIは成功済み。
  現行契約の可変なPR/run情報はmerge済みPRとActionsを都度再確認する。
- 現在の正本に既知の未修正source defectはない。Git / GitHub / CIは外部状態のため、
  可変の「最終main」SHAやopen件数をここへ固定せず、次の着手時に必ず再計測する。

## Success metrics

- plugin package、launcher、PowerShell/Bash hook、private-marker scannerの既存検証が成功する。
- CIはWindows、Ubuntu、macOSの各契約を有限時間で完了する。
- public outputへ保護対象を出さず、境界異常は固定・非反射診断でfail closedする。

## Key files

- `hooks/`: PowerShell / Bash hook実装。
- `scripts/test-hooks.ps1`: cross-runtime hook回帰。
- `docs/session-id-type-contract.md`: session identityの型境界とfail-open契約。
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
