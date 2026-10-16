# [P1 / M2] Apple XPC image pull・参照/manifest の確認

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M2
- Depends on: [0024](./0024-m2-xpc-protocol-contract.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

CLI では間接実行される image pull を XPC native へ移す。

## 実装範囲

- image name/tag と platform を XPC request に変換
- pull 完了/失敗を分類
- manifest のプラットフォーム選択と image not found を検証

## 完了条件

- [ ] alpine の取得→create に利用できる
- [ ] 存在しない tag は適切にエラー
- [ ] 通信不能時は期限内に復帰

## 検証計画（未実行）

- [ ] Apple Silicon 実機で public registry への pull と異常系
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/xpc_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs))
- `src/core/client/image_config.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/image_config.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
