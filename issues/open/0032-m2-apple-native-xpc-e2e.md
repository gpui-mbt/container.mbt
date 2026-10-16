# [P0 / M2] macOS 26 Apple Silicon の XPC native 受入試験

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M2
- Depends on: [0026](./0026-m2-xpc-create-start.md), [0027](./0027-m2-xpc-stop-remove.md), [0028](./0028-m2-xpc-exec.md), [0029](./0029-m2-xpc-logs-fd-ownership.md), [0030](./0030-m2-xpc-ports-network-inspect.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 CLI smoke が成功しても XPC 直接利用は検証されない。

## 実装範囲

- 物理 Apple Silicon で image pull→create→exec→logs→stop→delete を実行
- Apple container version/FD/port/cleanup 証拠を収集
- Local Network Privacy と仮想化前提を検証

## 完了条件

- [ ] CLI バイナリへの依存なしで native flow 完走
- [ ] 停止後の orphan/FD 残存ゼロ
- [ ] CI ビルド成功だけを実機 E2E と呼ばない

## 検証計画（未実行）

- [ ] macOS 26+ Apple Silicon 物理ホストの明示受入テスト
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `docs/APPLE_E2E.md` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md))
- `src/core/client/xpc_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
