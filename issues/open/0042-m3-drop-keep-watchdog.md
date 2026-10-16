# [P0 / M3] 所有 container の Drop/keep/watchdog cleanup 契約

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M3
- Depends on: [0021](./0021-m1-linux-process-crash-recovery.md), [0032](./0032-m2-apple-native-xpc-e2e.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 は明示 rm のみで upstream の TESTCONTAINERS_COMMAND=keep / Drop cleanup と異なる。

## 実装範囲

- 所有 scope に限定した async cleanup guard を設計
- keep は自動削除のみを抑え明示 rm は有効
- プロセス exit/kill 時の watchdog 設計と例外を文書化

## 完了条件

- [ ] 通常終了時 cleanup・keep 時残置を確認
- [ ] 不意の SIGKILL でも所有コンテナ以外は消さない
- [ ] 再実行しても監視プロセスが残らない

## 検証計画（未実行）

- [ ] Docker process-crash E2E / keep mode E2E / Linux/macOS cleanup
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/watchdog.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/watchdog.rs))
- `src/core/containers/async_container.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
