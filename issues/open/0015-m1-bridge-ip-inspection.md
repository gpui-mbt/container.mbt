# [P1 / M1] Container bridge IP と network 情報を正規化

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M1
- Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream は bridge IP を取得できるが M0 には API がない。

## 実装範囲

- inspect の Networks を parse
- 優先 network の選定規則を明示
- network 未接続、IP 無しの状態を区別

## 完了条件

- [ ] bridge IP 取得に成功し、到達可能な場合は通信できる
- [ ] 複数 network でも選択が安定
- [ ] 空 IP を正常値として返さない

## 検証計画（未実行）

- [ ] Docker network fixture と daemon-backed test
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/docker_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs))
- `src/core/containers/async_container.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
