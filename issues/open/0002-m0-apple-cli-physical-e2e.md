# [P0 / M0] Apple Silicon 実機で M0 CLI smoke を完走する

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M0
- Depends on: [0001](./0001-m0-run-failure-orphan-cleanup.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

Linux Docker CI 成功は macOS 26 の Apple Container 実行を証明しない。

## 実装範囲

- docs/APPLE_E2E.md の host 要件を実機で収集
- smoke_apple の起動・ログ待ち・exec・stop・delete を通す
- 実行前後のコンテナ一覧と cleanup を保存

## 完了条件

- [ ] 実機コマンドの終了コード 0 と Apple Container lifecycle E2E PASS を確認
- [ ] OS/arch/container version/実行ログ/残存ゼロを記録

## 検証計画（未実行）

- [ ] uname -m; sw_vers -productVersion; container system version; moon run smoke_apple --target native
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `docs/APPLE_E2E.md` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md))
- `smoke_apple/main.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke_apple/main.mbt))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
