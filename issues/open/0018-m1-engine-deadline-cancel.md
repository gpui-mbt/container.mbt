# [P0 / M1] Engine transport の deadline・取消・再試行を一元化

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M1
- Depends on: [0006](./0006-m1-docker-unix-socket-transport.md), [0007](./0007-m1-docker-http-framing-parser.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 に導入済みの start 起点 absolute deadline を HTTP transport でも失ってはいけない。

## 実装範囲

- connect/read/write/pull/create/start/ready に共通 deadline を伝搬
- cancel 時 socket と子 task を回収
- cleanup は期限付きの独立操作とする

## 完了条件

- [ ] 各処理でタイマーをリセットしない
- [ ] 遅い応答が全体期限内に中断する
- [ ] 取消後に所有リソースが残らない

## 検証計画（未実行）

- [ ] 遅延 fake daemon・接続途中切断・deadline 回帰テスト
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `runtime.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt))
- `src/core/client/client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/client.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
