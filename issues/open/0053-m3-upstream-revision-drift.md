# [P2 / M3] pinned upstream からの API/挙動 drift を追跡する

- Status: open
- Created: 2026-10-16
- Priority: P2
- Milestone: M3
- Depends on: [0050](./0050-m3-conformance-oracle.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

参照元は 2026-10-07 時点の commit 固定であり、以後の upstream 変更を無批判に混ぜない必要がある。

## 実装範囲

- pinned SHA と新 HEAD の差分を定期比較する手順を設計
- 追加 API/修正 bug/未対応を Markdown issue に分離
- parity の判定 source revision を残す

## 完了条件

- [ ] 同一 issue が複数 source revision を混ぜない
- [ ] 更新時に該当 fixture と結果を更新
- [ ] 非互換変更を無断採用しない

## 検証計画（未実行）

- [ ] GitHub source diff + test matrix レビュー（手動でも可）
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `docs/PORTING.md` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md))
- `src/lib.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/lib.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
