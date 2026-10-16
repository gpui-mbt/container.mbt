# [P1 / M0] CLI 起動・readiness・cleanup の回帰テストを固定する

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M0
Depends on: [0001](./0001-m0-run-failure-orphan-cleanup.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

0001 の orphan 回収を含む M0 CLI ライフサイクルの契約（共有 deadline、rollback、所有 ID 限定の操作）を wbtest と smoke で固定し、以降の変更で黙って壊れないようにする。

## 背景

- [runtime_wbtest.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime_wbtest.mbt) には共有 deadline の 4 テスト（単一 delay 超過、複合 delay、start 前 deadline の引継ぎ、logs 予算の clamp）と builder snapshot のテストがある。
- [smoke/main.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke/main.mbt) は Docker 実機で builder mutation が報告 port を変えないこと、複合 readiness が 1 予算であること、readiness 失敗時にコンテナが残らないことを確認している。
- 0001 が run 失敗経路の orphan 回収と name / label 生成を追加し、0004 が runtime 別の拒否契約を追加する。本 issue は両者を回帰テストで固定する。
- upstream は `run_ready_sequence` の失敗時に Keep ゲート付きの明示 rm でロールバックする（[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)）。

## 問題

- run 失敗経路（ID 取得前の失敗・timeout）の回収は現行テストに存在しない。
- 回収の予算が起動 deadline と独立であること、回収が対象の name / run ID だけに限定されることをテストで示せない。
- name 生成・ユーザー指定 name の事前衝突検出といった 0001 の新規契約が未カバー。
- 実機 smoke は Linux Docker のみで、Apple 分は 0002 に依存する。

## 目標

- start 起点の deadline が readiness 中に延長されない契約を維持・拡張する。
- 中断・readiness 失敗時の rollback が、起動 deadline とは別の有界予算で実行されることを固定する。
- run で使った name / run ID 以外を削除しないことを固定する（0001 の回帰）。
- 0004 の runtime 別拒否契約を wbtest で固定する。
- 既存の成功パス（smoke）の観測結果を変えない。

## 対象外

- 実機故障注入の網羅（0001、0020）と Apple 実機（0002、0003）。
- M1 direct API のテスト（0010–0020）。
- fuzz / 資源リークの系統検証（0054）と公開エラー型の整備（0049）。
- 実ランタイムの性能・負荷試験。

## 提案する方針

- `runtime_wbtest.mbt` を起点にテストを追加する。新規テストファイルへの分割は実装詳細として変更可。追加する契約:
  - run ID / name 生成の一意性・推測困難性と label 引数の組み立て。
  - ユーザー指定 name の事前衝突検出（run の副作用なしでエラー）。
  - 回収判定が run ID label の一致を要求すること（不一致は対象外）。
  - 回収予算が起動 deadline と独立であること（deadline 経過後でも回収だけは実行できる）。
- 0001 の実装を「純粋な判定・生成」と「spawn」に分けられる場合は、前者を wbtest、後者を smoke に置く。分割の境界と関数名は 0001 の実装に合わせる（本 issue で断定しない）。
- `smoke/main.mbt` に 0001 の失敗ケース（存在しない `--entrypoint` などで run が ID を返す前に失敗する故障注入）を追加し、生成 name の残存ゼロと無関係コンテナの生存を確認する。
- 0004 の拒否テストが `commands_wbtest.mbt` に入る場合は本 issue のテスト一覧に含め、重複定義しない。
- テストの掃除は生成 name prefix（`container-mbt-` など）と label 所有確認に限定する（[issues/README.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/issues/README.md) ルール 5）。

## 受け入れ条件

- [ ] Given 既存 4 本 + 追加した wbtest, when `moon test --target native` を実行する, then すべて PASS する。
- [ ] Given start 前から deadline を消費した状態, when readiness 条件が続く, then 予算が延長されない（既存テストの維持）。
- [ ] Given readiness 失敗と run 失敗の両経路, then rollback が起動 deadline と別の有界予算で実行され、元の run エラーを上書きしない。
- [ ] Given 無関係な既存コンテナ, when 回収テストを実行する, then 削除されない。
- [ ] Given Docker 実機（CI の docker ジョブ）, when `moon run smoke --target native` を実行する, then 既存の `Docker lifecycle E2E PASS` と追加した失敗注入ケースが PASS する。
- [ ] Given 0004 の拒否契約, when wbtest を実行する, then runtime 別の拒否が PASS する。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- CI の docker ジョブで `moon run smoke --target native` を実行する。run 失敗ケースは不正 entrypoint などの故障注入で作り、`docker ps -a` 相当で残存ゼロを確認する。
- Apple 分の失敗注入は 0002 の実機セッションで確認し、それまでは「未実行」と記録する。
- 追加テストが spawn に依存する場合は、固有 name prefix と `inspect` / `rm` による後始末を守る。

## リスク

- wbtest が実プロセス spawn に依存して flaky になる → 純粋関数へ寄せ、実 spawn は smoke に限定する。
- smoke の故障注入がユーザー環境のコンテナに触れる → 固有 name prefix と label 所有確認を必須にする。
- 既存テストの変更で回帰が隠れる → 既存の 4 本と smoke の既存確認は削除・緩和しない。

## 変更履歴

`CHANGES.md` impact: no

判断理由: テスト追加が中心で、利用者に見える API・挙動を変えない。

## 注記

- 0001 の回帰を本 issue が固定し、0004 の拒否契約もここで固定する。
- 関連: [runtime_wbtest.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime_wbtest.mbt)、[smoke/main.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke/main.mbt)、[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- issues/README.md の運用ルール 2 / 5 に従い、PASS / FAIL / 未実行を混同せず、生成した name に限定して掃除する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
