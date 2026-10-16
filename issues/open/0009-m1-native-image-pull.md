# [P0 / M1] Docker Engine API の image pull と progress/error を実装

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M1
- Depends on: [0006](./0006-m1-docker-unix-socket-transport.md), [0007](./0007-m1-docker-http-framing-parser.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

direct API start に必要な image pull は未移植。

## 実装範囲

- image reference を正規化し /images/create を実装
- pull の stream JSON と失敗理由を処理
- 既存 image と pull policy を文書化

## 完了条件

- [ ] alpine 指定バージョンの pull→start が CLI なしで可能
- [ ] 404/認証/timeout は正しくエラー
- [ ] ログに秘密情報を出さない

## 検証計画（未実行）

- [ ] 実 Docker pull と fake registry error fixture
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/docker_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs))
- `src/core/client/image_config.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/image_config.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
