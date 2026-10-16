# [P0 / M2] Apple XPC logs の FD 所有権と停止処理

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M2
- Depends on: [0026](./0026-m2-xpc-create-start.md), [0024](./0024-m2-xpc-protocol-contract.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream では XPC ログの複数 FD、poll、consumer lifecycle が複雑で、CLI logs と異なる。

## 実装範囲

- stdout/stderr/bootlog の FD を追跡し ownership を一箇所に置く
- start/stop/rm/再起動/consumer panic 時の閉鎖を設計
- フォローログの停止とキャンセルを作る

## 完了条件

- [ ] FD 数が操作後に増え続けない
- [ ] 2 stream を誤配信しない
- [ ] 再起動後も新しい log stream を受信

## 検証計画（未実行）

- [ ] macOS 実機 FD count 比較 / mixed stdout stderr / cancel test
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/xpc_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs))
- `src/core/logs/consumer.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/logs/consumer.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
