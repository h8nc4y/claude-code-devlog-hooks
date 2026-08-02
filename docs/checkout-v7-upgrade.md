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

- **状態:** 完了。3つのcheckoutを公式v7.0.1のverified full commit SHAへ更新し、
  version commentとaction refの所有関係、mutable / legacy pin、stale comment、comment
  separator欠落をvalidatorでfail closedにした。production scanner境界は維持し、
  self-testだけのstream-drain猶予とPID＋開始時刻のtri-state観測でhosted runnerの
  終了競争を安定化した。reviewed feature head
  `6b2f4d685fe15d5f6400f52af8f066e0a2a29780`ではlocal cross-runtime gate、
  tracked private-marker scan、Gitleaks、Semgrep、独立review 2系統が成功した。
  PR #22 run `30746654315`とsquash-merge integration commit
  `c9f7970d2d77aeb96113e6fd375156248b0bba92`のpost-main run `30746956450`は、
  いずれもWindows / Ubuntu / macOSの3 jobが成功した。reviewed headとintegration commitは
  tree `f3261e2d0dc0c84e28df59f6d4c6e29754e57a03`で一致し、feature branchも
  local / remoteからcleanup済み。
- **外部境界:** secret、OAuth、実データ、production、deployment、paid operation、
  tag、GitHub Releaseは使用しない。
- **未確認:** live Claude Code plugin install、実Vault書込み、owner環境のmacOS live session。
