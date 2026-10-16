# [P1 / M2] Apple XPC port mapping・bridge IP・host gateway

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M2
- Depends on: [0026](./0026-m2-xpc-create-start.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

Apple CLI は hostPort=0 を未検証として拒否するが upstream はホスト空きポートの割当を扱う。

## 実装範囲

- ポート割当の予約と公開/取得を実装
- IPv4/IPv6・bridge IP/host gateway の扱いを追跡
- SCTP 等非対応 protocol を拒否

## 完了条件

- [ ] port=0 の要求でホストから通信できる有効ポートを得る
- [ ] 競合時に再試行上限・誤公開なし
- [ ] IP 不明を検知

## 検証計画（未実行）

- [ ] Apple Silicon 実機 TCP/UDP ポート E2E
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/xpc_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs))
- `src/core/ports.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/ports.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
