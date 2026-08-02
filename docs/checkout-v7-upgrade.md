# Checkout v7.0.1 更新設計

## 分類と目的

- **Class:** M
- **目的:** 3つのcanonical `actions/checkout` stepを、公式v7.0.1の
  verified full commit SHAへ更新する。
- **変更対象:** validation workflow、executable workflow contract、
  mutation fixture、CHANGELOG、Living Handoff。
- **非変更対象:** trigger、`contents: read`、3 jobs、runner、timeout、step、
  `persist-credentials: false`、plugin/hook/scanner behavior、tag、Release。

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
- pull-request headとpost-mainでWindows、Ubuntu、macOS 15の3 jobsを確認する。

## Handoff

- **状態:** 実装中。公式provenance、runtime互換性、baseline Git/GitHub/CI、
  local cross-runtime gate、validator-first RED / workflow GREEN、final plugin / hook /
  scanner gateは確認済み。独立reviewで見つかったno-separator comment誤受理は
  mutation RED / regex修正 GREENで解消し、review-fix後のsecurity / hygiene gateと
  独立再review 2系統も成功した。
- **外部境界:** secret、OAuth、実データ、production、deployment、paid operation、
  tag、GitHub Releaseは使用しない。
- **未確認:** PR/main CI。
