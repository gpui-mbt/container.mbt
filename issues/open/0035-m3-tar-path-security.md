# [P0 / M3] tar 作成/展開と path traversal の安全性

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M3
- Depends on: [0033](./0033-m3-copy-to-before-start.md), [0034](./0034-m3-copy-from-bounded-archive.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

container 内へコピーするデータの tar path は外部入力を含み危険な経路になり得る。

## 実装範囲

- ../、//、末尾 .、絶対 path、リンク展開の受け入れ条件を定義
- パスを規格化する前に不正構造を検知
- 巨大 header や異常 tar を無制限に読まない

## 完了条件

- [ ] target 外を上書きしない
- [ ] invalid path を start 前に拒否
- [ ] tar サイズ/件数上限がテスト可能

## 検証計画（未実行）

- [ ] 悪意ある tar の property-based test と Linux fixture
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/docker_tar.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_tar.rs))
- `src/core/copy.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/copy.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
