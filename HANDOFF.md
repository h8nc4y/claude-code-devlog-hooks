# Handoff

更新日: 2026-08-02 (JST)

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
- 2026-08-02に3 OS jobの全checkoutへ`persist-credentials: false`を追加した。
  exact workflow validatorは`with`を所有checkoutへ結び付け、設定欠落、`true`、
  misindent、run literal偽装を拒否する。これはcheckout credentialのlocal Git config
  保存だけを無効化し、repository権限は`contents: read`のまま変更していない。
- 同変更のlocal検証ではPowerShell 7/5.1 readiness、Claude strict plugin validate、
  plugin contract、launcher 13件、PowerShell 7/5.1 hook各65件、private-marker
  self-testとtracked scanが成功した。PR #20 run `30732847840`とsquash-merge
  integration commit `d76b4e1`のpost-main run `30733118960`は、いずれも
  Windows / Ubuntu / macOSの3 jobが成功した。reviewed head `995f132`と
  integration commitは同一treeで、task branchもlocal / remoteからcleanup済み。
- 2026-08-02の新しいClass M work unitでは、3つのcheckoutを公式v7.0.1の
  verified full commit SHAへ更新する。baseline main、origin、live mainは
  `c6e7af25a07ede43f1af92b55bee54aa7c2e1976`で一致し、open PR / issueは0、
  exact-main run `30733818380`はWindows / Ubuntu / macOSの3 jobが成功した。
- 同baselineではstrict plugin validation、PowerShell 7/5.1 readinessとplugin、
  launcher 13件、PowerShell 7/5.1/WSL Bash/Git Bash hook各65件、scanner
  self-test両host、tracked scanが成功した。validator-first TDDでは旧workflowを
  両PowerShellが計7 diagnosticsで拒否し、3 pin更新後は両方GREENへ戻った。
- Final candidateでもstrict plugin validation、PowerShell 7/5.1 readinessとplugin、
  launcher 13件、WSL / Git Bash syntax、PowerShell 7/5.1/WSL Bash/Git Bash hook各65件、
  scanner self-test両host、tracked scanが成功した。Gitleaksはleak 0、Semgrepは
  82 rules / 5 filesでfinding 0、encoding / whitespace checksも成功した。
- 独立reviewで、SHA直後の`#`がcommentとして分離されずaction refへ混入する
  非canonical行の誤受理をP2として検出した。no-separator mutationで両PowerShellの
  REDを再現し、comment前に1文字以上の空白を要求して両方GREENへ修復した。
  修正後の独立再review 2系統はP0〜P3すべて0。feature commit `cd0ec87`をpushし、
  PR #22を作成した。
- PR #22 run `30743820276`のattempt 1ではmacOSが成功した一方、変更していない
  private-marker self-testがWindowsの1秒artifact競争とUbuntuの250ms stream-drain
  境界で失敗した。失敗jobだけのattempt 2ではWindowsが成功したが、Ubuntuが別の
  near-limit fixtureで再失敗したため、一過性として追加再実行しなかった。
- production process境界は変えず、self-test launcherだけに2秒のstream-drain猶予を
  設けた。Windows fixtureはchild自身の固定sleep後artifactではなく、bounded invocation
  返却後のchild process消失をPIDと開始時刻の組で直接検証する。独立reviewで、PID不在と
  process照会失敗を区別しないfail-openをP2として検出したため、`ArgumentException`だけを
  不在とし、同一instanceのstable handle待機、失敗時のbounded回収、全経路のhandle破棄へ
  修復した。修正後のscanner self-testはPowerShell 7で224.8秒、Windows PowerShell 5.1で
  141.2秒、ともに成功し、独立再review 2系統はP0〜P3すべて0。repair staged
  Gitleaksはleak 0、Semgrep `p/security-audit`はPR全6対象に実行された
  2 rulesでfinding 0だった。修正headのPR / main CIは未確認。
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

checkout v7.0.1更新をClass Mとして実行中。version commentを保持するparser契約、
mutable / legacy / stale-comment mutation、3つのfull-SHA pinを実装し、
PowerShell 7 / 5.1 readinessのRED / GREENとfull local runtime/scanner gateを確認した。
PR #22のhosted CIで顕在化したself-test timing境界を修復したため、全local gate、
security scan、独立reviewまで再確認した。repair commit / push、PR / post-mainの
3 OS job、integration evidence、cleanupを続ける。
