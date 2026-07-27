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
- `session_id`が欠落、空文字、または非文字列の場合:
  - `SessionStart`はcontextを出力し、`unknown.start`だけを書き込む。
  - `UserPromptSubmit`はstdout/stderrを出さずにallowする。
  - `Stop`はstdout/stderrを出さずにallowする。
- 非文字列値を文字列化した名前のmarkerが存在しても、nudge/Stopは参照しない。
- `stop_hook_active`の既存boolean-only契約、marker timestamp、mtime判定、
  fail-open/fail-silent契約は変更しない。

## Impact

この変更はprotocol境界の型検証だけを狭める。正規のClaude Code入力である
string `session_id`のmarker名とhook判断は変わらない。非文字列値は
unjudgeableとして扱い、cross-session marker collisionによる誤nudge・誤blockを
防ぐ。

## Verification Plan

repo-local synthetic fixtureだけを使い、共有pipe-testへ次の三ケースを追加する。

1. `SessionStart`へnumber `session_id`を渡し、`unknown.start`が作成され、
   数値名markerが作成されないことを確認する。
2. 数値名markerを事前作成して`UserPromptSubmit`へ同じnumberを渡し、
   stdout/stderrが空であることを確認する。
3. 数値名markerを事前作成して`Stop`へ同じnumberを渡し、blockせず
   stdout/stderrが空であることを確認する。

PowerShell 7、Windows PowerShell 5.1、Bashで同じ共有ケースを実行し、
repository readiness、plugin/launcher、private-marker scanも回帰確認する。

## Boundaries

live hook/plugin install、Claude Code実行、実Vault書込み、secret/OAuth、
実データ、外部送信、有料操作は行わない。fixtureはthrowaway directoryと
synthetic JSONだけを使用する。
