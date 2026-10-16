# [P1 / M3] Linux/Mac の実証と compile-only を区別する CI

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0020](./0020-m1-linux-native-e2e.md), [0032](./0032-m2-apple-native-xpc-e2e.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

Linux Docker CI と Mac VM の compile は Apple Container XPC 実機実行を代替しない。

## 実装範囲

- native check/test/build と daemon E2E を区別
- Apple Silicon 物理ホスト実行の証拠を artifact 化
- 明示 skip/未実行を緑扱いしない

## 完了条件

- [ ] 必須 Linux CI green
- [ ] Mac physical E2E 証拠 URL/日時/HEAD が追跡可能
- [ ] 失敗時ログ/残存 container 一覧を保存

## 検証計画（未実行）

- [ ] GitHub Actions run と物理 Mac 手動 acceptance
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `docs/APPLE_E2E.md` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md))
- `.github/workflows/ci.yml` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/.github/workflows/ci.yml))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
