# Handoff

## Current goal

private-marker scanner の fail-closed・hermetic・bounded 更新はPR #8、
PSVariable receiver follow-upはPR #10で`main`へ統合済み。本follow-upでは
全production regexへ有限MatchTimeoutを付け、各matchを最大250 msへ有限化する。

## Delivered

- stage-0 index blob と tracked worktree を別 provenance として検査し、最終
  raw index snapshot 一致を必須化。
- Git child の全 `GIT_*`、config、hook、filter、prompt、trace、repository /
  index / object redirect を隔離。subdirectory、conflict、intent-to-add、
  gitlink、symlink/reparse、path escape、変化中 file は fail closed。
- scan-wide deadline と process/file/byte/line/match/finding/UTF-8 output 上限を追加。
  全production regexはPS5.1互換の3引数constructorで最大250 msの
  MatchTimeoutを持つ。timeout診断はGit cleanup後まで遅延し、通常は固定
  `regex-timeout`、cleanupも失敗した場合は`process-boundary`だけをstderr
  1行 + exit 2で返す。入力/patternは再掲しない。readiness AST gateは
  operator/cast/短縮型/static API/New-Object/switch/Select-Stringとtimeout由来の
  mutationを拒否し、near-limit安全入力とcleanup競合も回帰化。
- helper欠落/例外、timeout/output、Git isolation create/removeを固定ASCII stderr
  1行 + exit 2へ統一し、repo/temp/scanner/helper絶対pathを出力・例外へ出さない。
- Windows は suspended direct target → stdio handle allowlist → Job assign →
  resume を維持。assign/resume failure の terminate/close/wait と error 集約を
  synthetic PID/sentinel で検証。Job close failure はhandleを保持してdirect
  terminateし、後続Stop/Disposeで同じhandleをretryする。success 40回後の
  GCでstdio handleが線形増加しないことも実測する。Job割当後に期限0をnative
  `Start`へ直接渡し、ResumeThread直前のdeadline防御、PID消失、target未実行も固定。
- BOM-less `-File` binary transport、native Git batch bytes、`.Invoke*()`、
  direct/transitive function、scope prefix、risky alias、function object の
  AST 順序、target helper shadow、Invoke-Command/InvokeScript、dynamic dot、
  Alias/Function/Variable provider mutation（Set-Content/Set-Variableを含む）、
  risky class construction/conversion（`-as`/static member provenanceを含む）、
  stored ScriptBlock引数、compound Invoke receiver、POSIX process group/errno
  の regression を追加。dynamic New-Item provider pathのFile/Directory免除は削除。
- public timeout/deadline/probe の invalid binding をbody内validationへ移し、
  固定stderr 1行 + exit 2へ統一。標準linked worktree gitfileとPOSIX `.GIT`
  directory/leafのcase-sensitive fallbackをregression化。
- self-test/readiness は同じ pure AST policy を使い、dynamic 解決は fail
  closed。literal native `Get-Command git -CommandType Application` は許可。
- bootstrap以外のliteral/dynamic `.` / `&` とfunction/type wrapperをfail
  closed化。許可する2 dot-sourceはsource直下の単一`$root`代入と
  `System.IO.Path` static callによるroot/path provenanceへ固定し、
  `Join-Path` function/alias shadowと`$root`再代入の迂回を回帰化。
- bare/alias経由script path、tuple/`PSVariable`/`[ref]` mutation、stored
  ScriptBlockのVariable provider回収、`ScriptBlock.Create` /
  `NewScriptBlock` / parser `GetScriptBlock`、ExternalScript lookupも拒否。
  `Get-Command git -CommandType Application`だけをnative lookup正例に固定。
- dormant function/type本文はeager処理から除外。実際に先行呼出しされるwrapperでは
  `script:`/`global:` mutation、mutable `PSVariable.Get` handle、PSVariable
  table aliasを拒否。括弧/cast/subexpression/単要素array indexもunwrapする。
  unsupported command wrapper内にraw table provenanceが残る場合もsubtreeを
  fail closedに追跡し、provenanceの無いsafe command expressionは許可する。
  scoped receiver、`Get-Variable ExecutionContext`、alias/parameter経由も追跡する。
  function-local代入、先行local bindingが保証された`[ref]`、無関係なobjectの
  `GetValue`/`SetValue`は許可するscope/receiver回帰を追加。未参照local
  ScriptBlockだけをdormantとし、scope escape、inline/provider消費、後続参照、
  script/global helper shadowを拒否。index/member mutationは`[ref]`のlocal
  bindingに数えず、`$Path` fallbackはtrusted `$scriptRoot` +
  `System.IO.Path.GetDirectoryName`へ固定。
