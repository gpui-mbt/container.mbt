# [P1 / M3] tmpfs size/mode・volume/read-only/bind の詳細互換

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0010](./0010-m1-docker-create-start.md), [0026](./0026-m2-xpc-create-start.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 の Mount は Bind/Volume/Tmpfs と read_only のみで upstream の tmpfs options 等が欠ける。

## 実装範囲

- tmpfs size bytes/mode/access をモデル化
- bind source の絶対パス・存在性確認
- ランタイム別未対応設定を副作用前拒否

## 完了条件

- [ ] read-only 書込拒否・tmpfs size の有効性を検証
- [ ] 不正/不存在 source で副作用なし
- [ ] Mac/Linux 非互換は matrix 化

## 検証計画（未実行）

- [ ] mount unit + Linux Docker/macOS Apple E2E
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `image.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt))
- `src/core/mounts.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/mounts.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
