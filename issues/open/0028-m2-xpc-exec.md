# [P1 / M2] Apple XPC exec と stdout/stderr/exit code を取得

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M2
- Depends on: [0026](./0026-m2-xpc-create-start.md), [0024](./0024-m2-xpc-protocol-contract.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream は macOS の XPC exec で専用出力 pipe を使う。

## 実装範囲

- exec request と env/user/working directory の指定
- stdout/stderr の FD と exit status を同期させる
- 出力が 64 MiB を超える場合にエラー

## 完了条件

- [ ] stdout/stderr が混線せず非ゼロ exit code を取得
- [ ] FD leak なし
- [ ] 失敗後に次の exec が可能

## 検証計画（未実行）

- [ ] Apple Silicon 実機で Alpine exec、異常終了・大量出力 test
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/xpc_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs))
- `src/core/containers/async_container/exec.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container/exec.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
