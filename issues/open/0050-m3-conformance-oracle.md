# [P0 / M3] Rust upstream と MoonBit の同一 fixture 比較基盤

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M3
- Depends on: [0020](./0020-m1-linux-native-e2e.md), [0032](./0032-m2-apple-native-xpc-e2e.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

port の完了を Rust ソースの存在で判断せず、実際の observable behavior の一致で判定する。

## 実装範囲

- upstream commit を pinned oracle にし Linux/Mac 実体 fixture を対応付け
- exit/log/ports/copy/timeout 等の比較形式を定義
- 環境未実行を PASS に含めない

## 完了条件

- [ ] 各 fixture に upstream/moonbit/環境/結果が記録
- [ ] 意図的差分を FAIL または documented deviation として区別
- [ ] 比較に固定 revision を使う

## 検証計画（未実行）

- [ ] Rust source cargo tests と MoonBit native E2E の結果照合
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `docs/PORTING.md` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md))
- `docs/TESTCONTAINERS.md` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/docs/TESTCONTAINERS.md))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
