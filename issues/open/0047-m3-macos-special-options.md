# [P2 / M3] Mac 専用 kernel/ssh/masked/readonly path オプション

- Status: open
- Created: 2026-10-16
- Priority: P2
- Milestone: M3
- Depends on: [0024](./0024-m2-xpc-protocol-contract.md), [0026](./0026-m2-xpc-create-start.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream は Apple Container 向け kernel/ssh/masked_paths/readonly_paths を持つ。Linux は未対応と明示する。

## 実装範囲

- XPC 対応可否を実機で確認
- path の検証と拒否ルールを設計
- Linux は明示 non-supported、Mac は version 要件を記録

## 完了条件

- [ ] 各 option が適用または明示拒否される
- [ ] 秘密/ホスト path が意図せず容器へ公開されない
- [ ] 非対応機能が silent ignore されない

## 検証計画（未実行）

- [ ] Mac physical XPC fixture / Linux unsupported unit
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/image/image_ext.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs))
- `src/core/client/xpc_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