- `$ExecutionContext.SessionState.PSVariable` のgeneric-risk除外を
  consumer-aware化。transparent wrapperの終端が静的
  `Get`/`GetValue`/`Set`/`SetValue` receiverの場合だけ後段の変数名検査へ渡し、
  return / assignment / command argument / multi-element pipelineはfail closed。
  castは除外し、arrayは直後のindexで唯一要素へ戻す形だけを許可。
  PS7/PS5.1で実際の`script:root`変異を証明するruntime fixtureも追加。
- POSIX はexternal/nativeとも同じready/release wrapperを使い、option-free
  `setsid` operand、ready PIDの`getpgid(pid) == pid`確認後にだけtargetを解放。
  deadlineはprep/start/handshake前から計測し、tree/stream/final cleanupは
  1つの独立した有限猶予の残量を共有する。external forkのlate ready PIDも
  同じ総budget内で回収する。release後はwrapperが実payloadの完了/exit codeを
  atomic sidecarへ公開し、tracked parent先行exitを完了と誤認しない。GNU/default、
  forced native、BusyBox互換shim、normal early-fork、delayed handshake、
  timeout後のlate-ready回収を回帰化。
- Actions の全 active top-level/job ID（quoted/flow key を含む）、trigger、
  permissions、runner、timeout、step shell/run を exact validation。
  Windows PS7/PS5.1 と Ubuntu 24.04 を対象化。

## Verified locally

- scanner full self-test: PowerShell 7 / Windows PowerShell 5.1 / Ubuntu
  PowerShell 7 の最終 follow-up treeでPASS。
- PSVariable return-wrapper follow-up: readiness とfull scanner self-testを
  PS7 / PS5.1 / Ubuntu (`--init` container)でPASS。PID 1がreapしないcontainer
  では停止済みchildがzombie化することも切り分け済み。
- regex MatchTimeout follow-up: 1,000,000文字のno-match入力が修正前は外部
  15.129秒上限を超過し、最終修正後はPS7 2.755秒 / PS5.1 1.462秒で固定
  exit 2へ収束。readinessとfull scanner self-testをPS7 201.2秒 /
  PS5.1 138.0秒 / Ubuntu 249.3秒（read-only・`--network none`・`--init`
  container）でPASS。
- readiness: PS7 / PS5.1 / Ubuntu PASS。workflow mutationと first-call
  mutation（wrapper/alias/function objectを含む）も拒否。
- plugin contract PS7/PS5.1、launcher 13 cases、hook pipe tests
  PS7/PS5.1各30 cases・Windows Bash 30 cases・Ubuntu Bash 33 cases、
  Bash syntax、scanner通常scan PS7/PS5.1/Ubuntu: PASS。
- `claude plugin validate . --strict`: PASS。
- AST/POSIX/Windows deadlineの独立read-only再review: CLEAN。
- Gitleaks directory / history（11 commits）: 0 findings。
  Semgrep `p/default`（44 files / 88 rules）: 0 findings / 0 errors。
- PR #8 Actions run `30133375935` とmerge後main run `30134332191` は、
  Windows / Ubuntuの全jobがPASS。

## Integration state

- PR #8はsquash merge済み（merge `a74f34ed8457797384a0b79863644157ea94991e`）。
- PR #10はsquash merge済み（merge
  `0039d8441a211929072dd19edc89282204f3e3ee`、initial commit
  `c9db040723c6f5579b5cb960d2ffb7b771885559`）。
- regex MatchTimeout follow-up は `fix/regex-match-timeout` の最終freezeで
  local 3環境検証と独立review CLEANまで完了。GitHub integration recordは
  PR #11とし、state／merge commit／Actions evidenceはGitHub現況を正とする。

## External gates / unverified

- live Claude Code plugin install、marketplace 公開、実 Vault 書込み、
  macOS hardware / Bash 3.2 は未確認。login、credential、実データ、公開、
  paid operation は実施しない。
