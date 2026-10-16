# [P2 / M3] SyncRunner と同期 Container 操作の安全な設計

- Status: open
- Created: 2026-10-16
- Priority: P2
- Milestone: M3
- Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

Rust upstream に blocking API がある一方、MoonBit 版は native async 専用。

## 実装範囲

- MoonBit 環境で同期 façade の実装可否を決定
- runtime 内 reentry・consumer callback の deadlock を避ける
- 非対応なら API 一覧で理由を明示

## 完了条件

- [ ] 通常同期呼出が同等の lifecycle を完走
- [ ] 危険な再入は即エラー
- [ ] async API に破壊的変更なし

## 検証計画（未実行）

- [ ] ネイティブ同期 consumer sample / reentry negative fixture
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/runners/sync_runner.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/sync_runner.rs))
- `src/core/containers/sync_container.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/sync_container.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
