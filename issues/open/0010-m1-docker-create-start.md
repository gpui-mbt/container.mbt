# [P0 / M1] Docker Engine API の create/start と request serialization

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M1
- Depends on: [0006](./0006-m1-docker-unix-socket-transport.md), [0007](./0007-m1-docker-http-framing-parser.md), [0009](./0009-m1-native-image-pull.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

GenericImage は CLI argv しか生成せず Docker JSON create request がない。

## 実装範囲

- Cmd/Entrypoint/Env/Labels/HostConfig/port bindings を JSON にする
- create した ID で start し失敗時 rollback
- builder のスナップショットを維持

## 完了条件

- [ ] docker 実 API の create/start で Alpine が起動
- [ ] 二段階失敗時に所有 ID が回収される
- [ ] CLI 起動を一度も使わない

## 検証計画（未実行）

- [ ] moon test --target native と Docker daemon-backed lifecycle test
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `image.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt))
- `src/core/client/container_cfg.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs))
- `src/core/client/docker_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
