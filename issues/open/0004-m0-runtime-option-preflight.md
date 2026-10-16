# [P1 / M0] CLI adapter の非対応設定を副作用前に明示拒否する

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M0
- Depends on: なし
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

image.mbt には Docker/Apple Container の共通 builder があるが、両 CLI でサポート差がある。

## 実装範囲

- ランタイム別 capability 表を作り引数化前にバリデーション
- 誤って黙殺される設定を許可しない
- mount/port/network/platform の意味が異なる設定は特定のエラーにする

## 完了条件

- [ ] 全設定が適用・明示拒否のいずれかになる
- [ ] 拒否前に run/pull が呼ばれない

## 検証計画（未実行）

- [ ] moon test --target native に各ランタイムの負の契約テストを追加
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `image.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt))
- `commands.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt))
- `docs/PORTING.md` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
