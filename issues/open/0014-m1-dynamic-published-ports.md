# [P0 / M1] Docker の動的 host port を IPv4/IPv6 inspect で解決

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M1
- Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

with_exposed_port は host=0 を指定できるが M0 get_host_port_ipv4 は実割当を返せない。

## 実装範囲

- inspect の NetworkSettings.Ports から protocol 別 mapping を解析
- IPv4 と IPv6 の情報を別 API で公開
- 未公開・未割当ポートは明示エラー

## 完了条件

- [ ] host=0 で起動後に割当ポートを返し TCP 通信成功
- [ ] port 0 を実ポートとして返さない
- [ ] duplicate protocol 対応

## 検証計画（未実行）

- [ ] Docker nginx dynamic publish E2E / IPv4 IPv6 JSON fixture
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `ports.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/ports.mbt))
- `runtime.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt))
- `src/core/ports.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/ports.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
