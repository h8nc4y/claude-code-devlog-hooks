# Checkout v7.0.1 更新設計

## 分類と目的

- **Class:** M
- **目的:** 3つのcanonical `actions/checkout` stepを、公式v7.0.1の
  verified full commit SHAへ更新する。
- **変更対象:** validation workflow、executable workflow contract、
  mutation fixture、hosted CIで顕在化したscanner self-test harness、CHANGELOG、
  Living Handoff。
- **非変更対象:** trigger、`contents: read`、3 jobs、runner、timeout、step、
  `persist-credentials: false`、plugin/hook/production scanner behavior、tag、Release。

## Provenanceと互換性

- 公式v7.0.1 tagはverified commit
  `3d3c42e5aac5ba805825da76410c181273ba90b1`を直接参照する。
- releaseは公開済みのstableだがimmutable表示ではないため、workflowはtagでなく
  verified full commit SHAを使う。
- 現行v5.1.0とv7.0.1はいずれもNode 24 action runtimeを使う。このworkflowは
  container action内でauthenticated Git commandを実行しない。

## 要件

1. 3つのcheckout stepが同じv7.0.1 full SHAと正しいversion commentを使う。
2. 各checkoutが所有する唯一のinputとして
   `with.persist-credentials: false`を維持する。
3. validatorがmutable `@v7`、旧v5.1.0 full SHA、stale version commentを
   fail closedに拒否する。
4. trigger、permission、job、runner、timeout、stepの既存exact契約を変えない。
5. CHANGELOGの旧v5 pin記録は履歴として保持する。

## 検証計画

- main上でplugin、readiness、launcher、PowerShell/Bash hook、scannerのbaselineを測る。
- validatorを先に更新し、旧workflowをPowerShell 7 / 5.1 readinessが拒否する
  REDを確認する。その後workflowを更新してGREENを確認する。
- frozen candidateで全local gate、private-marker scan、Gitleaks、Semgrep、
  encoding/line-ending、`git diff --check`、独立reviewを実施する。
- PRのhosted CIでself-test timing failureが再現した場合は、追加rerunで通過扱いにせず、
  production境界を維持したself-test-only修正をlocal両PowerShellで再検証する。
- pull-request headとpost-mainでWindows、Ubuntu、macOS 15の3 jobsを確認する。

## Handoff

- **状態:** 実装中。公式provenance、runtime互換性、baseline Git/GitHub/CI、
  local cross-runtime gate、validator-first RED / workflow GREEN、final plugin / hook /
  scanner gateは確認済み。独立reviewで見つかったno-separator comment誤受理は
  mutation RED / regex修正 GREENで解消し、review-fix後のsecurity / hygiene gateと
  独立再review 2系統も成功した。PR #22の初回hosted runと失敗job 1回再実行では、
  変更していないscanner self-testのWindows固定sleep競争とUbuntuの250ms pipe drain
  境界が顕在化した。production process境界は変えず、PID消失の直接検証と
  self-test-only 2秒drain猶予へ修復した。独立reviewで見つかったprocess照会の
  fail-openも、PIDと開始時刻で同一instanceを固定し、照会失敗の固定診断、bounded回収、
  handle破棄を行うよう修復した。local PowerShell 7 / 5.1は再び成功し、
  修正後の独立再review 2系統もP0〜P3すべて0だった。repair staged Gitleaksは
  leak 0、Semgrep `p/security-audit`はPR全6対象でfinding 0だった。repair headでは
  macOS、Ubuntu、Windows PowerShell 7 scannerが成功したが、Windows PowerShell 5.1が
  正常なchild終了と`StartTime` / `WaitForExit`の観測raceを固定診断で拒否した。
  追加rerunはせず、1秒の共有予算内でfresh processを再probeし、PID不在か開始時刻不一致
  だけを消失、同一instance残存を回収対象、観測不能を固定failureとするtri-stateへ修復した。
  local PowerShell 7 / 5.1のscanner self-test、readiness、tracked scan、Gitleaks、Semgrepは
  再び成功し、code diffの独立review 2系統もP0〜P3すべて0だった。
- **外部境界:** secret、OAuth、実データ、production、deployment、paid operation、
  tag、GitHub Releaseは使用しない。
- **未確認:** 次repair headのPR CI、main CI。
