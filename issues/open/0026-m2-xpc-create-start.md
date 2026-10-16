# [P0 / M2] Apple XPC container create/start と rollback

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M2
- Depends on: [0024](./0024-m2-xpc-protocol-contract.md), [0025](./0025-m2-xpc-image-pull.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

macOS の主対象である XPC create/start は現行 CLI adapter とは別に実装する必要がある。

## 実装範囲

- GenericImage snapshot を XPC container config に変換
- create→start→readiness を分離
- 途中失敗時に作成 ID を使った限定 rollback

## 完了条件

- [ ] Apple CLI を起動せずコンテナを生成・起動
- [ ] 同名衝突/不正 config は前段でエラー
- [ ] 起動失敗後に実験容器が残らない

## 検証計画（未実行）

- [ ] Apple Silicon 実機の create/start・故障注入 E2E
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/xpc_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs))
- `src/core/client/container_cfg.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
