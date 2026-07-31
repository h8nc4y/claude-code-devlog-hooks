# Hook Input Protocol Contract

## Objective

PowerShell と Bash の三つの hook で、stdin の JSON root、protocol field 名、
重複、型の受理条件を統一する。

型境界を揃えた後も、PowerShell の `ConvertFrom-Json` は単一要素arrayのscalar化
だけでなく、unquoted/single-quoted key、leading-zero number、`NaN`などRFC JSON
外の構文を受理する。一方、Bash command substitutionはNUL byteを削除し、property
名のUnicode escapeをmarker用のlossy表現へ畳み込んでいた。さらに、異なる
`session_id`が同じmarker名へ置換される余地と、byte上限内でも過大なJSON要素数や
数値長でCPU・memoryを消費する余地があった。曖昧・破損入力を実在sessionへ
関連付けず、二つのruntimeで同じbyte-level判断とwork budgetに固定する。

## Behavioral Contract

- stdinはUTF-8として厳密にdecodeできる最大1,048,576 byteのRFC JSONで、厳密に
  一つのtop-level objectでなければならない。NUL、invalid UTF-8、上限超過、
  単一要素array、またはstring、number、boolean、nullのrootは判定不能とする。
- 1,048,576 byteちょうどは受理対象とし、1,048,577 byte以上は拒否する。
- JSON container depthはtop-level objectを1として最大128、property名は各objectで
  最大256 Unicode scalar、number tokenは最大1,024文字、property valueとarray
  elementの合計は最大4,096とする。いずれかのbudget超過は入力全体を判定不能とする。
- unquoted/single-quoted key、comment、trailing comma、leading-zero number、
  `NaN`、`Infinity`、小数部が空のnumberなどJSON拡張構文は受理しない。
- JSON escape字種は大文字小文字を区別し、RFCで定義された小文字
  `b/f/n/r/t/u`だけを受理する。`\B`、`\F`、`\N`、`\R`、`\T`、`\U`はproperty
  名・値のどちらでも判定不能とする。
- JSON escapeをlosslessに復号したtop-level property名をordinal・case-sensitiveで比較し、
  `session_id`と`stop_hook_active`だけをprotocol fieldとして扱う。
  `SESSION_ID`や`STOP_HOOK_ACTIVE`など大小文字の異なる別名は未知fieldとして
  無視し、正規fieldの代替として受理しない。
- top-level property名は、Unicode scalar列のordinal完全一致とASCII
  case-fold後のordinal比較の両方で一意でなければならない。protocol fieldか
  未知fieldかを問わず、literal/escaped表現をまたぐ完全一致重複やASCII大小文字
  衝突は入力全体を判定不能とする。
- 非ASCIIの大小文字はlocale依存foldを行わない。たとえば`Ä`と`ä`は異なる一意な
  未知fieldとして両runtimeで受理し、protocol判断へ影響させない。
- `session_id`は`[A-Za-z0-9_.-]`だけから成る1〜64文字のJSON stringに限って
  session identityとして受理する。unsafe文字、非ASCII scalar、空文字、65文字以上は
  identity未確立とする。
- 受理したidentityはASCII byteごとにlowercase hexへ可逆・単射符号化し、`~sid-`
  prefixと`.start` suffixを持つmarker keyへ変換する。これによりcase-insensitive filesystem
  上の`A`/`a`、Windows予約basename、旧raw/sanitized marker namespaceを区別する。
- `stop_hook_active`は正規名の値がJSON boolean `true`の場合だけloop guardを
  有効にする。文字列、大小文字別名、nested fieldはguardを有効にしない。
- stdin byte列またはJSON grammarが不正、上限超過、rootがobject以外、
  top-level fieldが重複・衝突、または`session_id`が欠落、空文字、非文字列の
  場合はsession identityを確立できない判定不能状態とする。
  - `SessionStart`は通常のcontextに固定のJA/EN警告を追加するが、
    marker directoryの作成、marker書込み、pruningは行わない。
  - `UserPromptSubmit`はstdout/stderrを出さずにallowする。
  - `Stop`はstdout/stderrを出さずにallowする。
- 固定警告はidentity未確立とStop/nudgeの無効化だけを伝える。raw stdin、
  `session_id`、secret-like値、またはそれらから派生した文字列を反映しない。
- 非文字列値を文字列化した名前のmarkerが存在しても、nudge/Stopは参照しない。
- 未知のtop-level fieldとnested fieldはprotocol判断へ影響させない。
- marker timestampは改行なしのcanonical ASCII decimalとし、1〜18 byte、数字のみ、
  複数桁の先頭`0`なしを受理する。Bashはread前後のsize確認と最大19 byte read、
  PowerShellは`FileStream`のlength確認とexact bounded readで検証する。不正・変更中・
  過大なmarkerはfail openする。
