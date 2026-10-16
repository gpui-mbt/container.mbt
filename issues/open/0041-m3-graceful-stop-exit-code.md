# [P1 / M3] stop_with_timeout と exit code 語義を揃える

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md), [0027](./0027-m2-xpc-stop-remove.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 の stop は固定30秒の CLI 操作で grace/exit code API を持たない。

## 実装範囲

- None/0/正値・異常値の stop grace を定義
- kill と graceful の終了コードを識別
- stop 後の exit code 取得と stale cache 回避

## 完了条件

- [ ] SIGTERM を trap したプロセスが graceful 終了
- [ ] SIGKILL と区別できる
- [ ] 停止直後の race でも最終 code を返す

## 検証計画（未実行）

- [ ] Linux/macOS SIGTERM fixture + inspect/wait assertions
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/containers/async_container.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs))
- `src/core/wait/exit_strategy.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/exit_strategy.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
