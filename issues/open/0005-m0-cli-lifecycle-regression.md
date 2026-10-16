# [P1 / M0] CLI 起動・readiness・cleanup の回帰テストを固定する

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M0
- Depends on: [0001](./0001-m0-run-failure-orphan-cleanup.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

既存の単一 deadline と builder snapshot は重要な回帰点だが、実ランタイムの故障パターンを増やす必要がある。

## 実装範囲

- 起動時間を消費した後の複合 wait を網羅
- 既定/重複 mapping/後から builder 変更/途中 failure をテスト
- run で使った container ID のみ操作することを検証

## 完了条件

- [ ] start 起点の deadline を延長しない
- [ ] 中断時 rollback に別個の有界予算を適用
- [ ] 周辺に残存するコンテナを削除しない

## 検証計画（未実行）

- [ ] moon check --target native --deny-warn; moon test --target native; Docker smoke
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `runtime_wbtest.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime_wbtest.mbt))
- `smoke/main.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke/main.mbt))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
