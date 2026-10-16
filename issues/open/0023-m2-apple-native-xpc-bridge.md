# [P0 / M2] Apple Container XPC の MoonBit-native FFI 境界を確定

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M2
- Depends on: なし
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream macOS は CLI ではなく Apple Container XPC を直接利用し、MoonBit にはまだ bridge がない。

## 実装範囲

- macOS Apple Silicon native 向け XPC 呼出手段を PoC
- 必要な Objective-C/Swift/C shim があれば最小面積で隔離
- Node/Rust runtime を不要とする

## 完了条件

- [ ] コンテナ daemon との handshake の結果を取得
- [ ] 破棄・接続失敗でリークしない
- [ ] Intel Mac は要求対象外と明記

## 検証計画（未実行）

- [ ] 物理 Apple Silicon macOS 26 で最小 XPC PoC
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/xpc_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs))
- `docs/PORTING.md` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
