# [P1 / M1] CLI と直結 API の移行方針・capability gate

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M1
- Depends on: [0010](./0010-m1-docker-create-start.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

最初の実装は CLI であり direct Engine 実装後の選択が曖昧だと偽の互換性が生まれる。

## 実装範囲

- runtime adapter を内部境界に閉じ込める
- direct API を優先し CLI は明示指定のみにするか廃止条件を定義
- public GenericImage API を runtime に依存させない

## 完了条件

- [ ] 同一 fixture を各 adapter に渡せる
- [ ] unsupported option は実行前に失敗
- [ ] ドキュメントが選択動作と一致

## 検証計画（未実行）

- [ ] unit capability matrix と Docker direct/CLI 比較 smoke
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `commands.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt))
- `runtime.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt))
- `docs/PORTING.md` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
