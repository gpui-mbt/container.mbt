# [P1 / M1] Docker API version・daemon readiness の判定を追加

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M1
- Depends on: [0006](./0006-m1-docker-unix-socket-transport.md), [0007](./0007-m1-docker-http-framing-parser.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

互換 Engine では API version と利用可能機能が異なる。

## 実装範囲

- /_ping と /version で利用可能性を判定
- 必要な API version・unsupported option を事前診断
- CLI fallback と direct API をログ/エラーで識別

## 完了条件

- [ ] daemon 停止・古い API・ソケット誤接続を区別
- [ ] 非対応機能に対して無言 fallback しない

## 検証計画（未実行）

- [ ] mock daemon 各バージョンと Docker 実機
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/docker_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs))
- `commands.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
