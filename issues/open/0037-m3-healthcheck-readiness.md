# [P1 / M3] Healthcheck builder と healthy/unhealthy wait を実装

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

WaitFor::healthcheck は型だけあり実行前拒否される。

## 実装範囲

- Healthcheck Test/Interval/Timeout/Retries/StartPeriod を表現
- Engine health state を poll
- 未設定・starting・healthy・unhealthy を区別

## 完了条件

- [ ] healthy で ready を返し unhealthy を即分類
- [ ] health 未設定を成功と扱わない
- [ ] 同じ startup deadline を共有

## 検証計画（未実行）

- [ ] Docker HEALTHCHECK イメージ E2E、状态遷移 stub
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/healthcheck.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/healthcheck.rs))
- `src/core/wait/health_strategy.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/health_strategy.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
