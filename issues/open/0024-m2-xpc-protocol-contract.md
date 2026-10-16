# [P0 / M2] XPC request/response・型/バージョン契約を移植

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M2
- Depends on: [0023](./0023-m2-apple-native-xpc-bridge.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

XPC はコマンドライン出力で代替できず Apple container の protocol に依存する。

## 実装範囲

- upstream の request key・response body・error code を追跡
- シリアライズ/デシリアライズ境界を独立モジュール化
- Apple Container version 差を明示エラーにする

## 完了条件

- [ ] golden fixture で主要メッセージを再現
- [ ] 未知キー/NULL/不正 UTF-8 を安全に拒否
- [ ] XPC のコネクション再利用を検証

## 検証計画（未実行）

- [ ] mock serialization test と実機 version handshake
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/xpc_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
