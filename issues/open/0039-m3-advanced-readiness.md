# [P2 / M3] 環境変数待ちと複数 ready conditions の意味論

- Status: open
- Created: 2026-10-16
- Priority: P2
- Milestone: M3
- Depends on: [0036](./0036-m3-http-readiness.md), [0037](./0037-m3-healthcheck-readiness.md), [0038](./0038-m3-exit-cmd-wait.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream の millis_in_env_var とログ待ちの条件合成は M0 の簡易 wait より広い。

## 実装範囲

- 環境変数 millis の型/不正値処理を明記
- 順序付き条件の結果と途中失敗を定義
- 空ログ条件を無条件成功にすべきか upstream と比較

## 完了条件

- [ ] 複数条件の所要時間の合計が startup timeout を越えない
- [ ] invalid env は明示失敗
- [ ] ログ待ちは発行後の stream を失わない

## 検証計画（未実行）

- [ ] fake clock / log replay / 負値・overflow 条件
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/wait/mod.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/mod.rs))
- `src/core/wait/log_strategy.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/log_strategy.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
