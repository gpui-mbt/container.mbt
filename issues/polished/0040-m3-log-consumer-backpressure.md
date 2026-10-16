# [P1 / M3] LogConsumer 継続配信と backpressure を実装

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0013](./0013-m1-docker-log-stream.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

upstream の `LogConsumer` に相当する継続ログ配信 API（subscribe / unsubscribe、stdout / stderr 別配信、行分割、slow consumer の有界バッファ）を実装し、既存の一括 `Container::logs` と共存させる。

## 背景

- 現行の [runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) の `Container::logs` は `container logs` / `docker logs` を一括取得して 64 MiB 上限で返すだけであり、継続的にログを処理する手段がない。
- upstream は [src/core/logs/consumer.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/logs/consumer.rs) の `LogConsumer` trait でフレームを消費し、[src/core/logs/line.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/logs/line.rs) が行分割（`MAX_LINE_LENGTH = 8 MiB`、超過行は先頭を切ってフレーム配信し残余は読み捨て、その際に warn）を行う。
- upstream の [src/core/client/docker_log_stream.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_log_stream.rs) はストリームごとの共有バッファを既定 8 MiB とし、上限到達時は drop-oldest する。読取側が捨てられた領域を読むと初回のみ skip の warn を出す。ログ配信の停止は stop / rm / Drop の共通前置きとして先に行う。
- 0013 が follow / attach と有界取得を担当し、Apple CLI には `container logs --follow` が存在する。

## 問題

- 連続ログを逐次処理できない。テストのログ検証が一括取得の文字列検索に限られ、長時間走るコンテナの進捗監視が書けない。
- slow consumer / 大量ログ時のメモリ上限、drop の検出方法、stop 後の配送、unsubscribe 時のリーク安全性が未定義。
- 行長上限・改行・`\r` の扱いが未定義。極長行でメモリが急増し得る。
- 配信停止と `Container::stop` / `rm` の順序が未定義で、停止処理との競合時に配送が残る可能性がある。

## 目標

- 継続配信 API でログフレームが順序どおり・ストリーム別（stdout / stderr）に届く。
- 行分割は upstream と同じ規則で行い、8 MiB 超の行は先頭を切ったフレームを配信して残余を読み捨てる。
- slow consumer でもメモリがストリームあたりの上限内に収まり、drop 発生を利用者が観測できる。
- unsubscribe / `Container::stop` / `Container::rm` で配信タスクとバッファが残らない。consumer 側の例外でも資源がリークしない。
- 既存 `Container::logs` の出力と意味論に回帰がない。

## 対象外

- readiness のログ待ち（0038 / 0039）。
- Docker Engine API のログストリーム実装そのもの（0013）。
- Apple XPC のログ FD 所有権（0029）と XPC ストリーム（M2）。
- ログのファイル永続化・転送（外部 collector 連携）。
- 公開 API のパッケージング（0051）。

## 提案する方針

- 新規 `logs.mbt`（ファイル名は実装詳細として変更可）に配信 API を設計する。upstream の `LogConsumer::accept` に対応する consumer callback 型、`LogFrame` 相当（ストリーム種別、行バイト列、切捨ての有無）、`subscribe` が返す配信ハンドル、`unsubscribe`（停止と完了待ち）を用意する。API 名と callback 形式は MoonBit の async 事情（`moonbitlang/async@0.22.4`）に合わせて実装時に確定する。
- 行分割は upstream の line.rs と同じ規則にする。改行区切り、行末 `\r` の除去、`MAX_LINE_LENGTH` 相当の上限（8 MiB）超過時は先頭からの上限分をフレームとして配信し残余を読み捨てる。切捨て時は警告を 1 回だけ出す。
- バッファはストリームあたりの上限（upstream は 8 MiB）を定数化し、上限到達時は drop-oldest とする。読取側が捨てられた領域を読んだ場合は初回のみ skip 警告を出す（upstream の挙動に合わせる）。複数の consumer がいても後続 consumer が過去フレームを読めるよう、上限内は読み取り位置を保持する。
- 供給元は 2 経路を分離する。Apple CLI は `container logs --follow` のプロセス出力、Docker は 0013 のストリーム（M0 CLI adapter の一括 `logs` は既存 API として残す）。
- 停止順序: `Container::stop` / `Container::rm` は配信を先に停止してからランタイム操作を行う（upstream の `stop_log_delivery` の順序に合わせる）。配信タスクは停止要求で終了し、完了を待ってから戻る。
- 再入・例外: consumer callback の例外や早期終了で配信タスクが死なないように guard で終了処理を保証する。callback 内から同じコンテナの配信 API を再帰的に呼ぶケースの扱い（検出してエラー、または明示禁止）は実装時に確定し、doc に書く。

## 受け入れ条件

- [ ] Given 改行区切りの連続ログを出すコンテナ, when subscribe する, then フレームが順序どおりに届き、stdout と stderr が混ざらない。
- [ ] Given 8 MiB を超える 1 行, when 配信される, then 先頭からのフレームと切捨て通知が得られ、その後の行は引き続き届く。
- [ ] Given callback が遅い consumer, when 大量ログが流れる, then メモリ使用が上限内に収まり、drop の発生が警告として観測できる。
- [ ] Given unsubscribe または `Container::stop`, when 配信を停止する, then 配信タスクが残らず、以後フレームが届かない。
- [ ] Given consumer callback が例外を投げる, when 配信が継続する, then プロセスとバッファがリークしない。
- [ ] 既存 `Container::logs` の出力と意味論、および既存 smoke に回帰がない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: 行分割パーサ（改行境界、`\r`、上限ちょうど・超過、切捨て後の次行、複数チャンク境界）、バッファの drop-oldest と skip 検出、subscribe / unsubscribe のライフサイクルを fake stream で検証する。
- Linux Docker 実機（CI の Docker ジョブ）で確認する。
  - 連続ログ fixture（一定間隔で行を出すコンテナ）と極長行 fixture を使い、順序・ストリーム分離・有界メモリ・slow consumer の drop 警告を確認する。
  - 実 Docker daemon が必要。証跡として受信フレーム数と drop 警告をログに残す。
- Apple Silicon 実機: `container logs --follow` 経路で同じケースを確認する。物理 Mac は CI に存在しないため、実行できるまで「未実行」と記録し、0002 / 0029 の実機受入時に併せて実施する。
- テストは生成名 prefix に限定して後始末し、ユーザー所有コンテナを削除しない（`issues/README.md` の運用ルール 5）。

## リスク

- callback 実行中の例外で配信タスクが死ぬ。guard で必ず終了処理を通し、テストでリークを確認する。
- drop-oldest によりテストがフレーム欠落でフレークし得る。drop 警告を観測可能にし、テストは consumer の消化速度を確保した上で実行する。
- stop と配送の競合。stop 完了後は新規フレームが届かないことを契約としてテストで固定する。
- メモリ上限の定数が性能と安全性のトレードオフになる。定数を一箇所に集約し、将来の設定化は別 issue とする。
- Apple CLI の follow 出力と Docker の多重化フレームで行分割規則が揺れる。パーサを共通化し、入力形式の差異は供給元側で吸収する。
- ロールバック: 新規 API の追加が中心で、既存 `Container::logs` を変更しない。問題時は revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] LogConsumer 相当の継続ログ配信と有界バッファ・backpressure を実装

## 注記

- upstream の対応物: [src/core/logs/consumer.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/logs/consumer.rs)、[src/core/logs/line.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/logs/line.rs)、[src/core/client/docker_log_stream.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_log_stream.rs)。
- 関連: 0013（Docker ログストリーム）、0029（XPC ログ FD）、0039（ログ待ちの再 poll 意味論）、0051（公開 API 文書）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の Start / exec / stop / rm / logs 行。
- 証跡要件: フレーム順序・drop 警告・停止後の非配送をログまたは artifact に残す。実機が使えない確認は「未実行」と明記する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
