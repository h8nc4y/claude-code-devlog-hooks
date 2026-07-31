# Handoff

更新日: 2026-08-01 (JST)

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

- PowerShell/Bashはstrict UTF-8・最大1,048,576 byte・RFC grammarの一つのtop-level
  JSON objectだけを受理する。NUL、invalid UTF-8、上限超過、JSON拡張構文、
  大文字`B/F/N/R/T/U` escapeは拒否する。
- property名はlossless escape復号後のUnicode-scalar完全一致とASCII case-foldで比較し、
  全top-level propertyの完全一致重複・ASCII大小文字衝突は入力全体を判定不能とする。
  一意な未知fieldと非ASCII case pairは無視する。
- depth 128、property名256 Unicode scalar、number 1,024文字、JSON value 4,096の
  work budgetを持つ。Bashは通常stringとnumberを蓄積せず線形に検証する。
- SessionStartは正規名かつ`[A-Za-z0-9_.-]`の1〜64文字string `session_id`だけを
  identityとして使う。各ASCII byteをlowercase hexへ単射符号化し、旧方式と交差しない
  `~sid-` marker namespaceへ保存する。大小文字、Windows予約名、旧raw markerは衝突せず、
  unsafe・非ASCII・過大なIDはidentity未確立とする。
- markerはcanonical ASCII decimal 1〜18 byteだけを受理する。Bashはread前後の
  size確認と最大19 byte read、PowerShellは`FileStream`のlength確認とexact bounded
  readで検証する。Bashは設定rootのUTF-8もoutput/mutation前に検証する。
- 判定不能入力は通常contextへ固定・非反射のJA/EN警告を追加し、marker stateを
  変更しない。nudge/Stopは同じ入力を無音allowする。
- `scripts/test-hooks.ps1`はbyte/grammar/root、exact-case、Unicode名、重複/衝突、型、
  helper直接state、side effect不在、raw/session/secret-like sentinel非反射を含む
  65共有ケースを持つ。POSIX hostではpath escaping 3件を加えた68件になる。
- 2026-08-01のlatest patchでPowerShell 7、Windows PowerShell 5.1、WSL Bash、
  Git Bashが各65/65成功した。filesystem-safe marker key、depth 128 container内scalar、
  timeout kill順、1 MiB/pipe capture capを同じ共有ケースで実測済み。
- 同日、PowerShell 7/5.1 AST、Git Bash/WSL Bashの全shell構文、Claude strict plugin
  validate、plugin contract、launcher 13件、readiness、private-marker self-test/実scan、
  Gitleaks worktree/history、Semgrep local rulesが成功した。
- GitHub evidence: implementation commit `9fe8815` のPR run `30665994905`、
  reviewed head `1dd72f3` のPR run `30666868765`、squash-merge integration commit
  `e728f9d` の
  post-main run `30667455052`は、いずれもWindows / Ubuntu / macOSの3 jobが成功。
  reviewed headとintegration commitは同一tree。
- 現行契約の可変なPR/run情報はmerge済みPRとActionsを都度再確認する。
- 最新の独立再レビューは`CLEAR:YES`（P0〜P3すべて0）。Git / GitHub / CIは外部状態のため、
  可変の「最終main」SHAやopen件数をここへ固定せず、次の着手時に必ず再計測する。

## Success metrics

- plugin package、launcher、PowerShell/Bash hook、private-marker scannerの既存検証が成功する。
- CIはWindows、Ubuntu、macOSの各契約を有限時間で完了する。
- public outputへ保護対象を出さない。scanner/readiness境界は固定・非反射診断で
  fail closedし、hook input異常はSessionStartの固定警告または無音allowでfail openする。

## Key files

- `hooks/devlog-common.ps1` / `.sh`: runtime別の共有protocol parser。
- `hooks/devlog-*.ps1` / `.sh`: PowerShell / Bash event entrypoint。
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
- PR #18のreviewed headとpost-mainはGitHub-hosted Windows / Ubuntu / macOS CI成功済み。
  以後の変更ではmacOS 15 / system Bash 3.2を含むActionsを再確認する。

## Do not re-read

- 旧HANDOFFの実装経緯は再構成しない。永続的な結果は `CHANGELOG.md` とmerge済みPRを参照する。

## Next step

PR #18のintegration、post-main確認、task branch / worktree cleanupは完了。
新しいscopeは未選定。観測された回帰または具体的な利用者taskが生じた時点で、
既存のcross-runtime契約を保った最小変更を選び、上記gateを再実行する。
