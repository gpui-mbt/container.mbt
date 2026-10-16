# [P1 / M3] 公開エラー型と失敗分類の一貫性を検証

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0017](./0017-m1-engine-http-errors.md), [0024](./0024-m2-xpc-protocol-contract.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

CLI string errors と XPC/HTTP errors を統合しないとユーザーが分岐できない。

## 実装範囲

- Client/Wait/Exec/Port/IO の分類を公開エラーで表す
- OS/adapter 固有の発生源を失わず文言の機密性を確保
- エラー時の owned resource 回収を共通化

## 完了条件

- [ ] missing image/container/path と bad auth/timeout を識別
- [ ] password/token を含めない
- [ ] エラーの分類が両 adapter で一貫

## 検証計画（未実行）

- [ ] Linux/macOS 負の contract suite / error classification table
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/error.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/error.rs))
- `runtime.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