- Bashは設定rootもUTF-8として検証する。非UTF-8の環境byteを含むrootは、JSON出力や
  marker/journal mutationより前にfail openする。
- mtime判定、fail-open/fail-silent契約は変更しない。

## Impact

この変更はprotocol境界の構造・名前・多重度・型検証を狭め、session上限を64文字へ
固定する。正規のClaude Code入力である単一object、正規名、safe ASCII 1〜64文字の
`session_id`、boolean `stop_hook_active`のhook判断は維持するが、marker名はportableな
encoded keyへ移行する。更新前に開始し旧markerしか持たないsessionは新hookからmarkerを
見つけられずfail openする。旧markerは通常のretention pruning対象として残る。以前は
置換後に衝突し得たunsafe `session_id`は受理範囲から外れる。identity未確立時は
enforcement-looking stateを一切作らず、cross-session marker collisionによる
誤nudge・誤blockと、実際には無効なenforcementを有効に見せる誤解を防ぐ。

## Verification Plan

repo-local synthetic fixtureだけを使い、共有pipe-testで次を確認する。

1. 既存の欠落、空文字、非文字列、malformed stdinに加え、top-level array、
   大小文字別名、protocol/未知fieldの完全一致重複、ASCII大小文字衝突を三つの
   hookへ代表配置する。
2. leading zero、unquoted/single-quoted key、comment、trailing comma、`NaN`、
   `Infinity`、不完全なfraction/exponent、leading plus/decimal pointに加え、
   大文字`B/F/N/R/T/U` escapeを
   property名・値で三runtimeが同じく拒否する。
3. NUL、overlong・surrogate・範囲外・truncatedを含むinvalid UTF-8、
   1,048,577 byte以上をbyte列fixtureで拒否する。1,048,576 byteちょうどは受理し、
   Bashがcommand substitutionで入力を正規化しないことを確認する。
4. literal/escaped Unicode完全一致を重複として拒否し、異なるescaped Unicode
   unknown fieldと非ASCII case pairは一意な未知fieldとして受理する。
5. `SessionStart`の各判定不能入力でexit 0、stderr空、raw UTF-8 JSONの通常context
   と固定警告、marker directory作成・marker書込み・pruningがないことを確認する。
6. raw input、session、synthetic secret-like sentinelがstdout/stderr/marker名へ
   反映されないことを確認する。
7. `UserPromptSubmit`は衝突候補markerが存在しても判定不能入力をsilent allowする。
8. `Stop`は大小文字別名だけの`STOP_HOOK_ACTIVE`を無視して通常どおりblockし、
   重複・衝突した`stop_hook_active`をsilent allowする。
9. JSON escapeで表現した正規`session_id`名を両runtimeが同じfieldとして受理する。
10. helperを直接呼び、`{}`はparse成功・`HasSession=0`・`StopActive=0`、
    `{"session_id":null,"stop_hook_active":true}`はparse成功・
    `HasSession=0`・`StopActive=1`になることを各runtimeで確認する。
11. 日本語と英語の固定警告を完全一致で確認する。
12. depth 127/128/129をscalar leaf付きで、property 256/257 scalar、number
    1,024/1,025文字、value 4,096/4,097件の境界を直接parser probeで確認する。
13. safe `session_id` 64/65文字、unsafe文字、supplementary scalarを確認し、
    `A`/`a`、`NUL`/`CON`/`COM1`、旧raw marker候補が別のencoded keyになること、
    `a/b`と`a?b`が既存の`a_b.start`を参照しないことを三hookで確認する。
14. markerのleading zero、19 byte、1 MiB fixtureをboundedにfail openすることを確認する。
15. harnessがstdoutを先に大量出力するchildと1 MiB stdinをfull-duplexで処理し、共通
    deadline内に完了すること、stdinを読まないchildはkill後にpipeを閉じること、各
    output pipeの1 MiB capture cap超過を、同じchildが大きいstdinを読まない場合も
    timeoutへ誤分類せずboundedに失敗させることを確認する。
16. POSIXでは非UTF-8 rootをwrapper fixtureで注入し、stdout/stderrとfilesystem
    mutationがないことを確認する。

PowerShell 7、Windows PowerShell 5.1、Bashで同じ共有ケースを実行し、
repository readiness、plugin/launcher、private-marker scanも回帰確認する。

## Boundaries

live hook/plugin install、Claude Code実行、実Vault書込み、secret/OAuth、
実データ、外部送信、有料操作は行わない。fixtureはthrowaway directoryと
synthetic JSONだけを使用する。
