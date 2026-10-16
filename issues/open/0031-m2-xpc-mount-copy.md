# [P1 / M2] Apple XPC bind/volume/tmpfs とコピーの互換検証

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M2
- Depends on: [0026](./0026-m2-xpc-create-start.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

macOS では with_copy_to は start 後投入、起動前に必要なファイルは bind が基本。

## 実装範囲

- XPC mount の source/target/access mode を変換
- prestart bind と poststart copy の順序を保証
- volume/tmpfs の実サポート差を capability に反映

## 完了条件

- [ ] 起動前 bind を init から読める
- [ ] copy-to の前後順がテストでわかる
- [ ] read-only mount へ書込できない

## 検証計画（未実行）

- [ ] Apple 実機で bind/volume/tmpfs/copy fixture
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/xpc_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs))
- `src/core/mounts.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/mounts.rs))
- `src/core/copy.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/copy.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
