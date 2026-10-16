# [P1 / M3] WaitFor::exit と exec 待機条件を移植

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md), [0012](./0012-m1-docker-exec-attach.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 の WaitFor::when_exited と exec 期待値は未対応。

## 実装範囲

- ExitWaitStrategy と CmdWaitFor の exit code/出力文字列待ちを表現
- 終了コード指定・不問を区別
- exec の待ち中も deadline を伝搬

## 完了条件

- [ ] 期待コード一致で成功・不一致で typed error
- [ ] 終了待ちが無限化しない
- [ ] stderr 条件が stdout と混線しない

## 検証計画（未実行）

- [ ] 短命 Alpine container / exec 日時制御 unit
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/wait/exit_strategy.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/exit_strategy.rs))
- `src/core/wait/cmd_wait.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/cmd_wait.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
