# Handoff

更新日: 2026-08-03 (JST)

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
  68共有ケースを持つ。POSIX hostではpath escaping 3件を加えた71件になる。
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
- 2026-08-02のClass M work unitでは、3つのcheckoutを公式v7.0.1のverified full
  commit SHAへ更新した。validatorはversion commentを所有stepへ結び付け、mutable / legacy
  pin、stale comment、comment separator欠落をfail closedにする。production scannerの
  既定250msは維持し、self-testだけのstream-drain猶予とPID＋開始時刻のtri-state観測で
  hosted runnerの終了競争を安定化した。
- reviewed feature head `6b2f4d685fe15d5f6400f52af8f066e0a2a29780`では、local
  cross-runtime gate、tracked private-marker scan、staged Gitleaks、Semgrep
  `p/security-audit`が成功し、独立review 2系統はP0〜P3すべて0だった。PR #22 run
  `30746654315`とsquash-merge integration commit
  `c9f7970d2d77aeb96113e6fd375156248b0bba92`のpost-main run `30746956450`は、
  いずれもWindows / Ubuntu / macOSの3 jobが成功した。reviewed headとintegration commitは
  tree `f3261e2d0dc0c84e28df59f6d4c6e29754e57a03`で一致し、feature branchも
  local / remoteからcleanup済み。
- 現行契約の可変なPR/run情報はmerge済みPRとActionsを都度再確認する。
- 最新の独立再レビューは`CLEAR:YES`（P0〜P3すべて0）。Git / GitHub / CIは外部状態のため、
  可変の「最終main」SHAやopen件数をここへ固定せず、次の着手時に必ず再計測する。
- 2026-08-03にmain / origin/main一致、open PR / issue 0、最新main 3 OS CI成功を再計測した。
  次のClass Mとして、`.devlog-markers` directory / marker leafのlink・reparse経由で
  設定root外をwrite / read / pruneするP1を選定し、`fix/reject-linked-marker-state`で着手した。
- PowerShell 7 baseline 65 / 65は成功。directory linkとhardlinkはPowerShell、directory / leaf
  symlinkとhardlinkはWSL Bashで合成REDを確認した。fixtureはsuite専用temp内だけを使う。
- linked childはfinal-entry attributes / `-L`を先に判定し、provider lookupやtarget directory
  predicateより前にfail-openする。通常・hard-linked markerはlocal nameをunlink後にexclusive
  createし、別名targetをtruncateしない。read / pruneもlinked directory / leafを拒否する。
- 最終local gateはPowerShell 7、Windows PowerShell 5.1、WSL Bashが各68 / 68成功。
  Claude strict plugin、plugin contract、launcher 13件、readiness、PowerShell 7 / 5.1 AST、
  Bash全6 script構文、private-marker self-test / tracked scan、Gitleaks worktree 1.09 MB / 履歴
  27 commits、Semgrep 47 tracked filesが成功し、独立review 2系統はP0〜P3すべて0だった。

## Success metrics

- plugin package、launcher、PowerShell/Bash hook、private-marker scannerの既存検証が成功する。
- CIはWindows、Ubuntu、macOSの各契約を有限時間で完了する。
- public outputへ保護対象を出さない。scanner/readiness境界は固定・非反射診断で
  fail closedし、hook input異常はSessionStartの固定警告または無音allowでfail openする。
- linked marker stateはSessionStartで固定警告付きfail-open、nudge / Stopで無音allowとし、
  root外targetのcontent / mtime / treeを変更しない。hardlinkは既存entryを直接truncateしない。

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
- PR #22のreviewed headとpost-mainはGitHub-hosted Windows / Ubuntu / macOS CI成功済み。
  以後の変更ではmacOS 15 / system Bash 3.2を含むActionsを再確認する。
- 明示Git Bashの追加linked-directory試験は、MSYS2既定deep copyのfixture不備により同じwarning
  assertionが3回失敗した。fixtureはnative junction / native file symlink + junction fallbackへ修正し、
  静的reviewはclearだが、3回上限を守って再実行していないため最終Git Bash reparse実測は未確認。
- このhostはnative file symlink権限がないため、PowerShell 7 / 5.1はjunction leaf fallbackを実測。
  actual file symlinkはWSL Bashで実測し、Ubuntu / macOS CIはPRで再確認する。

## Do not re-read

- 旧HANDOFFの実装経緯は再構成しない。永続的な結果は `CHANGELOG.md` とmerge済みPRを参照する。

## Next step

exact stage / global security hookを通してcommit・pushし、PRのWindows / Ubuntu / macOS CIを
確認する。CIとreviewがgreenならmergeし、post-main gate、HANDOFF closeout、branch cleanupまで
完了する。Git Bash追加試験は3回上限のため再試行しない。
