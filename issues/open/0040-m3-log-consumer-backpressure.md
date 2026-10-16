# [P1 / M3] LogConsumer 継続配信と backpressure を実装

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0013](./0013-m1-docker-log-stream.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 logs() は一括 64MiB の取得で upstream の LogConsumer callback を代替できない。

## 実装範囲

- subscribe/unsubscribe を API 化
- stdout/stderr と line parsing を明確化
- slow consumer の buffer 上限/stop 後配送/再入防止を設計

## 完了条件

- [ ] 連続ログが順序保持で配送
- [ ] consumer の panic/停止で leak なし
- [ ] 極長行・大量ログでも有界メモリ

## 検証計画（未実行）

- [ ] Docker/macOS 実体 streaming、slow consumer stress
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/logs/consumer.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/logs/consumer.rs))
- `src/core/logs/line.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/logs/line.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
