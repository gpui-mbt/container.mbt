# [P1 / M3] Linux/Mac の実証と compile-only を区別する CI

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-17
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0020](./0020-m1-linux-native-e2e.md), [0032](./0032-m2-apple-native-xpc-e2e.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

CI 上で native check / test / build と daemon E2E を区別し、物理 Mac の Apple Container E2E 証跡（URL / 日時 / HEAD / ログ）を追跡可能にする。明示 skip を緑として扱わない。

## 背景

- 現在の CI は ubuntu-24.04 の単一 `native` ジョブで、check / test / build / Linux Docker lifecycle smoke / `moon package --list` を直列に実行する（[.github/workflows/ci.yml](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/.github/workflows/ci.yml) 1–32 行）。Linux Docker smoke は `moon run smoke --target native` で実 daemon を使う（[README.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/README.md) 33 行付近）。
- [docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md) は「NOT RUN」とし、GitHub-hosted macOS runner の compile では代替できない（nested virtualization 非対応）ことを merge gate に含める。
- [issues/README.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/issues/README.md) の運用ルール 2・4・5 が「PASS / FAIL / 未実行を混同しない」「実機 E2E を CI compile-only で代替しない」「ユーザー所有 container を破棄しない」を定める。
- 0002 / 0032 の受入と 0020 の E2E が前提。0050 の fixture 結果の保存先にもなる。

## 問題

- check / test / build と daemon E2E が同一ジョブで、どの段階が実証なのか CI の表示から読み取りにくい。
- 実機 Mac の証跡（URL / 日時 / HEAD / 実行ログ / 前後のコンテナ一覧）をどこへ保存するか定義がない。
- 環境がない場合の skip が緑扱いになる余地がある（明示「未実行」の表示と完了条件の分離がない）。
- 失敗時に failure ログと残存 container 一覧が残らず、原因調査が手作業になる。

## 目標

- CI は native compile / test と Docker daemon E2E を別ジョブまたは明確に分かれた step として持ち、どちらが失敗したか名前だけで判別できる。
- 物理 Mac の Apple E2E 証跡（URL / 日時 / HEAD / 生ログ）が artifact として追跡できる。
- 環境がない場合の skip は「未実行」と表示され、green と区別される。
- 失敗時は failure ログと残存 container 一覧（テスト生成 prefix の抽出）を artifact に残す。

## 対象外

- 実機 Mac の実行そのもの（0002 / 0032）。本 issue は証跡の受け皿と検証 gate を整える。
- self-hosted runner の調達など大規模な再設計。GitHub-hosted でできる範囲と手動実機証跡を組み合わせる。
- 0050 の fixture 内容（本 issue は CI への組み込み先だけを扱う）。
- 0051 の consumer CI。

## 提案する方針

- [.github/workflows/ci.yml](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/.github/workflows/ci.yml) を分割する（名称は例。実装時に確定）。
  - `native`: check（`--deny-warn`）/ test / build / `moon package --list`。
  - `docker-e2e`: `docker info` → `docker pull alpine:3.20` → `moon run smoke --target native`。失敗時も `docker ps -a` の前後スナップショットと smoke 出力を artifact へ保存する（`actions/upload-artifact`、`if: always()` 相当）。
  - 既存の timeout（15 分）と concurrency は維持し、toolchain セットアップの重複を許容してでも失敗箇所の判別を優先する。
- Apple 用 job は追加しない（GitHub-hosted macOS は実機ではない）。代わりに docs/APPLE_E2E.md の実行手順に沿った証跡テンプレート（日時 / HEAD / OS / arch / `container system version` / 実行ログ / `container list --all` の前後）を整備し、PR 本文へ貼る運用を README / docs に明記する。
- 明示 skip の扱い: 環境がないテストは戻り値として「未実行」を返し、CI ログと artifact に `SKIP (未実行)` と記録する。exit 0 で黙って通す実装を禁止する（0001 / 0004 の no-silent-pass 原則と同じ）。
- 失敗時の残存一覧は生成 name prefix（例: `container-mbt-`）に限定し、一覧の保存のみ行う。ユーザー所有コンテナを削除しない。
- artifact 名に HEAD SHA と日時を含め、PR 本文テンプレートに証跡 URL 欄を設ける。
- README の Development に、CI と同等のローカル実行コマンド（check / test / smoke）を同期させる。

## 受け入れ条件

- [ ] Given push / PR, when CI を実行する, then `native` と `docker-e2e` のどちらが失敗したかジョブ名で判別できる。
- [ ] Given Docker E2E の失敗, when artifact を確認する, then failure ログと `docker ps -a`（`container-mbt-` prefix 抽出）が残っている。
- [ ] Given Apple E2E 未実行, when PR を確認する, then 「未実行」と明記され、緑 / PASS 扱いになっていない。
- [ ] Given 実機 Mac の受入, when 証跡を確認する, then URL / 日時 / HEAD / 実行ログ / 前後のコンテナ一覧がある。
- [ ] Given 変更後の CI 構成, when ローカルで確認する, then README の Development と実行コマンドが一致している。
- [ ] Given CI の実行, when コンテナ一覧を確認する, then ユーザー所有コンテナを CI が削除していない。

## テスト計画

- 本変更は CI YAML と文書。PR 上でワークフローを 1 回実行し、ジョブ分割・artifact 保存・失敗時動作・「未実行」表示を確認して結果を記録する。
- `moon check --target native --deny-warn` / `moon test --target native` / `moon run smoke --target native` を新しいジョブ構成でも実行し、PASS / FAIL / 未実行を記録する。
- 失敗経路の注入: 存在しない entrypoint などで smoke を失敗させ、failure ログと残存一覧の artifact が残ることを確認する（確認後は元に戻す）。
- 物理 Mac の証跡は実行できない場合「未実行」と理由を明記する。GitHub-hosted macOS runner を実機 E2E の代替にしない。
- CI で確認できない手動受入（実機）は、証跡テンプレートに沿って記録された URL / 日時 / HEAD を完了条件の判定に使う。

## リスク

- ジョブ分割で toolchain セットアップが 2 回になり総時間が増える。cache と timeout で抑制し、E2E の分離に限定する。
- artifact の保存量増加。ログを有界化（`tail` など）し、失敗時も容量上限を設ける。
- 「未実行」運用が形骸化して常態化する。0002 / 0032 の受入を merge gate とし、PR テンプレートで可視化する。
- テスト用 prefix 以外の一覧を保存して秘密情報が混入する。抽出条件を prefix に限定し、環境変数などを artifact に出さない。
- ロールバック: ci.yml と文書の変更のみで、revert で戻せる。

## 変更履歴

`CHANGES.md` impact: no

## 注記

- 参照: [.github/workflows/ci.yml](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/.github/workflows/ci.yml)、[docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md)、[README.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/README.md)。
- 関連: 0020 / 0032（実機受入）、0050（fixture 結果の保存先）、issues/README.md の運用ルール 2・4・5。
- 証跡は [docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md) の merge gate（Linux CI green + 独立承認 + 物理 Mac 受入 + startup cleanup blocker 解消）と同じ判定語彙（PASS / FAIL / 未実行）を使う。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた

## 実装状況 (2026-10-17)

CI を `native` と `docker-e2e` に分割し、失敗時 artifact と SHA/run id 付き name を追加。Apple 実機は GitHub-hosted macOS job で代替しない方針を維持。ワークフローの実 remote 実行は未実行。
