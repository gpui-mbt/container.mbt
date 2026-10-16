# [P1 / M3] WaitFor::http と HTTP status/header/body 条件を移植

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0014](./0014-m1-dynamic-published-ports.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream の HTTP/1.1 readiness は M0 に存在しない。

## 実装範囲

- HttpWaitStrategy を MoonBit 型で表現
- 指定 port/path/期待 status/header/body を照合
- 未起動/接続拒否/非 HTTP レスポンスの retry と timeout を分離

## 完了条件

- [ ] nginx 200 を待てる
- [ ] 条件不一致は deadline 内で再試行
- [ ] TLS 非対応を明示し SSL 成功を誤認しない

## 検証計画（未実行）

- [ ] nginx real Docker E2E / socket fake HTTP response unit
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/wait/http_strategy.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/http_strategy.rs))
- `image.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
