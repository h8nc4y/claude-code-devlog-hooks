# Session ID Type Contract

## Objective

PowerShell と Bash の三つの hook で、top-level `session_id` の受理条件を
「空でない JSON string」に統一する。

変更前も Bash parser は非文字列値を拒否していた。一方、変更前のPowerShell
hookはnumber、boolean、array、objectを`[string]`へ暗黙変換したため、実際には
異なるprotocol inputが同じmarker名へ畳み込まれ得た。この差を解消し、未知の
入力を誤ったsessionへ関連付けない。

## Behavioral Contract

- 空でないJSON stringだけをsession identityとして受理する。
- 受理した文字列は、既存どおり`[A-Za-z0-9_.-]`以外を`_`へ置換する。
- stdin JSONが不正、または`session_id`が欠落、空文字、非文字列の場合は
  session identityを確立できない判定不能状態とする。
  - `SessionStart`は通常のcontextに固定のJA/EN警告を追加するが、
    marker directoryの作成、marker書込み、pruningは行わない。
  - `UserPromptSubmit`はstdout/stderrを出さずにallowする。
  - `Stop`はstdout/stderrを出さずにallowする。
- 固定警告はidentity未確立とStop/nudgeの無効化だけを伝える。raw stdin、
  `session_id`、secret-like値、またはそれらから派生した文字列を反映しない。
- 非文字列値を文字列化した名前のmarkerが存在しても、nudge/Stopは参照しない。
- `stop_hook_active`の既存boolean-only契約、marker timestamp、mtime判定、
  fail-open/fail-silent契約は変更しない。

## Impact

この変更はprotocol境界の型検証だけを狭める。正規のClaude Code入力である
string `session_id`のmarker名とhook判断は変わらない。identity未確立時は
enforcement-looking stateを一切作らず、cross-session marker collisionによる
誤nudge・誤blockと、実際には無効なenforcementを有効に見せる誤解を防ぐ。

## Verification Plan

repo-local synthetic fixtureだけを使い、共有pipe-testで次を確認する。

1. `SessionStart`へ欠落、空文字、非文字列、malformed stdinの各入力を渡し、
   exit 0、stderr空、raw UTF-8 JSONの通常contextと固定警告を確認する。
2. 各判定不能入力でmarker directory、marker、pruningのside effectがなく、
   raw input、session、synthetic secret-like sentinelがstdout/stderr/marker名へ
   反映されないことを確認する。
3. `UserPromptSubmit`へ同じ4種類を渡し、衝突候補markerが存在しても
   stdout/stderrが空であることを確認する。
4. `Stop`へ同じ4種類を渡し、衝突候補markerが存在してもblockせず
   stdout/stderrが空であることを確認する。
5. 日本語と英語の固定警告を完全一致で確認する。

PowerShell 7、Windows PowerShell 5.1、Bashで同じ共有ケースを実行し、
repository readiness、plugin/launcher、private-marker scanも回帰確認する。

## Boundaries

live hook/plugin install、Claude Code実行、実Vault書込み、secret/OAuth、
実データ、外部送信、有料操作は行わない。fixtureはthrowaway directoryと
synthetic JSONだけを使用する。
