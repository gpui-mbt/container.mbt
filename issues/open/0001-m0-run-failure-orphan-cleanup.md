# [P0 / M0] CLI run が ID を返す前に失敗した場合の orphan 回収

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M0
- Depends on: なし
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 は readiness 失敗時に rm する一方、run の途中失敗で ID を取得できない場合の孤児化が docs/APPLE_E2E.md に残る。

## 実装範囲

- 起動要求ごとに推測困難で固有の container name/label を割り当てて対象を追跡する
- run エラー/タイムアウト後の削除を所有 ID に限定して行う
- 既存のユーザー所有コンテナは削除しない

## 完了条件

- [ ] run 失敗直後に対象コンテナが残存しない
- [ ] 同名既存コンテナ・タイムアウト・出力欠落で誤削除が起きない

## 検証計画（未実行）

- [ ] Docker 実 E2E と Apple CLI 実機で故障注入。moon test --target native
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `docs/APPLE_E2E.md` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md))
- `runtime.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
