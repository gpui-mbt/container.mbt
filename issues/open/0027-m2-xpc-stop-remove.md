# [P0 / M2] Apple XPC stop/remove と idempotent cleanup

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M2
- Depends on: [0026](./0026-m2-xpc-create-start.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

CLI delete と XPC の停止・削除の semantics は同一と仮定できない。

## 実装範囲

- grace と hard kill の違いを API で扱う
- 停止/削除後の inspect と error を定義
- 繰返し stop/rm に安全な挙動を保証

## 完了条件

- [ ] stop→rm 後残存ゼロ
- [ ] タイムアウト後の cleanup を追跡可能
- [ ] 他コンテナに操作が及ばない

## 検証計画（未実行）

- [ ] Apple Silicon 実機 lifecycle E2E / timeout test
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/xpc_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs))
- `src/core/containers/async_container.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
