# [P0 / M1] Docker exec create/start と stdout/stderr 多重化を移植

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M1
- Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md), [0007](./0007-m1-docker-http-framing-parser.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 は docker exec CLI の文字列 stdout/stderr を取得するのみ。

## 実装範囲

- exec create/start/inspect を直接呼ぶ
- Docker stdcopy frame と TTY 非多重化を区別
- exit code と stdout/stderr を別々に取得

## 完了条件

- [ ] 混合 stdout/stderr と非ゼロ exit code が正しく復元
- [ ] 壊れた frame・サイズ超過はエラー
- [ ] env 付き exec を設計に含める

## 検証計画（未実行）

- [ ] 多重化バイト列 unit と Alpine exec E2E
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/containers/async_container/exec.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container/exec.rs))
- `src/core/client/docker_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
