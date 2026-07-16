# Journal Entry Templates / 日誌エントリのテンプレート

Copy-paste starting points for `daily/YYYY-MM-DD.md` entries. One file per
day; append a new session heading (or extend an existing one) each time.
The discipline behind these templates: [SKILL.md](../SKILL.md) /
[docs/SKILL.ja.md](../docs/SKILL.ja.md).

## 日本語 (default)

```markdown
## セッション(14:30) 〔CI の flaky テストを特定して隔離〕
- **やったこと**: <プロジェクト> の CI 失敗を調査。retry ログから flaky な
  統合テスト2件を特定し、隔離マークを付与。
- **学び・詰まり・解決**: テスト並列度を上げると DB fixture が競合する。
  `--workers 1` では再現しない → 並列競合が原因と確定。暫定は隔離、恒久対応は
  fixture の分離。
- **次回**: fixture 分離の PR を作る。
- 関連: [[flaky-test-triage]] ／ #ci #testing
```

軽微なセッションは一行で:

```markdown
軽微: README の typo 修正のみ。
```

## English

```markdown
## Session (14:30) [Identified and quarantined flaky CI tests]
- **Done**: Investigated CI failures in <project>. Found two flaky
  integration tests via retry logs; marked them quarantined.
- **Learned, stuck, solved**: Raising test parallelism makes DB fixtures
  collide. Not reproducible with `--workers 1`, which confirms the race.
  Quarantine is the stopgap; fixture isolation is the real fix.
- **Next**: Open the fixture-isolation PR.
- Links: [[flaky-test-triage]] / #ci #testing
```

Trivial sessions can be one line:

```markdown
Trivial: README typo fix only.
```

## Distilled Topic Note / 蒸留トピックの例 (`topics/<slug>.md`)

When the same lesson shows up a second time in `daily/`, move the general
form into a topic file and link it:

```markdown
# Flaky test triage checklist

Symptoms: intermittent CI failures, pass on retry, timing-dependent.

1. Check whether failures correlate with parallelism (`--workers 1` run).
2. Suspect shared state first: DB fixtures, temp files, ports, clocks.
3. Quarantine with a tracking issue; never delete the test silently.

First seen: [[2026-07-16]] (daily). Related: #ci #testing
```
